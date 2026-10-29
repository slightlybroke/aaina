from copy import deepcopy
from datetime import date, datetime
from uuid import uuid4

import httpx
import pytest
from pydantic import ValidationError

from app.config import Settings
from app.main import create_app
from app.skincare import Journal, Preferences, Routine, SkincareService, daily_state, summarize
from tests.fakes import MemoryRepository

A, B, R, S, T = [str(uuid4()) for _ in range(5)]


def revision(day="2026-10-01", version=1, **changes):
    return {
        "id": str(uuid4()),
        "routine_id": R,
        "version": version,
        "effective_from": day,
        "definition": {
            "name": "Morning",
            "kind": "morning",
            "status": "active",
            "days": [1, 2, 3, 4, 5, 6, 7],
            "steps": [{"id": S, "name": "Cleanse"}, {"id": T, "name": "SPF"}],
            **changes,
        },
    }


def log(day, steps=None):
    return {
        "routine_id": R,
        "local_date": day,
        "completed_steps": steps if steps is not None else [S, T],
        "updated_at": "2026-10-20T00:00:00Z",
    }


def test_partial_complete_and_correction():
    r = revision()
    day = date(2026, 10, 20)
    assert daily_state([r], [], day)["completion"] == "incomplete"
    assert daily_state([r], [log(str(day), [S])], day)["completion"] == "partial"
    assert daily_state([r], [log(str(day))], day)["completion"] == "complete"
    assert daily_state([r], [log(str(day), [])], day)["completion"] == "incomplete"


def test_partial_adherence_no_opportunities_and_immutable_steps():
    old = revision(
        "2026-10-19", steps=[{"id": S, "name": "Old first"}, {"id": T, "name": "Old second"}]
    )
    edited = revision("2026-10-21", 2, steps=[{"id": T, "name": "Renamed"}])
    logs = [log("2026-10-19"), log("2026-10-20", [S]), log("2026-10-21", [T])]
    summary = summarize(
        [old, edited], logs, date(2026, 10, 21), date(2026, 10, 19), date(2026, 10, 21)
    )
    assert (summary["scheduled"], summary["completed"], summary["partial"]) == (3, 2, 1)
    assert summary["routines"][0]["current_streak"] == 1
    historical = daily_state([old, edited], logs, date(2026, 10, 19))
    assert [s["id"] for s in historical["definition"]["steps"]] == [S, T]
    assert historical["completion"] == "complete"
    empty = summarize(
        [revision("2026-10-22")], [], date(2026, 10, 21), date(2026, 10, 19), date(2026, 10, 21)
    )
    assert empty["adherence_percent"] is None and empty["scheduled"] == 0


def test_schedule_streak_today_grace_and_future_excluded():
    r = revision(days=[1, 3, 5])
    logs = [log(d) for d in ["2026-10-19", "2026-10-21", "2026-10-23", "2026-10-26"]]
    result = summarize([r], logs, date(2026, 10, 23), date(2026, 10, 19), date(2026, 10, 31))
    assert result["scheduled"] == result["completed"] == 3
    assert result["routines"][0]["current_streak"] == 3
    result = summarize([r], logs[:2], date(2026, 10, 23), date(2026, 10, 19), date(2026, 10, 23))
    assert result["routines"][0]["current_streak"] == 2  # Today not over yet.
    result = summarize([r], logs[:2], date(2026, 10, 24), date(2026, 10, 19), date(2026, 10, 24))
    assert result["routines"][0] == {"routine_id": R, "current_streak": 0, "longest_streak": 2}
    assert result["adherence_percent"] == 66.7


def test_revisions_preserve_history_pauses_and_order():
    old = revision(days=[1, 2, 3, 4, 5, 6, 7])
    new = revision("2026-10-22", 2, status="paused", steps=[{"id": T, "name": "New"}])
    archived = revision("2026-10-24", 3, status="archived")
    logs = [log("2026-10-20"), log("2026-10-21")]
    assert daily_state([old, new], logs, date(2026, 10, 20))["definition"]["steps"][0]["id"] == S
    result = summarize(
        [old, new, archived], logs, date(2026, 10, 25), date(2026, 10, 20), date(2026, 10, 25)
    )
    assert result["completed"] == result["scheduled"] == 2
    assert result["routines"][0]["current_streak"] == 2


@pytest.mark.parametrize(
    "zone,instant,expected",
    [
        ("Asia/Kolkata", "2026-10-20T19:00:00+00:00", "2026-10-21"),
        ("America/New_York", "2026-03-08T06:59:00+00:00", "2026-03-08"),
        ("America/New_York", "2026-03-08T07:01:00+00:00", "2026-03-08"),
        ("America/New_York", "2026-11-01T05:30:00+00:00", "2026-11-01"),
        ("America/New_York", "2026-11-01T06:30:00+00:00", "2026-11-01"),
    ],
)
async def test_timezone_boundaries(zone, instant, expected):
    class Repo:
        async def owned(self, table, user, **kwargs):
            return [{"timezone": zone}] if table == "skincare_settings" else []

    result = await SkincareService(Repo(), lambda: datetime.fromisoformat(instant)).preferences(A)
    assert result["today"] == expected


