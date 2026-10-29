"""Live Auth + Gemini route check. Only an exact synthetic category may reach Gemini."""

import asyncio
import hashlib
import json
from uuid import uuid4

import httpx
from dotenv import dotenv_values

from app.config import Settings
from app.gemini_looks import CONSENT
from app.main import create_app
from app.repository import Supabase
from app.skincare import SkincareService
from app.vanity import VanityItem, VanityService
from scripts.check_gemini_live import check


class RestrictedRepo:
    def __init__(self, repo, category):
        self.repo, self.category = repo, category

    async def owned(self, table, user, **filters):
        check(
            table == "vanity_items" and filters.get("category") == "eq." + self.category,
            "only exact synthetic category allowed into model workflow",
        )
        return await self.repo.owned(table, user, **filters)


async def run():
    s = Settings()
    env = dotenv_values(".env")
    check(
        s.supabase_url.rstrip("/") == "https://zouvroynucstxqimygzd.supabase.co",
        "confirmed dev project",
    )
    category = "gemini-fixture-" + uuid4().hex
    item_id = str(uuid4())
    owner = None
    created = False
    async with httpx.AsyncClient(follow_redirects=False, timeout=30) as http:
        repo = Supabase(s, http)
        reader = SkincareService(repo)
        users = []
        baselines = []
        for suffix in ["", "_B"]:
            response = await http.post(
                s.supabase_url + "/auth/v1/token?grant_type=password",
                headers={"apikey": s.supabase_publishable_key},
                json={
                    "email": env.get("LIVE_TEST_EMAIL" + suffix),
                    "password": env.get("LIVE_TEST_PASSWORD" + suffix),
                },
            )
            check(response.status_code == 200, "ordinary password login")
            data = response.json()
            check(data["user"]["role"] == "authenticated", "ordinary role")
            users.append((data["user"]["id"], {"Authorization": "Bearer " + data["access_token"]}))
            rows = await reader.all("vanity_items", data["user"]["id"], "id.asc")
            baselines.append(hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest())
        check(users[0][0] != users[1][0], "distinct test users")
        owner = users[0][0]
        try:
            await VanityService(repo).save(
                owner,
                item_id,
                VanityItem(
                    name="Synthetic Gemini live fixture",
                    brand="Synthetic fixture",
                    category=category,
                    shade_name="Synthetic rose",
                    finish="satin",
                ),
            )
            created = True
            app = create_app(s, RestrictedRepo(repo, category), http)
            body = {
                "consent_version": CONSENT,
                "messages": [
                    {
                        "role": "user",
                        "text": f"Plan now, custom style, only the exact category {category}. No shade or finish restriction. This category is literal. Do not ask a question; use my owned inventory.",
                    }
                ],
            }
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app), base_url="http://acceptance", timeout=110
            ) as api:
                for index, (uid, headers) in enumerate(users):
                    response = await api.post("/v1/looks/conversation", headers=headers, json=body)
                    check(
                        response.status_code == 200,
                        "live consented conversation route user " + str(index + 1),
                    )
                    data = response.json()
                    check(data["plan"] is not None, "real Gemini requested authorized plan")
                    suggestions = data["plan"]["suggestions"]
                    check(
                        len(suggestions) == (1 if index == 0 else 0),
                        "cross-user synthetic inventory isolation",
                    )
                    if index == 0:
                        check(
                            suggestions[0]["product"]["id"] == item_id
                            and data["ai_status"] == "grounded",
                            "owned fixture and Gemini explanation references verified",
                        )
        finally:
            if owner and created:
                await repo.request(
                    "DELETE",
                    "/rest/v1/vanity_items",
                    params={"id": "eq." + item_id, "user_id": "eq." + owner},
                )
                check(
                    not await repo.owned("vanity_items", owner, id="eq." + item_id),
                    "exact fixture cleanup verified",
                )
            for index, (uid, _) in enumerate(users):
                rows = await reader.all("vanity_items", uid, "id.asc")
                check(
                    hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()
                    == baselines[index],
                    "original inventory unchanged",
                )
        print(
            "GEMINI_OWNED_LIVE_PASS (ordinary Auth + real Gemini + synthetic category only)",
            flush=True,
        )


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except Exception as exc:
        print(
            "GEMINI_OWNED_LIVE_FAILED:",
            str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__,
        )
        raise SystemExit(1) from None
