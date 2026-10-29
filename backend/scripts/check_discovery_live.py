"""Read-only catalogue acceptance plus denied ordinary writes; no private inventory changes."""

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


async def run():
    s = Settings()
    env = dotenv_values(".env")
    check(
        s.supabase_url == "https://zouvroynucstxqimygzd.supabase.co",
        "confirmed development project",
    )
    async with httpx.AsyncClient(timeout=30, follow_redirects=False) as h:
        repo = Supabase(s, h)
        app = create_app(s, repo, h)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as api:
            for suffix in ["", "_B", ""]:
                r = await h.post(
                    s.supabase_url + "/auth/v1/token?grant_type=password",
                    headers={"apikey": s.supabase_publishable_key},
                    json={
                        "email": env.get("LIVE_TEST_EMAIL" + suffix),
                        "password": env.get("LIVE_TEST_PASSWORD" + suffix),
                    },
                )
                check(r.status_code == 200, "ordinary/fresh login")
                headers = {
                    "apikey": s.supabase_publishable_key,
                    "Authorization": "Bearer " + r.json()["access_token"],
                }
                rows = await h.get(
                    s.supabase_url + "/rest/v1/discovery_products",
                    headers=headers,
                    params={"select": "id", "active": "eq.true"},
                )
                check(
                    rows.status_code == 200 and len(rows.json()) == 6,
                    "six shared reviewed records visible with ordinary token",
                )
                # A nonexistent UUID avoids even a weak policy changing a real record.
                denied = await h.patch(
                    s.supabase_url + "/rest/v1/discovery_products",
                    headers=headers,
                    params={"id": "eq." + str(uuid4())},
                    json={"active": False},
                )
                check(denied.status_code in {401, 403}, "ordinary catalogue writes denied")
                result = await api.get(
                    "/v1/discovery",
                    headers=headers,
                    params={"q": "Dirty Talk", "category": "lipstick"},
                )
                check(
                    result.status_code == 200 and len(result.json()["items"]) == 1,
                    "live indexed search through authenticated backend",
                )
                check(result.json()["exact_vto_available"] is False, "no exact VTO claim")
                missing = await api.get(
                    "/v1/discovery", headers=headers, params={"q": "nonexistentcataloguefixture"}
                )
                check(missing.status_code == 200 and not missing.json()["items"], "empty result")
            anonymous = await h.get(
                s.supabase_url + "/rest/v1/discovery_products",
                headers={"apikey": s.supabase_publishable_key},
            )
            check(anonymous.status_code in {401, 403}, "anonymous direct catalogue access denied")
    print(
        "LIVE_DISCOVERY_PASS: shared catalogue reads/search/fresh login; no catalogue or Vanity mutations."
    )


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except Exception as exc:
        print(
            "LIVE_DISCOVERY_BLOCKED:",
            str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__,
        )
        raise SystemExit(1) from None
