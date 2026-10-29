"""Live Phase 2 acceptance: ordinary tokens prove isolation; exact disposable fixtures only.

No image, Storage mutation, worker or YouCam request. Run from backend/.
"""

import asyncio
import hashlib
import json
from uuid import uuid4

import httpx
from dotenv import dotenv_values

from app.config import Settings
from app.domain import utcnow
from app.main import create_app
from app.repository import Supabase


def check(condition, label):
    if not condition:
        raise RuntimeError(label)
    print("PASS:", label, flush=True)


def fingerprint(rows):
    return hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()


async def run():
    settings = Settings()
    check(
        settings.supabase_url.rstrip("/") == "https://zouvroynucstxqimygzd.supabase.co",
        "confirmed development project",
    )
    env = dotenv_values(".env")
    async with httpx.AsyncClient(timeout=30, follow_redirects=False) as http:
        repo = Supabase(settings, http)
        app = create_app(settings, repo, http)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app), base_url="http://acceptance"
        ) as api:

            async def login(suffix):
                email, password = (
                    env.get("LIVE_TEST_EMAIL" + suffix),
                    env.get("LIVE_TEST_PASSWORD" + suffix),
                )
                check(bool(email and password), "test account configuration " + (suffix or "A"))
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
                    "headers": {
                        "Authorization": "Bearer " + data["access_token"],
                        "apikey": settings.supabase_publishable_key,
                    },
                    "suffix": suffix,
                }

            users = [await login(""), await login("_B")]
            check(users[0]["uid"] != users[1]["uid"], "distinct ordinary test users")
            fixtures, settings_fixtures = [], []
            baselines = []
            for user in users:
                before = await api.get("/v1/analyses", headers=user["headers"])
                check(before.status_code == 200, "existing Phase 1 history readable")
                baselines.append(fingerprint(before.json()))
            cleanup_failures = []
            try:
                for index, user in enumerate(users):
                    rid, sid, tid, jid = [str(uuid4()) for _ in range(4)]
                    fixture = {"rid": rid, "jid": jid, "sid": sid, "uid": user["uid"]}
                    fixtures.append(fixture)
                    if not await repo.owned("skincare_settings", user["uid"]):
                        created = await repo.request(
                            "POST",
                            "/rest/v1/skincare_settings",
                            json={"user_id": user["uid"], "timezone": "UTC"},
                            headers={"Prefer": "return=representation"},
                        )
                        settings_fixtures.append(created.json()[0])
                    headers = user["headers"]
                    body = {
                        "name": "Disposable Phase 2 acceptance",
                        "kind": "custom",
                        "status": "active",
                        "days": [1, 2, 3, 4, 5, 6, 7],
                        "steps": [
                            {"id": sid, "name": "First test step"},
                            {"id": tid, "name": "Second test step"},
                        ],
                    }
                    response = await api.put(
                        f"/v1/skincare/routines/{rid}", headers=headers, json=body
                    )
                    check(response.status_code == 200, "user %s routine create" % (index + 1))
                    revision = response.json()
                    fixture["revision"] = revision["id"]
                    state = await api.get("/v1/skincare/routines", headers=headers)
                    check(state.status_code == 200, "routine retrieval")
                    today = state.json()["today"]
                    payload = {
                        "local_date": today,
                        "revision_id": revision["id"],
                        "completed_steps": [sid],
                    }
                    path = f"/v1/skincare/routines/{rid}/checkins"
                    first = await api.put(path, headers=headers, json=payload)
                    repeat = await api.put(path, headers=headers, json=payload)
                    check(
                        first.status_code == repeat.status_code == 200
                        and first.json()["id"] == repeat.json()["id"],
                        "idempotent daily check-in",
                    )
                    fixture["checkin"] = first.json()["id"]
                    rows = await repo.owned("routine_checkins", user["uid"], routine_id="eq." + rid)
                    check(len(rows) == 1, "one persisted check-in after retry")
                    state = (await api.get("/v1/skincare/routines", headers=headers)).json()
                    own = next(r for r in state["routines"] if r["routine_id"] == rid)
                    check(own["completion"] == "partial", "partial completion persisted")
                    for steps in ([sid, tid], [], [sid, tid]):
                        payload["completed_steps"] = steps
                        check(
                            (await api.put(path, headers=headers, json=payload)).status_code == 200,
                            "check-in correction",
                        )
                    history = (await api.get("/v1/skincare/history", headers=headers)).json()
                    check(
                        next(
                            d
                            for d in history["days"]
                            if d["routine_id"] == rid and d["local_date"] == today
                        )["completion"]
                        == "complete",
                        "complete state in history",
                    )
                    check(
                        next(s for s in history["summary"]["routines"] if s["routine_id"] == rid)[
                            "current_streak"
                        ]
                        == 1,
                        "persisted streak calculation",
                    )
                    body.update(
                        {
                            "name": "Edited acceptance",
                            "status": "archived",
                            "expected_revision": revision["id"],
                            "steps": [{"id": tid, "name": "Changed"}],
                        }
                    )
                    edited = await api.put(
                        f"/v1/skincare/routines/{rid}", headers=headers, json=body
                    )
                    check(
                        edited.status_code == 200 and edited.json()["effective_from"] > today,
                        "archive/edit starts tomorrow",
                    )
                    stale = await api.put(
                        f"/v1/skincare/routines/{rid}", headers=headers, json=body
                    )
                    check(stale.status_code == 409, "stale edit rejected")
                    rows = await repo.owned("routine_checkins", user["uid"], routine_id="eq." + rid)
                    check(
                        rows[0]["revision_id"] == revision["id"]
                        and rows[0]["completed_steps"] == [sid, tid],
                        "historical completion preserved after edit",
                    )
                    entry = {
                        "concerns": ["dryness", "texture"],
                        "severity": "mild",
                        "notes": "Disposable acceptance observation",
                        "observed_at": utcnow().isoformat(),
                    }
                    response = await api.put(
                        f"/v1/skincare/journal/{jid}", headers=headers, json=entry
                    )
                    check(response.status_code == 200, "journal create")
                    entry["notes"] = "Corrected disposable observation"
                    response = await api.put(
                        f"/v1/skincare/journal/{jid}", headers=headers, json=entry
                    )
                    check(
                        response.status_code == 200 and response.json()["notes"] == entry["notes"],
                        "journal edit",
                    )

                for index, user in enumerate(users):
                    own, other = fixtures[index], fixtures[1 - index]
                    for table, field, key in [
                        ("routines", "id", "rid"),
                        ("routine_revisions", "id", "revision"),
                        ("routine_checkins", "id", "checkin"),
                        ("skin_journal", "id", "jid"),
                        ("skincare_settings", "user_id", "uid"),
                    ]:
                        for label, fixture, count in [("own", own, 1), ("other", other, 0)]:
                            params = {field: "eq." + fixture[key], "select": field}
                            response = await http.get(
                                settings.supabase_url + "/rest/v1/" + table,
                                headers=user["headers"],
                                params=params,
                            )
                            check(
                                response.status_code == 200 and len(response.json()) == count,
                                f"user {index + 1} {table} {label} RLS read",
                            )
                            for method in ("PATCH", "DELETE"):
                                kwargs = (
                                    {"json": {"user_id": user["uid"]}} if method == "PATCH" else {}
                                )
                                denied = await http.request(
                                    method,
                                    settings.supabase_url + "/rest/v1/" + table,
                                    headers=user["headers"],
                                    params=params,
                                    **kwargs,
                                )
                                check(
                                    denied.status_code in (401, 403),
                                    f"{table} {label} direct {method} denied",
                                )
                        denied = await http.post(
                            settings.supabase_url + "/rest/v1/" + table,
                            headers=user["headers"],
                            json={"user_id": user["uid"]},
                        )
                        check(denied.status_code in (401, 403), f"{table} direct insert denied")
                    denied = await http.post(
                        settings.supabase_url + "/rest/v1/rpc/skincare_write",
                        headers=user["headers"],
                        json={
                            "p_user": other["uid"],
                            "p_action": "journal_delete",
                            "p_data": {"id": other["jid"]},
                        },
                    )
                    check(
                        denied.status_code in (401, 403),
                        "ordinary user cannot invoke privileged RPC",
                    )
                    wrong = await api.put(
                        f"/v1/skincare/routines/{other['rid']}/checkins",
                        headers=user["headers"],
                        json={
                            "local_date": utcnow().date().isoformat(),
                            "revision_id": other["revision"],
                            "completed_steps": [],
                        },
                    )
                    check(wrong.status_code == 404, "API cross-user check-in denied")
                    wrong = await api.delete(
                        f"/v1/skincare/journal/{other['jid']}", headers=user["headers"]
                    )
                    check(wrong.status_code == 404, "API cross-user journal delete denied")
                    wrong = await api.put(
                        f"/v1/skincare/routines/{other['rid']}",
                        headers=user["headers"],
                        json={
                            "name": "Unauthorized",
                            "days": [1],
                            "steps": [{"id": own["sid"], "name": "Test"}],
                        },
                    )
                    check(wrong.status_code == 404, "API cross-user routine edit denied")
                    journal = (
                        await api.get("/v1/skincare/journal", headers=user["headers"])
                    ).json()
                    check(
                        any(e["id"] == own["jid"] for e in journal)
                        and all(e["id"] != other["jid"] for e in journal),
                        "API journal ownership",
                    )
                    logout = await http.post(
                        settings.supabase_url + "/auth/v1/logout?scope=local",
                        headers=user["headers"],
                    )
                    check(logout.status_code in (200, 204), "actual session sign-out")
                    fresh = await login(user["suffix"])
                    state = (
                        await api.get("/v1/skincare/routines", headers=fresh["headers"])
                    ).json()
                    check(
                        next(r for r in state["routines"] if r["routine_id"] == own["rid"])[
                            "completion"
                        ]
                        == "complete",
                        "routine/check-in survives fresh login",
                    )
                    journal = (
                        await api.get("/v1/skincare/journal", headers=fresh["headers"])
                    ).json()
                    check(
                        any(
                            e["id"] == own["jid"]
                            and e["notes"] == "Corrected disposable observation"
                            for e in journal
                        ),
                        "journal survives fresh login",
                    )
                    before_delete = await api.delete(
                        f"/v1/skincare/journal/{own['jid']}", headers=fresh["headers"]
                    )
                    check(before_delete.status_code == 200, "own journal deletion")
                    after = await api.get("/v1/analyses", headers=fresh["headers"])
                    check(
                        after.status_code == 200 and fingerprint(after.json()) == baselines[index],
                        "Phase 1 history unchanged across fresh login",
                    )
            finally:
                for fixture in fixtures:
                    for table, field, key in [
                        ("routine_checkins", "routine_id", "rid"),
                        ("routines", "id", "rid"),
                        ("skin_journal", "id", "jid"),
                    ]:
                        try:
                            await repo.request(
                                "DELETE",
                                "/rest/v1/" + table,
                                params={
                                    field: "eq." + fixture[key],
                                    "user_id": "eq." + fixture["uid"],
                                },
                            )
                            check(
                                not await repo.owned(
                                    table, fixture["uid"], **{field: "eq." + fixture[key]}
                                ),
                                "disposable " + table + " cleanup verified",
                            )
                        except Exception:
                            cleanup_failures.append(table)
                for fixture in settings_fixtures:
                    try:
                        await repo.request(
                            "DELETE",
                            "/rest/v1/skincare_settings",
                            params={
                                "user_id": "eq." + fixture["user_id"],
                                "updated_at": "eq." + fixture["updated_at"],
                            },
                        )
                    except Exception:
                        cleanup_failures.append("skincare_settings")
                check(not cleanup_failures, "all disposable fixture cleanup completed")
            print(
                "PHASE2_LIVE_PASS (API + ordinary Supabase tokens; no YouCam request)", flush=True
            )


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except Exception as exc:
        print(
            "PHASE2_LIVE_FAILED:", str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        )
        raise SystemExit(1) from None
