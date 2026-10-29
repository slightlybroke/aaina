import asyncio
import base64
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app.live_voice import LIVE_CONSENT, LiveTools, relay, setup_message
from app.main import create_app
from tests.test_api import settings as settings
from tests.test_gemini_looks import Repo
from tests.test_vanity import A, B


class Client:
    def __init__(self, messages=None):
        self.events = []
        self.frames = []
        self.messages = list(messages or [])

    async def send_json(self, data):
        self.events.append(data)

    async def send_bytes(self, data):
        self.frames.append(data)

    async def receive(self):
        if self.messages:
            return self.messages.pop(0)
        await asyncio.Event().wait()


class Provider:
    def __init__(self, events=None):
        self.events = list(events or [])
        self.sent = []

    async def send(self, data):
        self.sent.append(json.loads(data))

    def __aiter__(self):
        return self

    async def __anext__(self):
        if self.events:
            return json.dumps(self.events.pop(0))
        raise StopAsyncIteration


async def test_audio_transcripts_interruption_and_verified_plan():
    audio = b"\x00\x01" * 100
    provider = Provider(
        [
            {
                "serverContent": {
                    "inputTranscription": {"text": "Hello "},
                    "outputTranscription": {"text": "Hi"},
                    "modelTurn": {
                        "parts": [
                            {
                                "inlineData": {
                                    "mimeType": "audio/pcm;rate=24000",
                                    "data": base64.b64encode(audio).decode(),
                                }
                            }
                        ]
                    },
                }
            },
            {"serverContent": {"interrupted": True, "turnComplete": True}},
            {
                "toolCall": {
                    "functionCalls": [
                        {
                            "id": "call1",
                            "name": "plan_owned_look",
                            "args": {"categories": ["lipstick"]},
                        }
                    ]
                }
            },
        ]
    )
    client = Client()
    repo = Repo()
    await relay(client, provider, repo, A, seconds=0.2)
    assert client.frames == [audio]
    assert any(e["type"] == "transcript" and e["role"] == "user" for e in client.events)
    assert any(e["type"] == "interrupted" for e in client.events)
    assert any(e["type"] == "plan" for e in client.events)
    assert provider.sent[-1]["toolResponse"]["functionResponses"][0]["id"] == "call1"
    assert all(user == A for user, _ in repo.calls)


async def test_microphone_audio_only_no_client_tools():
    class Endless(Provider):
        async def __anext__(self):
            await asyncio.Event().wait()

    provider = Endless()
    client = Client(
        [
            {"type": "websocket.receive", "bytes": b"\x00\x00" * 100},
            {"type": "websocket.receive", "text": '{"type":"stop"}'},
        ]
    )
    await relay(client, provider, Repo(), A, seconds=0.2)
    assert provider.sent[0]["realtimeInput"]["audio"]["mimeType"] == "audio/pcm;rate=16000"
    bad = Client([{"type": "websocket.receive", "text": '{"setup":{"model":"attacker"}}'}])
    with pytest.raises(ValueError):
        await relay(bad, Endless(), Repo(), A, seconds=0.2)


@pytest.mark.parametrize("frame", [b"odd", b"x" * 32002])
async def test_pcm_frame_limits(frame):
    class Endless(Provider):
        async def __anext__(self):
            await asyncio.Event().wait()

    with pytest.raises(ValueError):
        await relay(
            Client([{"type": "websocket.receive", "bytes": frame}]),
            Endless(),
            Repo(),
            A,
            seconds=0.2,
        )


async def test_tool_args_and_cross_owner():
    client = Client()
    repo = Repo()
    tools = LiveTools(repo, B, client.send_json)
    invalid = await tools.execute(
        {"name": "plan_owned_look", "args": {"user_id": A, "categories": ["lipstick"]}}
    )
    assert "error" in invalid and not repo.calls
    assert "error" in await tools.execute({"name": "execute_sql", "args": {}})
    result = await tools.execute({"name": "plan_owned_look", "args": {"categories": ["lipstick"]}})
    assert result["suggestions"] == [] and all(user == B for user, _ in repo.calls)


def test_live_setup_no_thinking_or_keys(settings):
    setup = setup_message(settings)["setup"]
    assert setup["inputAudioTranscription"] == setup["outputAudioTranscription"] == {}
    assert setup["generationConfig"]["responseModalities"] == ["AUDIO"]
    assert "thinkingConfig" not in setup and "api_key" not in str(setup)
    vad = setup["realtimeInputConfig"]["automaticActivityDetection"]
    assert vad["startOfSpeechSensitivity"] == "START_SENSITIVITY_LOW"
    assert vad["silenceDurationMs"] == 600
    # Native-audio language control is system instruction, not unsupported languageCode.
    assert "languageCode" not in setup["generationConfig"]


def test_websocket_auth_and_consent_before_provider(settings):
    async def auth(req):
        return httpx.Response(401)

    http = httpx.AsyncClient(transport=httpx.MockTransport(auth))
    app = create_app(settings, Repo(), http)
    with TestClient(app) as client:
        with client.websocket_connect("/v1/looks/live") as ws:
            ws.send_json({"access_token": "forged", "consent_version": LIVE_CONSENT})
            assert ws.receive_json()["type"] == "error"
        with client.websocket_connect("/v1/looks/live") as ws:
            ws.send_json({"access_token": "forged"})
            assert ws.receive_json()["type"] == "error"


async def test_session_deadline_closes_idle_streams():
    class Endless(Provider):
        async def __anext__(self):
            await asyncio.Event().wait()

    client = Client()
    await relay(client, Endless(), Repo(), A, seconds=0.01)
    assert client.events[-1]["type"] == "ended"
