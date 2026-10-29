"""Live Auth/RLS/Storage checks using synthetic pixels; never calls YouCam."""

import argparse
import asyncio
import hashlib
import io
import json
from uuid import uuid4

import httpx
from dotenv import dotenv_values
from PIL import Image

from app.config import Settings
from app.main import create_app
from app.repository import Supabase
from app.vto_repository import VtoRepository


def check(condition, label):
    if not condition:
        raise RuntimeError(label)
    print("PASS: " + label, flush=True)


async def run():
    s = Settings()
    check(
        s.supabase_url == "https://zouvroynucstxqimygzd.supabase.co", "confirmed development target"
    )
    s.youcam_vto_enabled = True
    env = dotenv_values(".env")
    image = io.BytesIO()
    Image.new("RGB", (400, 600), "green").save(image, format="JPEG")
    fixtures = []
    async with httpx.AsyncClient(follow_redirects=False, timeout=30) as http:
        repo = Supabase(s, http)
        vto = VtoRepository(repo)

        async def login(suffix):
            r = await http.post(
                s.supabase_url + "/auth/v1/token?grant_type=password",
                headers={"apikey": s.supabase_publishable_key},
                json={
                    "email": env.get("LIVE_TEST_EMAIL" + suffix),
                    "password": env.get("LIVE_TEST_PASSWORD" + suffix),
                },
            )
            check(r.status_code == 200, "ordinary password login")
            data = r.json()
            check(data["user"]["role"] == "authenticated", "ordinary role")
            return data["user"]["id"], {"Authorization": "Bearer " + data["access_token"]}

        a, ha = await login("")
        b, hb = await login("_B")
        check(a != b, "distinct accounts")

        # Compare existing Phase 1/2/3 tables before and after; no row contents are printed.
        async def fingerprint():
            snapshots = []
            for table in [
                "skin_analyses",
                "routines",
                "routine_revisions",
                "routine_checkins",
                "skin_journal",
                "vanity_items",
            ]:
                snapshots.append(await repo.owned(table, a, order="id.asc", limit="1000"))
            return hashlib.sha256(json.dumps(snapshots, sort_keys=True).encode()).hexdigest()

        baseline = await fingerprint()
        app = create_app(s, repo, http)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as api:
            try:
                key = str(uuid4())

                async def create():
                    return await api.post(
                        "/v1/vto/jobs",
                        headers={**ha, "Idempotency-Key": key},
                        data={
                            "consent_version": "makeup-vto-v1",
                            "options": json.dumps({"mode": "lip_color"}),
                        },
                        files={"image": ("synthetic.jpg", image.getvalue(), "image/jpeg")},
                    )

                r = await create()
                check(r.status_code == 202, "synthetic source through authenticated VTO route")
                job_id = r.json()["id"]
                fixtures.append((a, job_id))
                check((await create()).json()["id"] == job_id, "idempotent replay")
                owner = await vto.owned(a, id="eq." + job_id)
                job = owner[0]
                public_read = await http.get(
                    s.supabase_url + "/storage/v1/object/public/vto-images/" + job["source_path"]
                )
                check(not public_read.is_success, "anonymous public Storage URL denied")
                for headers, expected in [(ha, 1), (hb, 0)]:
                    r = await http.get(
                        s.supabase_url + "/rest/v1/vto_jobs",
                        headers={**headers, "apikey": s.supabase_publishable_key},
                        params={"id": "eq." + job_id, "select": "id"},
                    )
                    check(
                        r.status_code == 200 and len(r.json()) == expected,
                        "ordinary-token RLS visibility",
                    )
                check(
                    (await api.get("/v1/vto/jobs/" + job_id, headers=hb)).status_code == 404,
                    "cross-account backend job denial",
                )
                for headers in [ha, hb]:
                    direct = {**headers, "apikey": s.supabase_publishable_key}
                    r = await http.get(
                        s.supabase_url
                        + "/storage/v1/object/authenticated/vto-images/"
                        + job["source_path"],
                        headers=direct,
                    )
                    check(not r.is_success, "direct Storage read denied (server-only bucket)")
                    r = await http.post(
                        s.supabase_url + "/storage/v1/object/vto-images/" + job["result_path"],
                        headers={**direct, "Content-Type": "image/jpeg"},
                        content=image.getvalue(),
                    )
                    check(not r.is_success, "ordinary-token Storage write denied")
                    r = await http.patch(
                        s.supabase_url + "/rest/v1/vto_jobs",
                        headers=direct,
                        params={"id": "eq." + job_id},
                        json={"status": "completed"},
                    )
                    check(not r.is_success, "ordinary-token job write denied")
                # Synthetic preview fixture only, explicitly not a rendered/live provider result.
                await vto.upload(job["result_path"], image.getvalue())
                await vto.patch(job_id, {"status": "completed"})
                check(
                    (await api.get("/v1/vto/jobs/" + job_id + "/preview", headers=hb)).status_code
                    == 404,
                    "cross-account preview denial",
                )
                _, fresh = await login("")
                r = await api.get("/v1/vto/jobs/" + job_id + "/preview", headers=fresh)
                check(
                    r.status_code == 200 and r.headers["cache-control"] == "no-store, private",
                    "fresh-login private synthetic preview",
                )
                check(
                    (await api.get("/v1/vto/jobs/" + job_id, headers=fresh)).json()["status"]
                    == "completed",
                    "fresh-login job persists",
                )
            finally:
                for user, job_id in fixtures:
                    rows = await vto.owned(user, id="eq." + job_id)
                    if not rows:
                        continue
                    for field in ["source_path", "result_path"]:
                        await vto.delete(rows[0][field])
                    await repo.request(
                        "DELETE",
                        "/rest/v1/vto_jobs",
                        params={"id": "eq." + job_id, "user_id": "eq." + user},
                    )
                check(await fingerprint() == baseline, "pre-existing data fingerprint unchanged")
                check(
                    not fixtures or not await vto.owned(a, id="eq." + fixtures[0][1]),
                    "exact synthetic fixture cleanup",
                )
    print(
        "LIVE_VTO_SECURITY_PASS (synthetic pixels; NO provider task or live VTO rendering)",
        flush=True,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--worker-stopped",
        action="store_true",
        help="Confirm the separate VTO worker is stopped; fixtures must never be submitted to YouCam.",
    )
    if not parser.parse_args().worker_stopped:
        parser.error(
            "Stop app.vto_worker first, then confirm with --worker-stopped. This check creates synthetic pending jobs."
        )
    try:
        asyncio.run(run())
    except Exception as exc:
        print(
            "LIVE_VTO_SECURITY_BLOCKED:",
            str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__,
        )
        raise SystemExit(1) from None
