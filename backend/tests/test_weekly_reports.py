from copy import deepcopy
from datetime import UTC, date, datetime
from uuid import uuid4

import httpx
import pytest
from fastapi import HTTPException

from app.weekly_reports import WeeklyService, analysis_summary, bounds, build_content, previous_week
from app.weekly_worker import sweep
from tests.test_skincare import S, log, revision

A, B = str(uuid4()), str(uuid4())
NOW = datetime(2026, 10, 28, 12, tzinfo=UTC)


def analysis(item="one", score=80, **changes):
    return {
        "id": item,
        "analyzed_at": "2026-10-20T12:00:00+00:00",
        "overall_score": score,
        "api_version": "2.1",
        "response_format": "zip",
        "metrics": [{"concern": "hd_pore", "region": "nose", "ui_score": 80, "raw_score": None}],
        **changes,
    }


def test_previous_week_local_midnight_and_no_current_future_dates():
    instant = datetime(2026, 10, 25, 19, tzinfo=UTC)
    assert previous_week(instant, "Asia/Kolkata") == (date(2026, 10, 19), date(2026, 10, 25))
    assert previous_week(instant, "America/New_York") == (date(2026, 10, 12), date(2026, 10, 18))


@pytest.mark.parametrize("start,hours", [(date(2026, 3, 2), 167), (date(2026, 10, 26), 169)])
def test_week_boundaries_cover_dst_real_instants(start, hours):
    a, b = bounds(start, "America/New_York")
    assert (b - a).total_seconds() == hours * 3600


def test_report_separates_scheduled_partial_scores_observations_and_omits_notes():
    r = revision(day="2026-10-19", days=[1, 3])
    result = build_content(
        [r],
        [log("2026-10-19"), log("2026-10-21", [S])],
        [analysis()],
        [{"concerns": ["dryness", "irritation"], "severity": "severe", "notes": "PRIVATE"}],
        date(2026, 10, 19),
        date(2026, 10, 25),
    )
    routine = result["routine"]
    assert routine["scheduled"] == 2 and routine["completed"] == 1 and routine["partial"] == 1
    assert routine["adherence_percent"] == 50 and routine["routines"][0]["current_streak"] == 0
    assert result["journal"]["entries"] == 1 and result["journal"]["concerns"]["dryness"] == 1
    assert result["skin"]["comparison"] is None and "PRIVATE" not in str(result)
    assert any("stop using" in s for s in result["suggestions"])


def test_empty_week_does_not_invent_scores_or_adherence():
    result = build_content([], [], [], [], date(2026, 10, 19), date(2026, 10, 25))
    assert result["routine"]["adherence_percent"] is None
    assert "latest" not in result["skin"] and not result["journal"]["entries"]


def test_comparisons_preserve_raw_ui_and_only_shared_metrics():
    a = analysis()
    b = analysis("two", 85, analyzed_at="2026-10-25T12:00:00+00:00")
    b["metrics"] = [
        {"concern": "hd_pore", "region": "nose", "ui_score": 83, "raw_score": 99},
        {"concern": "hd_pore", "region": "cheek", "ui_score": 89},
    ]
    result = analysis_summary([b, a])
    assert result["comparison"]["score_change"] == 5
    assert len(result["comparison"]["metrics"]) == 1
    assert result["comparison"]["metrics"][0]["ui_score"]["change"] == 3
    assert "raw_score" not in result["comparison"]["metrics"][0]
    assert "caused" in result["message"]


@pytest.mark.parametrize(
    "changes",
    [
        {"api_version": "other"},
        {"response_format": "json"},
        {"metrics": []},
        {"metrics": [{"concern": "standard_pore"}]},
    ],
)
def test_incompatible_data_never_draws_a_trend(changes):
    assert analysis_summary([analysis(), analysis("two", 90, **changes)])["comparison"] is None


@pytest.mark.parametrize("score", [None, "92", True, float("nan"), 101, 0])
def test_invalid_saved_scores_explicitly_omitted(score):
    result = analysis_summary([analysis(score=score)])
    assert result["valid_scores"] == 0 and "latest" not in result


