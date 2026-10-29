import json
from copy import deepcopy
from uuid import uuid4

import httpx
import pytest
from fastapi import HTTPException

from app.gemini_looks import Conversation, ConversationService
from app.live_voice import LiveTools, setup_message
from app.look_planner import LookRequest
from app.main import create_app
from app.makeup_preferences import (
    MakeupPreferences,
    PreferenceService,
    apply_preferences,
    context_text,
)
from tests.test_api import settings as settings
from tests.test_gemini_looks import Repo as InventoryRepo

A, B = str(uuid4()), str(uuid4())


class Repo(InventoryRepo):
    def __init__(self):
        super().__init__()
        self.preferences = {}
        self.profile_reads = []

    async def owned(self, table, user, **filters):
        if table == "makeup_preferences":
            self.profile_reads.append(user)
            return [deepcopy(self.preferences[user])] if user in self.preferences else []
        return await super().owned(table, user, **filters)

    async def request(self, method, path, **kwargs):
        assert path == "/rest/v1/makeup_preferences"
        if method == "POST":
            data = kwargs["json"].copy()
            user = data.pop("user_id")
            self.preferences[user] = {**data, "source": "explicit_profile"}
        else:
            self.preferences.pop(kwargs["params"]["user_id"][3:], None)
        return httpx.Response(200, json={})


async def test_preferences_crud_repeated_save_and_ownership():
    repo = Repo()
    s = PreferenceService(repo)
    assert (await s.get(A))["source"] is None
    body = MakeupPreferences(
        preferred_finish="satin", excluded_categories=[" Foundation ", "foundation"]
    )
    await s.save(A, body)
    await s.save(A, body)
    assert len(repo.preferences) == 1 and (await s.get(A))["excluded_categories"] == ["foundation"]
    assert (await s.get(B))["preferred_finish"] == ""
    await s.delete(B)
    assert (await s.get(A))["preferred_finish"] == "satin"
    await s.delete(A)
    await s.delete(A)
    assert (await s.get(A))["updated_at"] is None


@pytest.mark.parametrize(
    "data",
    [
        {"user_id": A},
        {"source": "inferred"},
        {"preferred_finish": "x" * 81},
        {"excluded_categories": [""]},
        {"excluded_categories": [str(x) for x in range(13)]},
    ],
)
def test_invalid_preferences(data):
    with pytest.raises(ValueError):
        MakeupPreferences(**data)


def test_current_request_overrides_labels_but_preserves_saved_exclusions():
    profile = MakeupPreferences(
        preferred_finish="satin", preferred_shade="Rose", excluded_categories=["foundation"]
    ).model_dump()
    effective, fields = apply_preferences(
        LookRequest(preferred_finish="matte", excluded_categories=["eyeliner"]), profile
    )
    assert effective.preferred_finish == "matte" and effective.preferred_shade == "Rose"
    assert effective.excluded_categories == ["eyeliner", "foundation"]
    assert fields == ["preferred_shade", "excluded_categories"]
    profile["excluded_categories"] = [str(x) for x in range(12)]
    with pytest.raises(HTTPException):
        apply_preferences(LookRequest(excluded_categories=["new"]), profile)


def test_context_does_not_dump_profile_identity_or_sensitive_unrelated_data(settings):
    data = {
        "preferred_finish": "satin",
        "user_id": A,
        "notes": "PRIVATE",
        "skin_score": 92,
        "journal": "PRIVATE",
    }
    text = context_text(data)
    assert "satin" in text and A not in text and "PRIVATE" not in text and "92" not in text
    encoded = json.dumps(setup_message(settings, data))
    assert "PRIVATE" not in encoded and A not in encoded


async def test_chat_opt_in_context_and_safe_backend_application():
    repo = Repo()
    await PreferenceService(repo).save(A, MakeupPreferences(preferred_finish="satin"))

    class Model:
        def __init__(self):
            self.seen = []

        async def call(self, contents, allowed):
            self.seen.append(deepcopy(contents))
            if allowed == ["explain_owned_plan"]:
                raise ValueError("deterministic explanation fallback")
            return {"role": "model", "parts": []}, {
                "name": "plan_owned_look",
                "args": {"categories": ["lipstick"]},
            }

    model = Model()
    service = ConversationService(repo, model)
    repo.profile_reads = []
    base = {
        "consent_version": "gemini-look-v1",
        "messages": [{"role": "user", "text": "Plan my lips"}],
    }
    result = await service.respond(A, Conversation(**base))
    assert not repo.profile_reads and result["plan"]["saved_preference_fields"] == []
    result = await service.respond(A, Conversation(**base, use_saved_preferences=True))
    assert repo.profile_reads == [A] and result["plan"]["saved_preference_fields"] == [
        "preferred_finish"
    ]
    assert "explicitly saved" in model.seen[-2][0]["parts"][0]["text"]


async def test_live_tools_merge_preferences_without_memory_writes():
    repo = Repo()
    events = []

    async def send(e):
        events.append(e)

    tool = LiveTools(
        repo, A, send, {"preferred_finish": "satin", "excluded_categories": ["foundation"]}
    )
    result = await tool.execute(
        {"name": "plan_owned_look", "args": {"categories": ["lipstick", "foundation"]}}
    )
    assert result["suggestions"] and all(
        x["category"] != "foundation" for x in result["suggestions"]
    )
    assert events[0]["plan"]["saved_preference_fields"] == [
        "preferred_finish",
        "excluded_categories",
    ]
    assert not repo.preferences


async def test_preferences_routes_reject_client_owner_and_require_auth(settings):
    repo = Repo()
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(lambda r: httpx.Response(200, json={"id": A}))
    ) as h:
        app = create_app(settings, repo, h)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as c:
            assert (await c.get("/v1/makeup-preferences")).status_code == 401
            c.headers["Authorization"] = "Bearer test"
            assert (await c.put("/v1/makeup-preferences", json={"user_id": B})).status_code == 422
            assert (
                await c.put("/v1/makeup-preferences", json={"preferred_finish": "satin"})
            ).status_code == 200
            assert set(repo.preferences) == {A}
            assert (await c.delete("/v1/makeup-preferences")).status_code == 200
