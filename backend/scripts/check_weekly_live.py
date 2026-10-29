"""Real ordinary-user weekly report acceptance. Deletes only newly created report fixtures."""

import asyncio
from uuid import uuid4

import httpx
from dotenv import dotenv_values

from app.config import Settings
from app.domain import utcnow
from app.main import create_app
from app.repository import Supabase
from app.weekly_reports import previous_week


def check(value, label):
    if not value:
        raise RuntimeError(label)
    print("PASS: " + label, flush=True)


async def run():
    s = Settings()
    env = dotenv_values(".env")
    check(
        s.supabase_url == "https://zouvroynucstxqimygzd.supabase.co", "confirmed development target"
    )
    async with httpx.AsyncClient(timeout=45) as h:
        repo = Supabase(s, h)
        app = create_app(s, repo, h)

        async def login(suffix):
            r = await h.post(
                s.supabase_url + "/auth/v1/token?grant_type=password",
                headers={"apikey": s.supabase_publishable_key},
                json={
                    "email": env.get("LIVE_TEST_EMAIL" + suffix),
                    "password": env.get("LIVE_TEST_PASSWORD" + suffix),
                },
            )
            check(r.status_code == 200, "real ordinary Auth login")
            data = r.json()
            check(data["user"]["role"] == "authenticated", "ordinary role")
            return data["user"]["id"], {
                "Authorization": "Bearer " + data["access_token"],
                "apikey": s.supabase_publishable_key,
            }

        users = [await login(""), await login("_B")]
        check(users[0][0] != users[1][0], "distinct users")
        weeks = {}
        fixtures = []
        temporary_settings = []
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test", timeout=90
        ) as api:
            try:
                # Refuse to modify or delete any pre-existing report/read status.
                for owner, _ in users:
                    settings = await repo.owned("skincare_settings", owner)
                    if not settings:
                        stamp = utcnow().isoformat()
                        temporary_settings.append((owner, stamp))
                        await repo.request(
                            "POST",
                            "/rest/v1/skincare_settings",
                            params={"on_conflict": "user_id"},
                            json={"user_id": owner, "timezone": "UTC", "updated_at": stamp},
                            headers={"Prefer": "resolution=ignore-duplicates"},
                        )
                        settings = await repo.owned("skincare_settings", owner)
                        check(bool(settings), "temporary UTC test settings created")
                    week, _ = previous_week(utcnow(), settings[0]["timezone"])
                    weeks[owner] = str(week)
                    check(
                        not await repo.owned("weekly_reports", owner, week_start="eq." + str(week)),
                        "no pre-existing report for test period",
                    )
                check(
                    (await api.get("/v1/weekly-reports")).status_code == 401,
                    "anonymous report API denied",
                )
                reports = []
                for owner, headers in users:
                    # Track scope before request so an interrupted response still cleans only the originally empty slot.
                    fixtures.append(owner)
                    r = await api.post("/v1/weekly-reports/generate", headers=headers)
                    check(r.status_code == 200, "authenticated weekly generation")
                    item = r.json()
                    reports.append(item)
                    check(
                        item["read_at"] is None and item["week_start"] == weeks[owner],
                        "atomic unread notification and local week",
                    )
                    repeat = await api.post("/v1/weekly-reports/generate", headers=headers)
                    check(
                        repeat.status_code == 200 and repeat.json()["id"] == item["id"],
                        "idempotent report generation",
                    )
                    count = await repo.owned(
                        "weekly_reports", owner, week_start="eq." + weeks[owner]
                    )
                    check(len(count) == 1, "one report per owner/week")
                    r = await h.get(
                        s.supabase_url + "/rest/v1/weekly_reports",
                        headers=headers,
                        params={"id": "eq." + item["id"]},
                    )
                    check(r.status_code == 200 and len(r.json()) == 1, "ordinary owner direct read")
                for i, (owner, headers) in enumerate(users):
                    foreign = reports[1 - i]["id"]
                    own = reports[i]["id"]
                    inserted = await h.post(
                        s.supabase_url + "/rest/v1/weekly_reports",
                        headers=headers,
                        json={
                            "user_id": owner,
                            "week_start": weeks[owner],
                            "week_end": reports[i]["week_end"],
                            "timezone": "UTC",
                            "content": {},
                        },
                    )
                    check(inserted.status_code in (401, 403), "ordinary direct INSERT denied")
                    spoofed = await api.post(
                        "/v1/weekly-reports/generate",
                        headers=headers,
                        json={"user_id": users[1 - i][0]},
                    )
                    check(spoofed.status_code == 422, "client-supplied report owner rejected")
                    r = await h.get(
                        s.supabase_url + "/rest/v1/weekly_reports",
                        headers=headers,
                        params={"id": "eq." + foreign},
                    )
                    check(
                        r.status_code == 200 and r.json() == [], "ordinary cross-owner RLS denial"
                    )
                    check(
                        (
                            await api.get("/v1/weekly-reports/" + foreign, headers=headers)
                        ).status_code
                        == 404,
                        "cross-owner report API denial",
                    )
                    check(
                        (
                            await api.post(
                                "/v1/weekly-reports/" + foreign + "/read", headers=headers
                            )
                        ).status_code
                        == 404,
                        "cross-owner notification write denial",
                    )
                    for method in ["PATCH", "DELETE"]:
                        r = await h.request(
                            method,
                            s.supabase_url + "/rest/v1/weekly_reports",
                            headers=headers,
                            params={"id": "eq." + own},
                            **(
                                {"json": {"read_at": utcnow().isoformat()}}
                                if method == "PATCH"
                                else {}
                            ),
                        )
                        check(r.status_code in (401, 403), "ordinary direct " + method + " denied")
                    r = await api.post("/v1/weekly-reports/" + own + "/read", headers=headers)
                    check(
                        r.status_code == 200 and r.json()["read_at"],
                        "owner read acknowledgement persisted",
                    )
                    repeat = await api.post("/v1/weekly-reports/" + own + "/read", headers=headers)
                    check(
                        repeat.json()["read_at"] == r.json()["read_at"],
                        "read acknowledgement idempotent",
                    )
                _, fresh = await login("")
                r = await api.get("/v1/weekly-reports/" + reports[0]["id"], headers=fresh)
                check(
                    r.status_code == 200 and r.json()["read_at"],
                    "fresh-login report and read-state persistence",
                )
                # No phantom body/user authority and no access to invented identifiers.
                check(
                    (await api.get("/v1/weekly-reports/" + str(uuid4()), headers=fresh)).status_code
                    == 404,
                    "unknown report safely missing",
                )
            finally:
                failed = []
                for owner in fixtures:
                    try:
                        await repo.request(
                            "DELETE",
                            "/rest/v1/weekly_reports",
                            params={"user_id": "eq." + owner, "week_start": "eq." + weeks[owner]},
                        )
                        check(
                            not await repo.owned(
                                "weekly_reports", owner, week_start="eq." + weeks[owner]
                            ),
                            "temporary report fixture deletion verified",
                        )
                    except Exception as e:
                        failed.append(type(e).__name__)
                for owner, stamp in temporary_settings:
                    try:
                        await repo.request(
                            "DELETE",
                            "/rest/v1/skincare_settings",
                            params={"user_id": "eq." + owner, "updated_at": "eq." + stamp},
                        )
                        remaining = await repo.owned(
                            "skincare_settings", owner, updated_at="eq." + stamp
                        )
                        check(not remaining, "temporary timezone fixture deletion verified")
                    except Exception as e:
                        failed.append(type(e).__name__)
                if failed:
                    raise RuntimeError("Report cleanup failed: " + ",".join(failed))


if __name__ == "__main__":
    asyncio.run(run())
