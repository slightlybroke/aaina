"""Temporary synthetic fixtures only; real Auth, RLS and fresh-login checks."""

import argparse
import asyncio
from uuid import uuid4

import httpx
from dotenv import dotenv_values

from app.config import Settings
from app.main import create_app
from app.repository import Supabase


def check(value, label):
    if not value:
        raise RuntimeError(label)
    print("PASS: " + label, flush=True)


async def run(use_gemini=False):
    s = Settings()
    env = dotenv_values(".env")
    check(
        s.supabase_url == "https://zouvroynucstxqimygzd.supabase.co", "confirmed development target"
    )
    async with httpx.AsyncClient(timeout=40) as h:
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
            check(r.status_code == 200, "ordinary Auth login")
            data = r.json()
            check(data["user"]["role"] == "authenticated", "ordinary authenticated role")
            return data["user"]["id"], {
                "Authorization": "Bearer " + data["access_token"],
                "apikey": s.supabase_publishable_key,
            }

        users = [await login(""), await login("_B")]
        check(users[0][0] != users[1][0], "distinct accounts")
        ids = [str(uuid4()), str(uuid4())]
        fixtures = []
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test", timeout=100
        ) as api:
            try:
                for i, (owner, headers) in enumerate(users):
                    item = ids[i]
                    fixtures.append((owner, item))
                    text = "Synthetic finish fixture " + uuid4().hex
                    data = {"category": "preference", "text": text, "share_with_ai": True}
                    r = await api.put("/v1/beauty-memories/" + item, headers=headers, json=data)
                    check(
                        r.status_code == 200 and r.json()["status"] == "confirmed",
                        "authenticated save confirmed fixture",
                    )
                    again = await api.put("/v1/beauty-memories/" + item, headers=headers, json=data)
                    check(
                        again.status_code == 200 and again.json()["version"] == 1,
                        "idempotent repeated save",
                    )
                    r = await h.get(
                        s.supabase_url + "/rest/v1/beauty_memories",
                        headers=headers,
                        params={"id": "eq." + item},
                    )
                    check(r.status_code == 200 and len(r.json()) == 1, "ordinary direct owner read")
                    r = await h.patch(
                        s.supabase_url + "/rest/v1/beauty_memories",
                        headers=headers,
                        params={"id": "eq." + item},
                        json={"text": "unauthorized"},
                    )
                    check(r.status_code in (401, 403), "ordinary direct writes denied")
                for i, (owner, headers) in enumerate(users):
                    foreign = ids[1 - i]
                    r = await h.get(
                        s.supabase_url + "/rest/v1/beauty_memories",
                        headers=headers,
                        params={"id": "eq." + foreign},
                    )
                    check(
                        r.status_code == 200 and r.json() == [],
                        "ordinary-token cross-owner RLS denial",
                    )
                    for method in ["GET", "DELETE"]:
                        r = await api.request(
                            method, "/v1/beauty-memories/" + foreign, headers=headers
                        )
                        check(r.status_code == 404, "cross-owner API " + method + " denial")
                    r = await api.put(
                        "/v1/beauty-memories/" + foreign,
                        headers=headers,
                        json={
                            "category": "preference",
                            "text": "foreign change",
                            "expected_version": 1,
                        },
                    )
                    check(r.status_code == 404, "cross-owner update denial")
                    r = await h.post(
                        s.supabase_url + "/rest/v1/rpc/search_beauty_memories",
                        headers=headers,
                        json={
                            "p_user": users[1 - i][0],
                            "p_query": "finish",
                            "p_for_ai": False,
                            "p_offset": 0,
                        },
                    )
                    check(r.status_code in (401, 403, 404), "ordinary privileged search RPC denied")
                owner, headers = users[0]
                item = ids[0]
                r = await api.put(
                    "/v1/beauty-memories/" + item,
                    headers=headers,
                    json={
                        "category": "preference",
                        "text": "Synthetic finish uncertain " + item,
                        "kind": "inference",
                        "share_with_ai": True,
                        "expected_version": 1,
                    },
                )
                check(
                    r.status_code == 200
                    and r.json()["status"] == "pending"
                    and not r.json()["share_with_ai"],
                    "inference held private for review",
                )
                r = await api.post(
                    "/v1/beauty-memories/" + item + "/confirm",
                    headers=headers,
                    json={"expected_version": 2, "share_with_ai": True},
                )
                check(
                    r.status_code == 200 and r.json()["kind"] == "inference",
                    "confirmation preserves inference",
                )
                if use_gemini:
                    response = await api.post(
                        "/v1/looks/conversation",
                        headers=headers,
                        json={
                            "consent_version": "gemini-look-v1",
                            "use_beauty_memory": True,
                            "messages": [
                                {
                                    "role": "user",
                                    "text": "For the synthetic fixture "
                                    + item
                                    + ", ask me whether I want a natural or bold makeup style.",
                                }
                            ],
                        },
                    )
                    check(
                        response.status_code == 200
                        and any(m["id"] == item for m in response.json().get("memory_context", [])),
                        "real Gemini conversation receives opted-in synthetic memory",
                    )
                    response = await api.post(
                        "/v1/education/lesson",
                        headers=headers,
                        json={
                            "topic": "sunscreen",
                            "question": "What does broad spectrum mean?",
                            "use_ai": True,
                            "consent_version": "beauty-education-v1",
                        },
                    )
                    check(
                        response.status_code == 200
                        and response.json()["status"] == "ai_selected_reviewed_facts",
                        "real Gemini selects validated education fact references",
                    )
                from app.beauty_memory import MemoryService

                memories = await MemoryService(repo).relevant(owner, item)
                check(any(m["id"] == item for m in memories), "confirmed shared context retrieved")
                r = await api.put(
                    "/v1/beauty-memories/" + item,
                    headers=headers,
                    json={
                        "category": "event",
                        "text": "Synthetic expired event " + item,
                        "expires_at": "2000-01-01T00:00:00Z",
                        "share_with_ai": True,
                        "expected_version": 3,
                    },
                )
                check(r.status_code == 200, "expired fixture saved for review")
                check(
                    not any(
                        m["id"] == item for m in await MemoryService(repo).relevant(owner, item)
                    ),
                    "expired context excluded",
                )
                _, fresh = await login("")
                r = await api.get("/v1/beauty-memories/" + item, headers=fresh)
                check(r.status_code == 200 and r.json()["version"] == 4, "fresh-login persistence")
                r = await api.post(
                    "/v1/education/lesson", headers=fresh, json={"topic": "sunscreen"}
                )
                check(
                    r.status_code == 200 and r.json()["status"] == "reference_only",
                    "authenticated reference lesson",
                )
            finally:
                failures = []
                for owner, item in fixtures:
                    try:
                        await repo.request(
                            "DELETE",
                            "/rest/v1/beauty_memories",
                            params={"id": "eq." + item, "user_id": "eq." + owner},
                        )
                        check(
                            not await repo.owned("beauty_memories", owner, id="eq." + item),
                            "temporary fixture deletion verified",
                        )
                    except Exception as e:
                        failures.append(type(e).__name__)
                if failures:
                    raise RuntimeError("Fixture cleanup failed: " + ",".join(failures))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--gemini",
        action="store_true",
        help="Two small synthetic-only Gemini requests; may consume credits.",
    )
    asyncio.run(run(parser.parse_args().gemini))
