"""Read-only resource acceptance for the deterministic planner; uses existing test inventory."""

import asyncio
import hashlib
import json

import httpx
from dotenv import dotenv_values

from app.config import Settings
from app.look_planner import LookRequest, plan_look
from app.main import create_app
from app.repository import Supabase
from app.skincare import SkincareService


def check(condition, label):
    if not condition:
        raise RuntimeError(label)
    print("PASS:", label, flush=True)


def fingerprint(rows):
    return hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()


async def run():
    s = Settings()
    values = dotenv_values(".env")
    check(
        s.supabase_url.rstrip("/") == "https://zouvroynucstxqimygzd.supabase.co",
        "confirmed development project",
    )
    async with httpx.AsyncClient(timeout=30) as upstream:
        repo = Supabase(s, upstream)
        reader = SkincareService(repo)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(create_app(s, repo, upstream)),
            base_url="http://acceptance",
        ) as api:
            check(
                (await api.post("/v1/looks/plan", json={})).status_code == 401,
                "unauthenticated planning denied",
            )
            identities = []
            for suffix in ["", "_B"]:
                check(
                    bool(
                        values.get("LIVE_TEST_EMAIL" + suffix)
                        and values.get("LIVE_TEST_PASSWORD" + suffix)
                    ),
                    "test account configuration",
                )
                response = await upstream.post(
                    s.supabase_url + "/auth/v1/token?grant_type=password",
                    headers={"apikey": s.supabase_publishable_key},
                    json={
                        "email": values["LIVE_TEST_EMAIL" + suffix],
                        "password": values["LIVE_TEST_PASSWORD" + suffix],
                    },
                )
                check(response.status_code == 200, "ordinary password login")
                data = response.json()
                check(data["user"]["role"] == "authenticated", "ordinary role")
                uid = data["user"]["id"]
                identities.append(uid)
                rows = await reader.all("vanity_items", uid, "id.asc")
                before = fingerprint(rows)
                # Custom categories deliberately reflect actual stored labels, not invented test facts.
                categories = list(dict.fromkeys(r["category"] for r in rows))[:12]
                body = LookRequest(style="custom", categories=categories)
                headers = {"Authorization": "Bearer " + data["access_token"]}
                response = await api.post("/v1/looks/plan", headers=headers, json=body.model_dump())
                check(response.status_code == 200, "live planner route")
                result = response.json()
                check(result == plan_look(rows, body), "plan reflects actual owned metadata")
                ids = {r["id"] for r in rows}
                check(
                    all(p["product"]["id"] in ids for p in result["suggestions"]),
                    "suggestions restricted to verified owner",
                )
                check(
                    (
                        await api.post(
                            "/v1/looks/plan", headers=headers, json={"user_id": "forged"}
                        )
                    ).status_code
                    == 422,
                    "client owner injection denied",
                )
                repeated = await api.post("/v1/looks/plan", headers=headers, json=body.model_dump())
                check(repeated.json() == result, "repeat request deterministic")
                check(
                    fingerprint(await reader.all("vanity_items", uid, "id.asc")) == before,
                    "inventory unchanged",
                )
                print(
                    "INFO: existing inventory count",
                    len(rows),
                    "suggestions",
                    len(result["suggestions"]),
                    flush=True,
                )
            check(len(set(identities)) == 2, "separate test identities")
            print(
                "LOOKS_LIVE_PASS (existing inventory only; no fixtures or provider calls)",
                flush=True,
            )


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except Exception as exc:
        print(
            "LOOKS_LIVE_FAILED:", str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        )
        raise SystemExit(1) from None