def test_invalid_fields_and_missing_data():
    for zone in ["invalid/zone", "../UTC"]:
        with pytest.raises(ValidationError):
            Preferences(timezone=zone)
    valid = revision()["definition"]
    for changes in [
        {"name": " "},
        {"steps": []},
        {"days": [0]},
        {"days": [1, 1]},
        {"steps": [valid["steps"][0]] * 2},
        {"user_id": A},
    ]:
        with pytest.raises(ValidationError):
            Routine(**{**valid, **changes})
    for changes in [
        {"concerns": []},
        {"severity": "diagnosed"},
        {"observed_at": "2026-01-01T00:00:00"},
        {"observed_at": "2099-01-01T00:00:00Z"},
    ]:
        with pytest.raises(ValidationError):
            Journal(**{"concerns": ["dryness"], "observed_at": "2026-01-01T00:00:00Z", **changes})


class TrackingRepo(MemoryRepository):
    def __init__(self):
        super().__init__()
        self.tracking = {
            t: []
            for t in [
                "skincare_settings",
                "routines",
                "routine_revisions",
                "routine_checkins",
                "skin_journal",
            ]
        }
        self.calls = []

    async def owned(self, table, user, **filters):
        if table not in self.tracking:
            return await super().owned(table, user, **filters)
        rows = [
            deepcopy(r)
            for r in self.tracking[table]
            if r["user_id"] == user
            and all(
                r.get(k) == v[3:]
                for k, v in filters.items()
                if isinstance(v, str) and v.startswith("eq.")
            )
        ]
        offset = int(filters.get("offset", 0))
        return rows[offset : offset + int(filters.get("limit", 500))]

    async def rpc(self, name, payload=None):
        self.calls.append(deepcopy(payload))
        if payload["p_data"].get("id") == B:
            return {"error": "Entry not found.", "status": 404}
        return payload["p_data"]


@pytest.fixture
async def tracking_api():
    repo = TrackingRepo()
    settings = Settings(
        _env_file=None,
        supabase_url="https://test.supabase.co",
        supabase_publishable_key="public",
        supabase_service_role_key="secret",
        youcam_api_key="unused",
    )

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
            headers={"Authorization": "Bearer a"},
        ) as client:
            yield client, repo


async def test_routes_owner_payload_and_cross_user(tracking_api):
    client, repo = tracking_api
    body = revision()["definition"]
    assert (await client.put(f"/v1/skincare/routines/{R}", json=body)).status_code == 200
    assert repo.calls[-1]["p_user"] == A
    assert repo.calls[-1]["p_data"]["definition"]["steps"][0]["id"] == S
    assert (
        await client.put(f"/v1/skincare/routines/{R}", json={**body, "user_id": B})
    ).status_code == 422
    assert (await client.put(f"/v1/skincare/routines/{B}", json=body)).status_code == 404
    assert (await client.delete(f"/v1/skincare/journal/{B}")).status_code == 404
    await client.put("/v1/skincare/settings", json={"timezone": "Asia/Kolkata"})
    assert repo.calls[-1]["p_action"] == "settings"
    await client.put(
        f"/v1/skincare/routines/{R}/checkins",
        json={"local_date": "2026-10-20", "revision_id": R, "completed_steps": [S]},
    )
    assert repo.calls[-1]["p_user"] == A
    assert (
        await client.put(
            f"/v1/skincare/routines/{R}/checkins",
            json={"local_date": "2026-10-20", "revision_id": R, "completed_steps": [S, S]},
        )
    ).status_code == 422
    await client.put(
        f"/v1/skincare/journal/{R}",
        json={"concerns": ["dryness"], "observed_at": "2026-01-01T00:00:00Z"},
    )
    assert repo.calls[-1]["p_action"] == "journal"
    await client.delete(f"/v1/skincare/journal/{R}")
    assert repo.calls[-1]["p_action"] == "journal_delete"


async def test_read_isolation_and_phase1_unchanged(tracking_api):
    client, repo = tracking_api
    r = {**revision(), "user_id": A}
    repo.tracking["routine_revisions"].append(r)
    repo.tracking["skin_journal"].append({"id": R, "user_id": A, "notes": "Private"})
    repo.analyses.append({"user_id": A, "overall_score": 92.25, "metrics": []})
    assert len((await client.get("/v1/skincare/routines?day=2026-10-20")).json()["routines"]) == 1
    assert (await client.get("/v1/analyses")).json()[0]["overall_score"] == 92.25
    assert (await client.get("/v1/skincare/history?start=2026-10-19&end=2026-10-20")).json()[
        "summary"
    ]["scheduled"] == 2
    assert (await client.get("/v1/skincare/history?start=2020-01-01")).status_code == 422
    client.headers["Authorization"] = "Bearer b"
    assert (await client.get("/v1/skincare/routines")).json()["routines"] == []
    assert (await client.get("/v1/skincare/journal")).json() == []
    assert (await client.get("/v1/analyses")).json() == []
    client.headers.clear()
    for path in ["settings", "routines", "history", "journal"]:
        assert (await client.get(f"/v1/skincare/{path}")).status_code == 401


async def test_pagination_does_not_truncate_summary():
    repo = TrackingRepo()
    repo.tracking["routine_revisions"] = [{**revision(), "user_id": A} for _ in range(501)]
    assert len(await SkincareService(repo).all("routine_revisions", A, "id.asc")) == 501


async def test_pagination_respects_lower_database_row_cap():
    class CappedRepo:
        async def owned(self, table, user, **filters):
            rows = [{"id": i} for i in range(123)]
            offset = int(filters["offset"])
            return rows[offset : offset + 50]

    assert len(await SkincareService(CappedRepo()).all("routine_checkins", A, "id.asc")) == 123
