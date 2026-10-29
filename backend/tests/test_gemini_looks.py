from copy import deepcopy

import httpx
import pytest

from app.gemini_looks import CONSENT, Conversation, ConversationService, Gemini
from app.main import create_app
from tests.test_api import settings as settings
from tests.test_vanity import A, B


@pytest.mark.parametrize(
    "exact_exists,excluded,expected",
    [(False, [], "other"), (True, [], "others"), (False, ["other"], None)],
)
async def test_other_alias_exact_match_and_exclusions(exact_exists, excluded, expected):
    from app.gemini_looks import build_owned_plan
    from app.look_planner import LookRequest

    class CategoriesRepo(Repo):
        async def owned(self, table, user, **filters):
            assert user == A and "notes" not in filters["select"]
            self.calls.append((user, filters))
            category = filters["category"][3:]
            if int(filters.get("offset", 0)) or (category == "others" and not exact_exists):
                return []
            return [
                {
                    "id": category,
                    "name": "Random fixture",
                    "category": category,
                    "brand": "",
                    "shade_name": "",
                    "shade_identifier": "",
                    "finish": "",
                    "undertone": "",
                }
            ]

    repo = CategoriesRepo()
    plan = await build_owned_plan(
        repo, A, LookRequest(categories=["others"], excluded_categories=excluded)
    )
    if expected:
        assert plan["suggestions"][0]["product"]["category"] == expected
    else:
        assert not plan["suggestions"]
        assert not any(f["category"] == "eq.other" for _, f in repo.calls)


async def test_other_alias_keeps_owner_isolation():
    from app.gemini_looks import build_owned_plan
    from app.look_planner import LookRequest

    repo = Repo()
    plan = await build_owned_plan(repo, B, LookRequest(categories=["others"]))
    assert not plan["suggestions"]
    assert all(user == B for user, _ in repo.calls)


def conversation(text="Plan lips"):
    return Conversation(consent_version=CONSENT, messages=[{"role": "user", "text": text}])


def result(name, args, signature=True):
    part = {"functionCall": {"name": name, "args": args}}
    if signature:
        part["thoughtSignature"] = "opaque-signature"
    return {"candidates": [{"finishReason": "STOP", "content": {"role": "model", "parts": [part]}}]}


class Repo:
    def __init__(self):
        self.calls = []

    async def owned(self, table, user, **filters):
        assert table == "vanity_items"
        assert "notes" not in filters["select"]
        self.calls.append((user, filters))
        if user == B or int(filters.get("offset", 0)) > 0:
            return []
        return [
            {
                "id": "owned-product",
                "name": "Recorded product",
                "category": "lipstick",
                "brand": "Recorded brand",
                "shade_name": "Rose",
                "shade_identifier": "R1",
                "finish": "satin",
                "undertone": "",
            }
        ]


async def test_tool_boundary_grounded_explanations_and_signatures(settings):
    from pydantic import SecretStr

    settings.gemini_api_key = SecretStr("server-key")
    calls = []

    def provider(req):
        import json

        payload = json.loads(req.content)
        calls.append(payload)
        assert req.url.host == "generativelanguage.googleapis.com"
        assert "key=" not in str(req.url) and req.headers["x-goog-api-key"] == "server-key"
        if len(calls) == 1:
            return httpx.Response(
                200,
                json=result(
                    "plan_owned_look", {"categories": ["lipstick"], "preferred_finish": "satin"}
                ),
            )
        assert payload["contents"][1]["parts"][0]["thoughtSignature"] == "opaque-signature"
        response = payload["contents"][2]["parts"][0]["functionResponse"]["response"]
        assert response["suggestions"][0]["product"]["id"] == "owned-product"
        assert "user_id" not in str(response) and "notes" not in str(response)
        return httpx.Response(
            200,
            json=result(
                "explain_owned_plan",
                {
                    "opening": "plan_ready",
                    "evidence": [{"product_id": "owned-product", "reason_indexes": [0, 1]}],
                },
            ),
        )

    repo = Repo()
    async with httpx.AsyncClient(transport=httpx.MockTransport(provider)) as client:
        response = await ConversationService(repo, Gemini(settings, client)).respond(
            A, conversation()
        )
    assert response["ai_status"] == "grounded" and len(calls) == 2
    assert repo.calls[0][0] == A and repo.calls[0][1]["category"] == "eq.lipstick"
    assert response["explanations"][0]["reasons"] == response["plan"]["suggestions"][0]["reasons"]


async def test_clarification_does_not_read_inventory(settings):
    from pydantic import SecretStr

    settings.gemini_api_key = SecretStr("key")
    repo = Repo()
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda r: httpx.Response(
                200,
                json=result(
                    "ask_clarification",
                    {"question": "Would you like a natural or bold category plan?"},
                ),
            )
        )
    ) as client:
        response = await ConversationService(repo, Gemini(settings, client)).respond(
            A, conversation("Help me")
        )
    assert response["plan"] is None and not repo.calls


