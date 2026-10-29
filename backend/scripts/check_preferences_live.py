"""Temporary explicit preferences + ordinary-user isolation; optional synthetic Gemini check."""

import argparse
import asyncio
from uuid import uuid4

import httpx
from dotenv import dotenv_values

from app.config import Settings
from app.main import create_app
from app.makeup_preferences import MakeupPreferences, PreferenceService
from app.repository import Supabase
from app.vanity import VanityItem, VanityService


def check(condition, label):
    if not condition:
        raise RuntimeError(label)
    print("PASS: " + label, flush=True)


async def run(use_gemini):
    s = Settings()
    check(
        s.supabase_url == "https://zouvroynucstxqimygzd.supabase.co",
        "confirmed development project",
    )
    env = dotenv_values(".env")
    async with httpx.AsyncClient(timeout=40, follow_redirects=False) as h:
        repo = Supabase(s, h)
        service = PreferenceService(repo)
        users = []
        for suffix in ["", "_B"]:
            r = await h.post(
                s.supabase_url + "/auth/v1/token?grant_type=password",
                headers={"apikey": s.supabase_publishable_key},
                json={
                    "email": env.get("LIVE_TEST_EMAIL" + suffix),
                    "password": env.get("LIVE_TEST_PASSWORD" + suffix),
                },
            )
            check(r.status_code == 200, "ordinary login")
            data = r.json()
            check(data["user"]["role"] == "authenticated", "ordinary role")
            user = data["user"]["id"]
            headers = {
                "Authorization": "Bearer " + data["access_token"],
                "apikey": s.supabase_publishable_key,
            }
            baseline = await service.get(user)
            check(
                baseline["source"] is None, "dedicated test profile empty before temporary fixture"
            )
            users.append((user, headers))
        check(users[0][0] != users[1][0], "distinct accounts")
        fixture_id = str(uuid4())
        category = "pref-fixture-" + uuid4().hex
        created = False
        written = []
        try:
            for index, (user, headers) in enumerate(users):
                body = MakeupPreferences(
                    preferred_finish="satin" if index == 0 else "matte",
                    excluded_categories=["foundation"],
                )
                await service.save(user, body)
                written.append(user)
                await service.save(user, body)
                rows = await repo.owned("makeup_preferences", user)
                check(len(rows) == 1, "repeated preference save remains one row")
                other = users[1 - index][0]
                r = await h.get(
                    s.supabase_url + "/rest/v1/makeup_preferences",
                    headers=headers,
                    params={"user_id": "eq." + other},
                )
                check(
                    r.status_code == 200 and r.json() == [],
                    "ordinary-token cross-user profile denial",
                )
                denied = await h.patch(
                    s.supabase_url + "/rest/v1/makeup_preferences",
                    headers=headers,
                    params={"user_id": "eq." + user},
                    json={"preferred_finish": "spoof"},
                )
                check(denied.status_code in {401, 403}, "direct ordinary profile mutation denied")
            # Both fixtures now exist, so neither direction can pass just because the
            # other owner's row has not been created yet.
            for index, (user, headers) in enumerate(users):
                response = await h.get(
                    s.supabase_url + "/rest/v1/makeup_preferences",
                    headers=headers,
                    params={"user_id": "eq." + users[1 - index][0]},
                )
                check(
                    response.status_code == 200 and response.json() == [],
                    "both-existing ordinary-token profile isolation",
                )
            app = create_app(s, repo, h)
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test", timeout=100
            ) as api:
                r = await api.get("/v1/makeup-preferences", headers=users[0][1])
                check(
                    r.status_code == 200 and r.json()["preferred_finish"] == "satin",
                    "authenticated preference route reads owner data",
                )
                saved = await api.put(
                    "/v1/makeup-preferences",
                    headers=users[0][1],
                    json={"preferred_finish": "satin", "excluded_categories": ["foundation"]},
                )
                check(
                    saved.status_code == 200 and saved.json()["preferred_finish"] == "satin",
                    "authenticated preference save route",
                )
                check(
                    (
                        await api.put(
                            "/v1/makeup-preferences",
                            headers=users[0][1],
                            json={"user_id": users[1][0]},
                        )
                    ).status_code
                    == 422,
                    "client-supplied owner rejected",
                )
            # Fresh password login reads persisted profile through actual Auth again.
            r = await h.post(
                s.supabase_url + "/auth/v1/token?grant_type=password",
                headers={"apikey": s.supabase_publishable_key},
                json={
                    "email": env.get("LIVE_TEST_EMAIL"),
                    "password": env.get("LIVE_TEST_PASSWORD"),
                },
            )
            r.raise_for_status()
            fresh = {"Authorization": "Bearer " + r.json()["access_token"]}
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            ) as api:
                check(
                    (await api.get("/v1/makeup-preferences", headers=fresh)).json()[
                        "preferred_finish"
                    ]
                    == "satin",
                    "fresh-login preference persistence",
                )
            if use_gemini:
                owner = users[0][0]
                await VanityService(repo).save(
                    owner,
                    fixture_id,
                    VanityItem(
                        name="Synthetic preference fixture",
                        brand="Fixture",
                        category=category,
                        finish="satin",
                    ),
                )
                created = True

                class Restricted:
                    async def owned(self, table, user, **filters):
                        check(
                            user == owner
                            and (
                                table == "makeup_preferences"
                                or (
                                    table == "vanity_items"
                                    and filters.get("category") == "eq." + category
                                )
                            ),
                            "only synthetic requested context read",
                        )
                        return await repo.owned(table, user, **filters)

                synthetic_app = create_app(s, Restricted(), h)
                async with httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=synthetic_app),
                    base_url="http://test",
                    timeout=100,
                ) as api:
                    response = await api.post(
                        "/v1/looks/conversation",
                        headers=fresh,
                        json={
                            "consent_version": "gemini-look-v1",
                            "use_saved_preferences": True,
                            "messages": [
                                {
                                    "role": "user",
                                    "text": "Plan only my custom category "
                                    + category
                                    + " using my saved preferences. No other categories please.",
                                }
                            ],
                        },
                    )
                    check(
                        response.status_code == 200, "real Gemini preference-context conversation"
                    )
                    plan = response.json()["plan"]
                    check(
                        plan is not None and plan["context"]["preferred_finish"] == "satin",
                        "persisted saved finish used in actual plan",
                    )
                    check(
                        len(plan["suggestions"]) == 1
                        and plan["suggestions"][0]["product"]["id"] == fixture_id,
                        "only owned synthetic product selected",
                    )
        finally:
            if created:
                await VanityService(repo).delete(users[0][0], fixture_id)
            for user in written:
                await service.delete(user)
                check((await service.get(user))["source"] is None, "temporary preferences removed")
        print(
            "LIVE_PREFERENCES_PASS"
            + (" (real Gemini, synthetic context only)" if use_gemini else " (no Gemini call)"),
            flush=True,
        )


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--gemini", action="store_true")
    args = p.parse_args()
    try:
        asyncio.run(run(args.gemini))
    except Exception as exc:
        print(
            "LIVE_PREFERENCES_BLOCKED:",
            str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__,
        )
        raise SystemExit(1) from None
