"""Local relay handshake using ordinary Auth; no audio or inventory is submitted."""

import asyncio
import json

import httpx
from dotenv import dotenv_values
from websockets.asyncio.client import connect

from app.config import Settings
from app.live_voice import LIVE_CONSENT


async def run():
    settings = Settings()
    assert settings.supabase_url == "https://zouvroynucstxqimygzd.supabase.co"
    env = dotenv_values(".env")
    async with connect("ws://127.0.0.1:8000/v1/looks/live") as ws:
        await ws.send(json.dumps({"access_token": "forged", "consent_version": LIVE_CONSENT}))
        assert json.loads(await asyncio.wait_for(ws.recv(), 10))["type"] == "error"
    print("PASS: running relay rejects forged session before audio", flush=True)
    async with httpx.AsyncClient(timeout=30) as http:
        response = await http.post(
            settings.supabase_url + "/auth/v1/token?grant_type=password",
            headers={"apikey": settings.supabase_publishable_key},
            json={"email": env.get("LIVE_TEST_EMAIL"), "password": env.get("LIVE_TEST_PASSWORD")},
        )
        assert response.status_code == 200, "ordinary test login failed"
        session = response.json()
        assert session["user"]["role"] == "authenticated"
    async with connect("ws://127.0.0.1:8000/v1/looks/live") as ws:
        await ws.send(
            json.dumps({"access_token": session["access_token"], "consent_version": LIVE_CONSENT})
        )
        event = json.loads(await asyncio.wait_for(ws.recv(), 45))
        assert event["type"] == "ready", "Live relay was not ready"
        assert event["input_rate"] == 16000 and event["output_rate"] == 24000
        await ws.send(json.dumps({"type": "stop"}))
    print("PASS: ordinary authenticated relay, real provider setup and explicit Stop", flush=True)
    print("LIVE_VOICE_AUTH_PASS (no audio, inventory or database writes)", flush=True)


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except Exception as exc:
        print("LIVE_VOICE_AUTH_FAILED:", type(exc).__name__)
        raise SystemExit(1) from None