@pytest.mark.parametrize(
    "bad", [{"user_id": B, "categories": ["lipstick"]}, {"sql": "select *"}, {"style": "invented"}]
)
async def test_invalid_model_arguments_never_access_data(settings, bad):
    from fastapi import HTTPException
    from pydantic import SecretStr

    settings.gemini_api_key = SecretStr("key")
    repo = Repo()
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda r: httpx.Response(200, json=result("plan_owned_look", bad))
        )
    ) as client:
        with pytest.raises(HTTPException) as exc:
            await ConversationService(repo, Gemini(settings, client)).respond(A, conversation())
    assert exc.value.status_code == 502 and not repo.calls


@pytest.mark.parametrize(
    "evidence",
    [
        [{"product_id": "foreign", "reason_indexes": [0]}],
        [{"product_id": "owned-product", "reason_indexes": [99]}],
        [{"product_id": "owned-product", "reason_indexes": [True]}],
    ],
)
async def test_invalid_explanation_falls_back_to_owned_facts(settings, evidence):
    from pydantic import SecretStr

    settings.gemini_api_key = SecretStr("key")
    counter = 0

    def provider(req):
        nonlocal counter
        counter += 1
        return httpx.Response(
            200,
            json=result("plan_owned_look", {"categories": ["lipstick"]})
            if counter == 1
            else result("explain_owned_plan", {"opening": "plan_ready", "evidence": evidence}),
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(provider)) as client:
        response = await ConversationService(Repo(), Gemini(settings, client)).respond(
            A, conversation()
        )
    assert response["ai_status"] == "deterministic_fallback"
    assert response["explanations"][0]["product_id"] == "owned-product"


@pytest.mark.parametrize(
    "provider_response",
    [
        httpx.Response(429),
        httpx.Response(403),
        httpx.Response(200, json={}),
        httpx.Response(200, json=result("execute_sql", {"sql": "bad"})),
        httpx.Response(200, json={"candidates": [{"finishReason": "SAFETY"}]}),
    ],
)
async def test_provider_errors_safe(settings, provider_response):
    from fastapi import HTTPException
    from pydantic import SecretStr

    settings.gemini_api_key = SecretStr("key")
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(lambda r: provider_response)
    ) as client:
        with pytest.raises(HTTPException) as exc:
            await Gemini(settings, client).call([], ["plan_owned_look"])
    assert exc.value.status_code in (502, 503)


async def test_api_auth_consent_and_cross_user(settings):
    from pydantic import SecretStr

    settings.gemini_api_key = SecretStr("key")
    repo = Repo()

    def upstream(req):
        if req.url.host == "generativelanguage.googleapis.com":
            return httpx.Response(200, json=result("plan_owned_look", {"categories": ["lipstick"]}))
        token = req.headers.get("authorization")
        return (
            httpx.Response(200, json={"id": A if token == "Bearer a" else B})
            if token in ["Bearer a", "Bearer b"]
            else httpx.Response(401)
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(upstream)) as provider:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(create_app(settings, repo, provider)),
            base_url="http://test",
        ) as client:
            data = conversation().model_dump()
            assert (await client.post("/v1/looks/conversation", json=data)).status_code == 401
            missing = deepcopy(data)
            missing.pop("consent_version")
            assert (
                await client.post(
                    "/v1/looks/conversation", headers={"Authorization": "Bearer a"}, json=missing
                )
            ).status_code == 422
            invalid = {**data, "user_id": A}
            assert (
                await client.post(
                    "/v1/looks/conversation", headers={"Authorization": "Bearer b"}, json=invalid
                )
            ).status_code == 422
            response = await client.post(
                "/v1/looks/conversation", headers={"Authorization": "Bearer b"}, json=data
            )
            assert response.status_code == 200 and response.json()["plan"]["suggestions"] == []
            assert all(user == B for user, _ in repo.calls)


async def test_missing_key_does_not_call_provider(settings):
    from fastapi import HTTPException

    async with httpx.AsyncClient(
        transport=httpx.MockTransport(lambda r: pytest.fail("Unexpected network call"))
    ) as provider:
        with pytest.raises(HTTPException) as exc:
            await Gemini(settings, provider).call([], [])
    assert exc.value.status_code == 503


async def test_candidate_cap_and_low_database_page_limit():
    class PagedRepo:
        async def owned(self, table, user, **filters):
            assert user == A and table == "vanity_items"
            offset = int(filters["offset"])
            rows = [
                {
                    "id": f"{i:02}",
                    "name": "Synthetic product",
                    "brand": "",
                    "category": "lipstick",
                    "shade_name": "",
                    "shade_identifier": "",
                    "finish": "",
                    "undertone": "",
                }
                for i in range(24)
            ]
            return rows[offset : offset + min(7, int(filters["limit"]))]

    class Model:
        async def call(self, contents, allowed):
            if "plan_owned_look" in allowed:
                return {"role": "model", "parts": []}, {
                    "name": "plan_owned_look",
                    "args": {"categories": ["lipstick"]},
                }
            return {}, {
                "name": "explain_owned_plan",
                "args": {
                    "opening": "plan_ready",
                    "evidence": [{"product_id": "00", "reason_indexes": [0]}],
                },
            }

    response = await ConversationService(PagedRepo(), Model()).respond(A, conversation())
    assert response["plan"]["inventory_count"] == 20
    assert response["plan"]["candidate_limit_reached"] is True
    assert response["plan"]["suggestions"][0]["product"]["id"] == "00"
