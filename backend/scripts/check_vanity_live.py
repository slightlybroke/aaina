"""Digital Vanity acceptance against the confirmed dev project. No image/provider calls."""

import asyncio
import hashlib
import json
from uuid import uuid4

import httpx
from dotenv import dotenv_values

from app.config import Settings
from app.main import create_app
from app.repository import Supabase
from app.skincare import SkincareService


def check(condition, label):
    if not condition:
        raise RuntimeError(label)
    print("PASS:", label, flush=True)


def fingerprint(data):
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


async def run():
    settings = Settings()
    check(
        settings.supabase_url.rstrip("/") == "https://zouvroynucstxqimygzd.supabase.co",
        "confirmed development project",
    )
    env = dotenv_values(".env")
    async with httpx.AsyncClient(timeout=30, follow_redirects=False) as http:
        repo = Supabase(settings, http)
        tracker = SkincareService(repo)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(create_app(settings, repo, http)),
            base_url="http://acceptance",
        ) as api:

            async def login(suffix):
                email, password = (
                    env.get("LIVE_TEST_EMAIL" + suffix),
                    env.get("LIVE_TEST_PASSWORD" + suffix),
                )
                check(bool(email and password), "test-account configuration " + (suffix or "A"))
                response = await http.post(
                    settings.supabase_url + "/auth/v1/token?grant_type=password",
                    headers={"apikey": settings.supabase_publishable_key},
                    json={"email": email, "password": password},
                )
                check(response.status_code == 200, "ordinary password login " + (suffix or "A"))
                data = response.json()
                check(
                    data.get("user", {}).get("role") == "authenticated",
                    "ordinary authenticated role",
                )
                return {
                    "uid": data["user"]["id"],
                    "suffix": suffix,
                    "headers": {
                        "apikey": settings.supabase_publishable_key,
                        "Authorization": "Bearer " + data["access_token"],
                    },
                }

            users = [await login(""), await login("_B")]
            check(users[0]["uid"] != users[1]["uid"], "separate ordinary accounts")

            async def baseline(user):
                history = await api.get("/v1/analyses", headers=user["headers"])
                check(history.status_code == 200, "existing analysis history readable")
                data = {"analyses": history.json()}
                for table in [
                    "routines",
                    "routine_revisions",
                    "routine_checkins",
                    "skin_journal",
                    "skincare_settings",
                ]:
                    data[table] = await tracker.all(
                        table,
                        user["uid"],
                        "user_id.asc" if table == "skincare_settings" else "id.asc",
                    )
                return fingerprint(data)

            before = [await baseline(user) for user in users]
            fixtures = []
            cleanup_failures = []
            try:
                for index, user in enumerate(users):
                    item_id = str(uuid4())
                    fixtures.append((user["uid"], item_id))
                    name = "Disposable 50%_, shade " + item_id
                    path = "/v1/vanity/" + item_id
                    body = {"name": name}
                    responses = await asyncio.gather(
                        *(api.put(path, headers=user["headers"], json=body) for _ in range(3))
                    )
                    check(
                        all(r.status_code == 200 and r.json()["version"] == 1 for r in responses),
                        "concurrent create/retry retains one version",
                    )
                    rows = await repo.owned("vanity_items", user["uid"], id="eq." + item_id)
                    check(
                        len(rows) == 1 and rows[0]["brand"] == "" and rows[0]["shade_name"] == "",
                        "one stored incomplete product; unknown metadata stays blank",
                    )
                    edited = {
                        "name": name,
                        "brand": "Recorded test brand",
                        "category": "Acceptance-Custom",
                        "shade_name": "Recorded test shade",
                        "shade_identifier": "TEST-01",
                        "finish": "user-entered finish",
                        "undertone": "",
                        "notes": "Disposable acceptance note",
                        "expected_version": 1,
                    }
                    response = await api.put(path, headers=user["headers"], json=edited)
                    check(
                        response.status_code == 200 and response.json()["version"] == 2,
                        "edit all supported metadata and custom category",
                    )
                    retry = await api.put(path, headers=user["headers"], json=edited)
                    check(
                        retry.status_code == 200 and retry.json()["version"] == 2,
                        "edit retry is idempotent",
                    )
                    stale = await api.put(
                        path, headers=user["headers"], json={**edited, "notes": "Stale overwrite"}
                    )
                    check(stale.status_code == 409, "stale update rejected")
                    found = await api.get(
                        "/v1/vanity",
                        headers=user["headers"],
                        params={"q": name, "category": "ACCEPTANCE-CUSTOM"},
                    )
                    check(
                        found.status_code == 200
                        and len(found.json()["items"]) == 1
                        and found.json()["items"][0]["id"] == item_id,
                        "literal percent/underscore search and category filtering",
                    )
                    empty = await api.get(
                        "/v1/vanity",
                        headers=user["headers"],
                        params={"q": item_id, "category": "lipstick"},
                    )
                    check(
                        empty.status_code == 200 and empty.json()["items"] == [],
                        "nonmatching filter returns empty",
                    )

                for index, user in enumerate(users):
                    own, other = fixtures[index][1], fixtures[1 - index][1]
                    headers = user["headers"]
                    for label, item_id, count in [("own", own, 1), ("other", other, 0)]:
                        params = {"id": "eq." + item_id, "select": "id"}
                        response = await http.get(
                            settings.supabase_url + "/rest/v1/vanity_items",
                            headers=headers,
                            params=params,
                        )
                        check(
                            response.status_code == 200 and len(response.json()) == count,
                            f"user {index + 1} {label} RLS read",
                        )
                        for method in ["PATCH", "DELETE"]:
                            response = await http.request(
                                method,
                                settings.supabase_url + "/rest/v1/vanity_items",
                                headers=headers,
                                params=params,
                                **({"json": {"notes": "Forbidden"}} if method == "PATCH" else {}),
                            )
                            check(
                                response.status_code in (401, 403),
                                f"{label} direct {method} denied",
                            )
                    inserted = await http.post(
                        settings.supabase_url + "/rest/v1/vanity_items",
                        headers=headers,
                        json={"id": str(uuid4()), "user_id": user["uid"], "name": "Forbidden"},
                    )
                    check(inserted.status_code in (401, 403), "direct client insert denied")
                    for rpc, payload in [
                        (
                            "list_vanity_items",
                            {
                                "p_user": users[1 - index]["uid"],
                                "p_query": "",
                                "p_category": "",
                                "p_offset": 0,
                            },
                        ),
                        (
                            "save_vanity_item",
                            {
                                "p_user": users[1 - index]["uid"],
                                "p_id": other,
                                "p_data": {"name": "Forbidden"},
                                "p_expected_version": 2,
                            },
                        ),
                    ]:
                        denied = await http.post(
                            settings.supabase_url + "/rest/v1/rpc/" + rpc,
                            headers=headers,
                            json=payload,
                        )
                        check(denied.status_code in (401, 403), "ordinary user cannot call " + rpc)
                    for method, body in [
                        ("GET", None),
                        ("PUT", {"name": "Forbidden", "expected_version": 2}),
                        ("DELETE", None),
                    ]:
                        response = await api.request(
                            method, "/v1/vanity/" + other, headers=headers, json=body
                        )
                        check(response.status_code == 404, "API cross-user " + method + " denied")
                    result = await api.get("/v1/vanity", headers=headers, params={"q": other})
                    check(
                        result.status_code == 200 and result.json()["items"] == [],
                        "other user search returns no inventory",
                    )
                    logout = await http.post(
                        settings.supabase_url + "/auth/v1/logout?scope=local", headers=headers
                    )
                    check(logout.status_code in (200, 204), "actual session sign-out")
                    fresh = await login(user["suffix"])
                    saved = await api.get("/v1/vanity/" + own, headers=fresh["headers"])
                    check(
                        saved.status_code == 200
                        and saved.json()["version"] == 2
                        and saved.json()["shade_identifier"] == "TEST-01",
                        "metadata persists after fresh password login",
                    )
                    check(
                        await baseline(fresh) == before[index],
                        "Phase 1 history and all Phase 2 stored data unchanged",
                    )
                    deleted = await api.delete("/v1/vanity/" + own, headers=fresh["headers"])
                    check(deleted.status_code == 200, "own product deletion")
                    check(
                        (await api.get("/v1/vanity/" + own, headers=fresh["headers"])).status_code
                        == 404,
                        "deleted item no longer retrievable",
                    )
                anonymous = await http.get(
                    settings.supabase_url + "/rest/v1/vanity_items",
                    headers={"apikey": settings.supabase_publishable_key},
                )
                check(anonymous.status_code in (401, 403), "anonymous inventory access denied")
            finally:
                for uid, item_id in fixtures:
                    try:
                        await repo.request(
                            "DELETE",
                            "/rest/v1/vanity_items",
                            params={"id": "eq." + item_id, "user_id": "eq." + uid},
                        )
                        check(
                            not await repo.owned("vanity_items", uid, id="eq." + item_id),
                            "exact disposable inventory fixture cleanup verified",
                        )
                    except Exception:
                        cleanup_failures.append(item_id)
                check(not cleanup_failures, "all vanity fixture cleanup completed")
            print("VANITY_LIVE_PASS (ordinary tokens; no provider/image calls)", flush=True)


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except Exception as exc:
        print(
            "VANITY_LIVE_FAILED:", str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        )
        raise SystemExit(1) from None
