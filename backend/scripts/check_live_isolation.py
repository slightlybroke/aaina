"""Real Supabase ordinary-user isolation checks; disposable fixtures, no YouCam calls."""

import asyncio
import io
from datetime import timedelta
from uuid import uuid4

import httpx
from dotenv import dotenv_values
from PIL import Image

from app.config import Settings
from app.domain import utcnow
from app.repository import Supabase


def check(condition, label):
    if not condition:
        raise RuntimeError(label)
    print("PASS:", label, flush=True)


async def run():
    s = Settings()
    check(
        s.supabase_url.rstrip("/") == "https://zouvroynucstxqimygzd.supabase.co",
        "confirmed project",
    )
    v = dotenv_values(".env")
    async with httpx.AsyncClient(timeout=25, follow_redirects=False) as http:
        repo = Supabase(s, http)
        users = []
        for suffix in ("", "_B"):
            email, password = (
                v.get("LIVE_TEST_EMAIL" + suffix),
                v.get("LIVE_TEST_PASSWORD" + suffix),
            )
            check(bool(email and password), "test account configuration " + (suffix or "A"))
            response = await http.post(
                s.supabase_url + "/auth/v1/token?grant_type=password",
                headers={"apikey": s.supabase_publishable_key},
                json={"email": email, "password": password},
            )
            check(response.status_code == 200, "ordinary password login " + (suffix or "A"))
            data = response.json()
            headers = {
                "apikey": s.supabase_publishable_key,
                "Authorization": "Bearer " + data["access_token"],
            }
            identity = await http.get(s.supabase_url + "/auth/v1/user", headers=headers)
            check(
                identity.status_code == 200 and identity.json().get("role") == "authenticated",
                "ordinary authenticated identity " + (suffix or "A"),
            )
            users.append((identity.json()["id"], headers))
        check(users[0][0] != users[1][0], "distinct ordinary test users")
        bucket = await repo.request("GET", "/storage/v1/bucket/" + s.storage_bucket)
        check(
            bucket.json().get("public") is False, "staging bucket is private (configuration only)"
        )
        fixtures = []
        buffer = io.BytesIO()
        Image.new("RGB", (1200, 1200), "gray").save(buffer, format="JPEG")
        content = buffer.getvalue()
        try:
            for uid, headers in users:
                jid = str(uuid4())
                now = utcnow()
                job = {
                    "id": jid,
                    "user_id": uid,
                    "idempotency_key": str(uuid4()),
                    "image_sha256": "disposable-isolation-fixture",
                    "image_path": f"{uid}/{jid}/source.jpg",
                    "consent_version": "skin-analysis-v1",
                    "status": "uploading",
                    "expires_at": (now + timedelta(minutes=10)).isoformat(),
                    "image_delete_after": (now + timedelta(minutes=10)).isoformat(),
                }
                await repo.insert_job(job)
                fixtures.append(job)
                await repo.upload(job["image_path"], content)
                # Synthetic result is a temporary authorization fixture, never provider evidence.
                await repo.request(
                    "POST",
                    "/rest/v1/skin_analyses",
                    json={
                        "job_id": jid,
                        "user_id": uid,
                        "overall_score": 1,
                        "metrics": [],
                        "api_version": "isolation_fixture",
                        "contract_verification": "test_fixture",
                    },
                )
            for index, (uid, headers) in enumerate(users):
                own, other = fixtures[index], fixtures[1 - index]
                for table, field in [("analysis_jobs", "id"), ("skin_analyses", "job_id")]:
                    for label, fixture, expected in [("own", own, 1), ("cross-user", other, 0)]:
                        response = await http.get(
                            s.supabase_url + "/rest/v1/" + table,
                            headers=headers,
                            params={field: "eq." + fixture["id"], "select": field},
                        )
                        check(
                            response.status_code == 200 and len(response.json()) == expected,
                            f"user {index + 1} {table} {label} read",
                        )
                    denied = await http.patch(
                        s.supabase_url + "/rest/v1/" + table,
                        headers=headers,
                        params={field: "eq." + own["id"]},
                        json={"user_id": other["user_id"]},
                    )
                    check(
                        denied.status_code in (401, 403),
                        f"user {index + 1} {table} direct write denied",
                    )
                own_url = s.supabase_url + repo.object_path(own["image_path"])
                other_url = s.supabase_url + repo.object_path(other["image_path"])
                response = await http.get(own_url, headers=headers)
                check(
                    response.status_code == 200 and response.content == content,
                    f"user {index + 1} own real object download",
                )
                response = await http.get(other_url, headers=headers)
                check(
                    response.status_code in (400, 401, 403, 404) and response.content != content,
                    f"user {index + 1} cross-user object download denied",
                )
                response = await http.post(
                    own_url,
                    headers={**headers, "Content-Type": "image/jpeg", "x-upsert": "true"},
                    content=content,
                )
                check(
                    response.status_code in (400, 401, 403),
                    f"user {index + 1} object overwrite denied",
                )
                response = await http.request(
                    "DELETE",
                    s.supabase_url + "/storage/v1/object/" + s.storage_bucket,
                    headers=headers,
                    json={"prefixes": [own["image_path"]]},
                )
                check(
                    response.status_code in (200, 400, 401, 403),
                    f"user {index + 1} delete request bounded",
                )
                remains = await http.get(own_url, headers=headers)
                check(
                    remains.status_code == 200 and remains.content == content,
                    f"user {index + 1} client deletion had no effect",
                )
                denied = await http.post(
                    s.supabase_url + "/rest/v1/rpc/complete_analysis_job",
                    headers=headers,
                    json={
                        "p_job": str(uuid4()),
                        "p_token": str(uuid4()),
                        "p_score": 1,
                        "p_metrics": [],
                        "p_warnings": [],
                    },
                )
                check(denied.status_code in (401, 403, 404), f"user {index + 1} worker RPC denied")
            anon = {"apikey": s.supabase_publishable_key}
            response = await http.get(
                s.supabase_url + "/rest/v1/analysis_jobs",
                headers=anon,
                params={"id": "eq." + fixtures[0]["id"], "select": "id"},
            )
            check(response.status_code in (401, 403), "anonymous job read denied")
            response = await http.get(
                s.supabase_url + repo.object_path(fixtures[0]["image_path"]), headers=anon
            )
            check(
                response.status_code in (400, 401, 403, 404) and response.content != content,
                "anonymous private object download denied",
            )
            print("ORDINARY_USER_ISOLATION_PASS", flush=True)
        finally:
            for job in fixtures:
                await repo.delete(job["image_path"])
                await repo.request(
                    "DELETE",
                    "/rest/v1/analysis_jobs",
                    params={"id": "eq." + job["id"], "user_id": "eq." + job["user_id"]},
                )
            print("Disposable fixture cleanup completed", flush=True)


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except RuntimeError as exc:
        raise SystemExit("CHECK_FAILED: " + str(exc)) from None
    except Exception as exc:
        raise SystemExit(
            "CHECK_ABORTED: " + type(exc).__name__ + "; inspect fixture cleanup locally"
        ) from None
