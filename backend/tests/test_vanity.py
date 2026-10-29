from copy import deepcopy
from uuid import uuid4

import httpx
import pytest

from app.config import Settings
from app.main import create_app
from app.vanity import VanityItem
from tests.fakes import MemoryRepository

A, B = str(uuid4()), str(uuid4())


class VanityRepo(MemoryRepository):
    def __init__(self):
        super().__init__()
        self.items = {}
        self.calls = []

    async def owned(self, table, user, **filters):
        if table != "vanity_items":
            return await super().owned(table, user, **filters)
        return [
            deepcopy(row)
            for row in self.items.values()
            if row["user_id"] == user
            and all(row.get(k) == v[3:] for k, v in filters.items() if v.startswith("eq."))
        ]

    async def rpc(self, name, payload=None):
        self.calls.append((name, deepcopy(payload)))
        user = payload["p_user"]
        if name == "list_vanity_items":
            rows = [deepcopy(r) for r in self.items.values() if r["user_id"] == user]
            categories = sorted({r["category"] for r in rows})
            rows = [
                r
                for r in rows
                if (not payload["p_category"] or r["category"] == payload["p_category"])
                and payload["p_query"].lower()
                in " ".join(
                    str(r[k]) for k in VanityItem(name="x").model_dump(exclude={"expected_version"})
                ).lower()
            ]
            offset = payload["p_offset"]
            return {
                "items": rows[offset : offset + 50],
                "categories": categories,
                "has_more": len(rows) > offset + 50,
            }
        item_id = payload["p_id"]
        data = payload["p_data"]
        existing = self.items.get(item_id)
        if existing and existing["user_id"] != user:
            return {"error": "Product not found.", "status": 404}
        if existing and all(existing[k] == v for k, v in data.items()):
            return deepcopy(existing)
        if existing and payload["p_expected_version"] != existing["version"]:
            return {"error": "This product changed. Reload it before editing.", "status": 409}
        if not existing and payload["p_expected_version"] is not None:
            return {"error": "Product not found.", "status": 404}
        self.items[item_id] = {
            "id": item_id,
            "user_id": user,
            **data,
            "version": existing["version"] + 1 if existing else 1,
            "created_at": "2026-10-26T00:00:00Z",
            "updated_at": "2026-10-26T00:00:00Z",
        }
        return deepcopy(self.items[item_id])

    async def request(self, method, path, **kwargs):
        assert method == "DELETE" and path == "/rest/v1/vanity_items"
        self.calls.append(("delete", deepcopy(kwargs)))
        item_id = kwargs["params"]["id"][3:]
        user = kwargs["params"]["user_id"][3:]
        row = self.items.get(item_id)
        deleted = [self.items.pop(item_id)] if row and row["user_id"] == user else []
        return httpx.Response(200, json=deleted)


@pytest.fixture
async def vanity_api():
    repo = VanityRepo()
    settings = Settings(
        _env_file=None,
        supabase_url="https://test.supabase.co",
        supabase_publishable_key="public",
        supabase_service_role_key="secret",
        youcam_api_key="unused",
    )

    def auth(request):
        token = request.headers.get("authorization")
        return (
            httpx.Response(200, json={"id": A if token == "Bearer a" else B})
            if token in ["Bearer a", "Bearer b"]
            else httpx.Response(401)
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(auth)) as upstream:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(create_app(settings, repo, upstream)),
            base_url="http://test",
            headers={"Authorization": "Bearer a"},
        ) as client:
            yield client, repo


