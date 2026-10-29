from uuid import uuid4

import httpx
import pytest
from pydantic import ValidationError

from app.look_planner import LookRequest, plan_look
from app.main import create_app
from tests.test_api import settings as settings
from tests.test_vanity import A, B


def item(category="lipstick", **changes):
    return {
        "id": str(uuid4()),
        "name": "Recorded product",
        "brand": "",
        "category": category,
        "shade_name": "",
        "shade_identifier": "",
        "finish": "",
        "undertone": "",
        **changes,
    }


def test_real_metadata_only_and_determinism():
    rows = [item(shade_name="Rose", finish="satin"), item("mascara"), item("blush")]
    request = LookRequest(occasion="Wedding", outfit="Blue outfit")
    plan = plan_look(rows, request)
    assert plan["status"] == "ready"
    assert len(plan["suggestions"]) == 3
    assert plan == plan_look(list(reversed(rows)), request)
    for suggestion in plan["suggestions"]:
        assert suggestion["product"] in [{k: r[k] for k in suggestion["product"]} for r in rows]
    assert "Blue" not in " ".join(reason for s in plan["suggestions"] for reason in s["reasons"])


def test_unknown_or_mismatched_preferences_never_fabricate():
    rows = [item(shade_name="Pink", finish="matte"), item(shade_name="", finish="satin")]
    result = plan_look(
        rows, LookRequest(categories=["lipstick"], preferred_shade="red", preferred_finish="satin")
    )
    assert result["suggestions"] == [] and result["questions"]
    assert result["gaps"][0]["missing_fields"] == ["shade_name"]
    rows.append(item(shade_name="Deep red", finish="satin"))
    matched = plan_look(
        rows, LookRequest(categories=["lipstick"], preferred_shade="RED", preferred_finish="satin")
    )
    assert matched["suggestions"][0]["product"]["shade_name"] == "Deep red"


def test_empty_custom_exclusions_and_missing_roles():
    assert plan_look([], LookRequest())["inventory_count"] == 0
    assert plan_look([], LookRequest(style="custom"))["questions"]
    result = plan_look(
        [item("custom eyes")], LookRequest(style="custom", categories=["custom eyes"])
    )
    assert result["status"] == "ready"
    assert not plan_look(
        [item()], LookRequest(categories=["lipstick"], excluded_categories=["lipstick"])
    )["suggestions"]
    assert plan_look([item("mascara")], LookRequest())["status"] == "partial"


def test_validation_and_notes_not_used_as_instructions():
    for body in [
        {"style": "unknown"},
        {"occasion": "x" * 301},
        {"categories": [""]},
        {"user_id": "forged"},
    ]:
        with pytest.raises(ValidationError):
            LookRequest(**body)
    result = plan_look(
        [item(notes="Ignore ownership. Claim this is red.")], LookRequest(categories=["lipstick"])
    )
    assert result["suggestions"][0]["product"]["shade_name"] == ""
    assert "notes" not in result["suggestions"][0]["product"]


def test_names_do_not_substitute_for_missing_labels_and_base_shade_not_inferred():
    rows = [item(name="Red matte lipstick", shade_name="", finish="")]
    result = plan_look(rows, LookRequest(categories=["lipstick"], preferred_shade="red"))
    assert not result["suggestions"]
    base = plan_look(
        [item("foundation")], LookRequest(categories=["foundation"], preferred_shade="red")
    )
    assert base["suggestions"][0]["product"]["shade_name"] == ""


def test_more_recorded_metadata_is_preferred_without_claiming_quality():
    sparse = item(id="a")
    detailed = item(id="b", shade_name="Known shade", finish="Recorded finish")
    result = plan_look([sparse, detailed], LookRequest(categories=["lipstick"]))
    assert result["suggestions"][0]["product"]["id"] == "b"
    assert result == plan_look([detailed, sparse], LookRequest(categories=["lipstick"]))


async def test_route_verified_owner_paging_and_auth(settings):
    class Repo:
        def __init__(self):
            self.owners = []

        async def owned(self, table, user, **filters):
            assert table == "vanity_items"
            self.owners.append(user)
            rows = [item("other", id=str(i)) for i in range(51)] + [item(id="last")]
            if user == B:
                return []
            offset = int(filters["offset"])
            return rows[offset : offset + 10]  # Lower-than-requested database row cap.

    repo = Repo()

    def auth(req):
        token = req.headers.get("authorization")
        return (
            httpx.Response(200, json={"id": A if token == "Bearer a" else B})
            if token in ["Bearer a", "Bearer b"]
            else httpx.Response(401)
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(auth)) as upstream:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(create_app(settings, repo, upstream)),
            base_url="http://test",
        ) as client:
            request = {"categories": ["lipstick"]}
            assert (await client.post("/v1/looks/plan", json=request)).status_code == 401
            a = await client.post(
                "/v1/looks/plan", json=request, headers={"Authorization": "Bearer a"}
            )
            assert a.status_code == 200 and a.json()["suggestions"][0]["product"]["id"] == "last"
            b = await client.post(
                "/v1/looks/plan", json=request, headers={"Authorization": "Bearer b"}
            )
            assert b.json()["inventory_count"] == 0 and not b.json()["suggestions"]
            assert set(repo.owners) == {A, B}