class Repo:
    def __init__(self):
        self.reports = {}
        self.calls = []
        self.zones = {A: "UTC", B: "UTC"}

    async def owned(self, table, user, **filters):
        self.calls.append((table, user, filters))
        if table == "skincare_settings":
            return [{"user_id": user, "timezone": self.zones[user]}] if user in self.zones else []
        if table == "weekly_reports":
            rows = [r for r in self.reports.values() if r["user_id"] == user]
            for key in ["id", "week_start"]:
                if key in filters:
                    rows = [r for r in rows if r[key] == filters[key][3:]]
            if filters.get("read_at") == "is.null":
                rows = [r for r in rows if r["read_at"] is None]
            return deepcopy(rows)
        assert table in ["routine_revisions", "routine_checkins", "skin_analyses", "skin_journal"]
        return []

    async def request(self, method, path, **kwargs):
        assert path == "/rest/v1/weekly_reports"
        if method == "POST":
            data = kwargs["json"]
            key = (data["user_id"], data["week_start"])
            if key in self.reports:
                return httpx.Response(200, json=[])
            row = {"id": str(uuid4()), "read_at": None, "generated_at": NOW.isoformat(), **data}
            self.reports[key] = row
            return httpx.Response(200, json=[row])
        params = kwargs["params"]
        rows = [
            r
            for r in self.reports.values()
            if r["id"] == params["id"][3:]
            and r["user_id"] == params["user_id"][3:]
            and r["read_at"] is None
        ]
        for r in rows:
            r.update(kwargs["json"])
        return httpx.Response(200, json=deepcopy(rows))

    async def rows(self, table, **params):
        assert table == "skincare_settings"
        return [{"user_id": A}, {"user_id": B}] if params["offset"] == "0" else []


async def test_idempotent_generate_atomic_unread_and_read_no_duplicate_notifications():
    repo = Repo()
    service = WeeklyService(repo, lambda: NOW)
    one = await service.generate(A)
    two = await service.generate(A)
    assert one["id"] == two["id"] and len(repo.reports) == 1 and one["read_at"] is None
    await service.read(A, one["id"])
    first_read = repo.reports[(A, "2026-10-19")]["read_at"]
    assert (await service.read(A, one["id"]))["read_at"] == first_read
    assert (await service.generate(A))["read_at"] == first_read
    assert all(u == A for _, u, _ in repo.calls)
    queries = {t: f for t, _, f in repo.calls if t in ["skin_journal", "skin_analyses"]}
    assert "notes" not in queries["skin_journal"]["select"] and "and" in queries["skin_journal"]


async def test_cross_user_get_and_read_denied_and_timezone_required():
    repo = Repo()
    service = WeeklyService(repo, lambda: NOW)
    item = (await service.generate(A))["id"]
    for action in [service.get(B, item), service.read(B, item)]:
        with pytest.raises(HTTPException) as e:
            await action
        assert e.value.status_code == 404
    repo.zones = {}
    with pytest.raises(HTTPException) as e:
        await service.generate(B)
    assert e.value.status_code == 409


async def test_concurrent_unique_conflict_returns_existing_snapshot():
    repo = Repo()
    service = WeeklyService(repo, lambda: NOW)
    await service.generate(A)
    original = repo.owned
    calls = 0

    async def hidden_once(table, user, **filters):
        nonlocal calls
        if table == "weekly_reports":
            calls += 1
            if calls == 1:
                return []
        return await original(table, user, **filters)

    repo.owned = hidden_once
    result = await service.generate(A)
    assert len(repo.reports) == 1 and result["week_start"] == "2026-10-19"


async def test_worker_failure_isolated_and_retry_safe(monkeypatch):
    from app import weekly_worker

    repo = Repo()
    seen = []

    async def generate(self, user):
        seen.append(user)
        if user == A:
            raise RuntimeError("simulated failure")

    monkeypatch.setattr(weekly_worker.WeeklyService, "generate", generate)
    assert await sweep(repo) == {"checked": 2, "failed": 1}
    assert seen == [A, B]


async def test_routes_auth_and_forbidden_owner_inputs():
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from app.weekly_reports import router

    repo = Repo()
    app = FastAPI()

    async def auth():
        return A

    app.include_router(router(repo, auth))
    with TestClient(app) as c:
        assert c.get("/v1/weekly-reports").status_code == 200
        assert c.get("/v1/weekly-reports/" + str(uuid4())).status_code == 404
        assert c.post("/v1/weekly-reports/generate", json={"user_id": B}).status_code == 422
        assert (
            c.post(
                "/v1/weekly-reports/" + str(uuid4()) + "/read", json={"read_at": "2030-01-01"}
            ).status_code
            == 422
        )