async def test_crud_optional_fields_retry_and_persistence(vanity_api):
    client, repo = vanity_api
    item = str(uuid4())
    path = "/v1/vanity/" + item
    first = await client.put(path, json={"name": "My lipstick"})
    assert first.status_code == 200
    assert first.json()["category"] == "other" and first.json()["shade_name"] == ""
    retry = await client.put(path, json={"name": "My lipstick"})
    assert retry.json()["version"] == 1 and len(repo.items) == 1
    body = {
        "name": "My lipstick",
        "brand": "Known brand",
        "category": " Lipstick ",
        "shade_name": "Shade on label",
        "shade_identifier": "A-12",
        "finish": "User-entered satin",
        "undertone": "",
        "notes": "My own note",
        "expected_version": 1,
    }
    edited = await client.put(path, json=body)
    assert edited.status_code == 200 and edited.json()["version"] == 2
    assert (await client.put(path, json=body)).json()["version"] == 2
    # A fresh request/session boundary reads the persisted adapter state (mocked, not live Auth).
    client.headers["Authorization"] = "Bearer a"
    assert (await client.get(path)).json()["shade_identifier"] == "A-12"
    assert (await client.put(path, json={**body, "notes": "Stale"})).status_code == 409
    assert (await client.delete(path)).status_code == 200
    assert repo.calls[-1][1]["params"]["user_id"] == "eq." + A
    assert (await client.get(path)).status_code == 404
    assert (await client.delete(path)).status_code == 404


async def test_cross_user_all_routes_and_untrusted_owner(vanity_api):
    client, repo = vanity_api
    item = str(uuid4())
    path = "/v1/vanity/" + item
    await client.put(path, json={"name": "Private item"})
    client.headers["Authorization"] = "Bearer b"
    assert (await client.get(path)).status_code == 404
    assert (await client.put(path, json={"name": "Hijacked"})).status_code == 404
    assert (await client.delete(path)).status_code == 404
    assert (await client.get("/v1/vanity")).json() == {
        "items": [],
        "categories": [],
        "has_more": False,
    }
    assert (
        await client.put("/v1/vanity/" + str(uuid4()), json={"name": "Bad owner", "user_id": A})
    ).status_code == 422
    assert repo.items[item]["name"] == "Private item"
    client.headers.clear()
    for method, url, body in [
        ("GET", "/v1/vanity", None),
        ("GET", path, None),
        ("PUT", path, {"name": "x"}),
        ("DELETE", path, None),
    ]:
        assert (await client.request(method, url, json=body)).status_code == 401


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"name": " "},
        {"name": "x" * 151},
        {"name": "x", "category": " "},
        {"name": "x", "notes": "n" * 3001},
        {"name": "x", "expected_version": 0},
        {"name": "x", "shade_name": None},
        {"name": "x", "image_url": "https://untrusted.example/image"},
    ],
)
async def test_invalid_input(vanity_api, body):
    client, repo = vanity_api
    assert (await client.put("/v1/vanity/" + str(uuid4()), json=body)).status_code == 422
    assert not repo.items


async def test_search_filter_and_custom_categories_are_literal(vanity_api):
    client, repo = vanity_api
    for name, category in [("50%_ shade", "lipstick"), ("Other product", "custom category")]:
        await client.put("/v1/vanity/" + str(uuid4()), json={"name": name, "category": category})
    response = (await client.get("/v1/vanity", params={"q": "50%_", "category": "LIPSTICK"})).json()
    assert len(response["items"]) == 1
    assert response["categories"] == ["custom category", "lipstick"]
    attack = "x),user_id.eq.other"
    assert (await client.get("/v1/vanity", params={"q": attack})).json()["items"] == []
    assert repo.calls[-1][1]["p_query"] == attack and repo.calls[-1][1]["p_user"] == A
    for params in [{"offset": -1}, {"q": "x" * 201}, {"category": "x" * 81}]:
        assert (await client.get("/v1/vanity", params=params)).status_code == 422


async def test_pagination_and_existing_history_unchanged(vanity_api):
    client, repo = vanity_api
    for index in range(51):
        await client.put("/v1/vanity/" + str(uuid4()), json={"name": str(index)})
    page = (await client.get("/v1/vanity")).json()
    assert len(page["items"]) == 50 and page["has_more"]
    assert len((await client.get("/v1/vanity?offset=50")).json()["items"]) == 1
    repo.analyses.append({"user_id": A, "overall_score": 92.25, "metrics": []})
    assert (await client.get("/v1/analyses")).json()[0]["overall_score"] == 92.25


async def test_upstream_error_is_retryable(vanity_api):
    client, repo = vanity_api

    async def failing(*args, **kwargs):
        raise httpx.ConnectError("offline")

    repo.rpc = failing
    response = await client.get("/v1/vanity")
    assert response.status_code == 503 and "Retry safely" in response.json()["detail"]
