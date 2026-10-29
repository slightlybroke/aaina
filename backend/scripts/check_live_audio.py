"""Synthetic PCM in / real Gemini speech + transcripts out. No personal microphone/data."""

import asyncio
import base64
import json
import sys
import wave
from pathlib import Path
from uuid import uuid4

from websockets.asyncio.client import connect

from app.config import Settings
from app.live_voice import LIVE_URL, LiveTools, setup_message


class SyntheticRepo:
    async def owned(self, table, user, **filters):
        assert table == "vanity_items" and "notes" not in filters["select"]
        if int(filters.get("offset", 0)):
            return []
        category = filters["category"][3:]
        return [
            {
                "id": "synthetic-" + category,
                "name": "Synthetic " + category,
                "brand": "Demo fixture",
                "category": category,
                "shade_name": "",
                "shade_identifier": "",
                "finish": "satin",
                "undertone": "",
            }
        ]


async def run():
    tool_test = "--tool-test" in sys.argv
    path = Path("../evidence/live-synthetic.wav")
    if not path.exists():
        raise RuntimeError(
            "Generate the synthetic WAV first; no real recording is accepted by this smoke."
        )
    with wave.open(str(path), "rb") as source:
        assert (
            source.getframerate() == 16000
            and source.getnchannels() == 1
            and source.getsampwidth() == 2
        )
        pcm = source.readframes(source.getnframes())
    s = Settings()
    events = []

    async def event(data):
        events.append(data)

    tools = LiveTools(SyntheticRepo(), str(uuid4()), event)
    print("INFO: Live model", s.gemini_live_model, flush=True)
    async with connect(
        LIVE_URL,
        additional_headers={"x-goog-api-key": s.gemini_api_key.get_secret_value()},
        open_timeout=20,
        max_size=1000000,
    ) as ws:
        await ws.send(json.dumps(setup_message(s)))
        first = json.loads(await asyncio.wait_for(ws.recv(), 20))
        if "setupComplete" not in first:
            raise RuntimeError("Setup not accepted")
        print("PASS: real Live setup", flush=True)

        async def speak():
            if tool_test:
                await ws.send(
                    json.dumps(
                        {
                            "clientContent": {
                                "turns": [
                                    {
                                        "role": "user",
                                        "parts": [
                                            {
                                                "text": "Can you check my vanity and choose a lipstick I own with a satin finish? Please tell me its recorded product name."
                                            }
                                        ],
                                    }
                                ],
                                "turnComplete": True,
                            }
                        }
                    )
                )
                return
            for start in range(0, len(pcm), 3200):
                await ws.send(
                    json.dumps(
                        {
                            "realtimeInput": {
                                "audio": {
                                    "data": base64.b64encode(pcm[start : start + 3200]).decode(),
                                    "mimeType": "audio/pcm;rate=16000",
                                }
                            }
                        }
                    )
                )
                await asyncio.sleep(0.1)
            for _ in range(10):
                await ws.send(
                    json.dumps(
                        {
                            "realtimeInput": {
                                "audio": {
                                    "data": base64.b64encode(bytes(3200)).decode(),
                                    "mimeType": "audio/pcm;rate=16000",
                                }
                            }
                        }
                    )
                )
                await asyncio.sleep(0.1)
            await ws.send(json.dumps({"realtimeInput": {"audioStreamEnd": True}}))

        sender = asyncio.create_task(speak())
        audio_bytes = 0
        input_text = ""
        output_text = ""
        try:
            async with asyncio.timeout(60):
                async for raw in ws:
                    msg = json.loads(raw)
                    content = msg.get("serverContent", {})
                    input_text += content.get("inputTranscription", {}).get("text", "")
                    output_text += content.get("outputTranscription", {}).get("text", "")
                    for part in content.get("modelTurn", {}).get("parts", []):
                        audio_bytes += len(
                            base64.b64decode(part.get("inlineData", {}).get("data", ""))
                        )
                    replies = []
                    for call in msg.get("toolCall", {}).get("functionCalls", []):
                        result = await tools.execute(call)
                        replies.append({"id": call["id"], "name": call["name"], "response": result})
                    if replies:
                        await ws.send(json.dumps({"toolResponse": {"functionResponses": replies}}))
                    if (
                        content.get("turnComplete")
                        and audio_bytes
                        and output_text
                        and (events if tool_test else input_text)
                    ):
                        break
        finally:
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)
        if (
            not audio_bytes
            or not output_text.strip()
            or not (events if tool_test else input_text.strip())
        ):
            raise RuntimeError("Audio/transcripts incomplete")
        print(
            "PASS: real Live tool roundtrip with synthetic inventory"
            if tool_test
            else "PASS: synthetic microphone-format audio transcribed",
            flush=True,
        )
        print("PASS: real spoken PCM output and output transcript", flush=True)
        print(
            "INFO: input/output transcript character counts",
            len(input_text),
            len(output_text),
            "audio bytes",
            audio_bytes,
            "tool plans",
            len(events),
            flush=True,
        )
        print(
            "LIVE_AUDIO_PASS (synthetic file; no real microphone/device playback proof)", flush=True
        )


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except Exception as exc:
        print(
            "LIVE_AUDIO_FAILED:", str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        )
        raise SystemExit(1) from None
