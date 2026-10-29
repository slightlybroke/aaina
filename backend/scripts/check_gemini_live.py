"""Live Gemini smoke using synthetic text/products only; no Supabase or personal data."""

import asyncio
from uuid import uuid4

import httpx

from app.config import Settings
from app.gemini_looks import CONSENT, Conversation, ConversationService, Gemini


def check(condition, label):
    if not condition:
        raise RuntimeError(label)
    print("PASS:", label, flush=True)


class SyntheticRepo:
    async def owned(self, table, user, **filters):
        check(
            table == "vanity_items" and filters["category"] == "eq.lipstick",
            "only requested synthetic category read",
        )
        check("notes" not in filters["select"], "notes excluded")
        return [
            {
                "id": "synthetic-product",
                "name": "Synthetic demo lipstick",
                "brand": "Synthetic fixture",
                "category": "lipstick",
                "shade_name": "Demo rose",
                "shade_identifier": "DEMO-1",
                "finish": "satin",
                "undertone": "",
            }
        ]


async def run():
    settings = Settings()
    check(bool(settings.gemini_api_key.get_secret_value()), "backend Gemini key configured")
    print("INFO: configured model", settings.gemini_model, flush=True)
    async with httpx.AsyncClient(follow_redirects=False) as client:
        service = ConversationService(SyntheticRepo(), Gemini(settings, client))
        messages = [
            {
                "role": "user",
                "text": "I have not decided between a natural and bold look. Ask me which style I prefer before planning.",
            }
        ]
        first = await service.respond(
            str(uuid4()), Conversation(consent_version=CONSENT, messages=messages)
        )
        check(
            first["ai_status"] == "clarification" and first["plan"] is None,
            "real Gemini clarifying question",
        )
        messages += [
            {"role": "assistant", "text": first["reply"]},
            {
                "role": "user",
                "text": "Use custom categories: lipstick only, with a satin finish. Plan my look from my owned inventory now.",
            },
        ]
        final = await service.respond(
            str(uuid4()), Conversation(consent_version=CONSENT, messages=messages)
        )
        check(
            final["ai_status"] == "grounded",
            "real function call and validated explanation references",
        )
        check(
            len(final["plan"]["suggestions"]) == 1
            and final["plan"]["suggestions"][0]["product"]["id"] == "synthetic-product",
            "only synthetic owned product returned",
        )
        check(
            final["explanations"][0]["product_id"] == "synthetic-product",
            "explanation resolves authorized facts",
        )
        print(
            "GEMINI_LIVE_PASS (synthetic conversation/metadata; no personal inventory or image)",
            flush=True,
        )


if __name__ == "__main__":
    from fastapi import HTTPException

    try:
        asyncio.run(run())
    except Exception as exc:
        print(
            "GEMINI_LIVE_FAILED:",
            exc.detail
            if isinstance(exc, HTTPException)
            else str(exc)
            if isinstance(exc, RuntimeError)
            else type(exc).__name__,
        )
        raise SystemExit(1) from None
