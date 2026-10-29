"""Deterministic weekly snapshots. No provider calls, photos, notes or combined scores."""

import math
from collections import Counter
from datetime import UTC, datetime, time, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query

from app.domain import utcnow
from app.skincare import Input, SkincareService, summarize


class ReportAction(Input):
    """No client-controlled owner, period, read time or computed report content."""


def previous_week(now, timezone):
    local = now.astimezone(ZoneInfo(timezone)).date()
    start = local - timedelta(days=local.weekday() + 7)
    return start, start + timedelta(days=6)


def bounds(start, timezone):
    zone = ZoneInfo(timezone)
    return (
        datetime.combine(start, time.min, zone).astimezone(UTC),
        datetime.combine(start + timedelta(days=7), time.min, zone).astimezone(UTC),
    )


def valid_score(value):
    return (
        isinstance(value, (float, int))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and 1 <= value <= 100
    )


def group(analysis):
    metrics = analysis.get("metrics")
    if (
        analysis.get("api_version") != "2.1"
        or analysis.get("response_format") != "zip"
        or not isinstance(metrics, list)
        or not metrics
    ):
        return None
    concerns = {m.get("concern") for m in metrics if isinstance(m, dict)}
    if not concerns or any(not isinstance(c, str) or not c.startswith("hd_") for c in concerns):
        return None
    return tuple(sorted(concerns))


def analysis_summary(analyses):
    ordered = sorted(analyses, key=lambda a: (a["analyzed_at"], a["id"]))
    valid = [a for a in ordered if valid_score(a.get("overall_score"))]
    result = {
        "count": len(ordered),
        "valid_scores": len(valid),
        "comparison": None,
        "message": "At least two compatible analyses within this week are needed for a comparison.",
    }
    if valid:
        last = valid[-1]
        result["latest"] = {
            k: last.get(k)
            for k in ["id", "analyzed_at", "overall_score", "api_version", "response_format"]
        }
    if len(valid) >= 2:
        first, last = valid[0], valid[-1]
        if group(first) is not None and group(first) == group(last):

            def metrics(a):
                return {
                    (m["concern"], m.get("region")): m
                    for m in a["metrics"]
                    if isinstance(m, dict) and isinstance(m.get("concern"), str)
                }

            one, two = metrics(first), metrics(last)
            changes = []
            for key in sorted(one.keys() & two.keys(), key=str):
                fields = {}
                for field in ["ui_score", "raw_score"]:
                    x, y = one[key].get(field), two[key].get(field)
                    if valid_score(x) and valid_score(y):
                        fields[field] = {"first": x, "last": y, "change": round(y - x, 4)}
                if fields:
                    changes.append({"concern": key[0], "region": key[1], **fields})
            result["comparison"] = {
                "first_id": first["id"],
                "last_id": last["id"],
                "first_at": first["analyzed_at"],
                "last_at": last["analyzed_at"],
                "first_score": first["overall_score"],
                "last_score": last["overall_score"],
                "score_change": round(last["overall_score"] - first["overall_score"], 4),
                "metrics": changes,
            }
            result["message"] = (
                "First and last valid compatible results in this week. Higher scores indicate more favorable visible characteristics in YouCam’s system; lighting, angle and camera conditions can affect comparisons. This does not show that a product or routine caused a change."
            )
        else:
            result["message"] = (
                "First and last results use incompatible or unverified analysis formats; no change is calculated."
            )
    return result


def build_content(revisions, checkins, analyses, journal, start, end):
    adherence = summarize(revisions, checkins, end + timedelta(days=1), start, end)
    names = {
        r["routine_id"]: r["definition"]["name"]
        for r in sorted(revisions, key=lambda r: r["version"])
        if r["effective_from"] <= end.isoformat()
    }
    for routine in adherence["routines"]:
        routine["name"] = names.get(routine["routine_id"], "Routine")
    counts = Counter(c for entry in journal for c in entry.get("concerns", []))
    severities = Counter(entry["severity"] for entry in journal if entry.get("severity"))
    skin = analysis_summary(analyses)
    suggestions = []
    if not adherence["scheduled"]:
        suggestions.append("Create a routine that fits your schedule whenever you are ready.")
    elif adherence["partial"]:
        suggestions.append(
            "Partial check-ins are recorded separately. You can review whether your routine steps fit your day."
        )
    if skin["count"] < 2:
        suggestions.append(
            "A new scan is optional. Comparable lighting and angle help when you choose to track visible changes."
        )
    if counts.get("irritation") or severities.get("severe"):
        suggestions.append(
            "If a product appears to cause a reaction, stop using it and seek professional advice. These are your observations, not an AI diagnosis."
        )
    return {
        "schema_version": 1,
        "routine": adherence,
        "skin": skin,
        "journal": {
            "entries": len(journal),
            "concerns": dict(sorted(counts.items())),
            "severity_counts": dict(sorted(severities.items())),
        },
        "suggestions": suggestions,
        "notes": "Routine completion, YouCam scores and user-reported observations are separate signals. This snapshot reflects records available when generated; later corrections do not rewrite it. No journal notes or photos are copied into reports. Streaks are measured as of the end of this week; unscheduled days do not break them.",
    }


class WeeklyService:
    def __init__(self, repo, clock=utcnow):
        self.repo, self.clock = repo, clock

    async def get(self, user, item):
        rows = await self.repo.owned("weekly_reports", user, id="eq." + item)
        if not rows:
            raise HTTPException(404, "Weekly report not found.")
        return rows[0]

    async def generate(self, user):
        settings = await self.repo.owned("skincare_settings", user)
        if not settings:
            raise HTTPException(
                409, "Choose your tracking timezone before creating a weekly report."
            )
        zone = settings[0]["timezone"]
        start, end = previous_week(self.clock(), zone)
        existing = await self.repo.owned("weekly_reports", user, week_start="eq." + str(start))
        if existing:
            return existing[0]
        tracking = SkincareService(self.repo, self.clock)
        revisions = await tracking.all(
            "routine_revisions",
            user,
            "routine_id.asc,version.asc",
            effective_from="lte." + str(end),
        )
        # Full history is needed for an accurate as-of-week-end streak; later check-ins are excluded.
        checkins = await tracking.all(
            "routine_checkins", user, "local_date.asc,id.asc", local_date="lte." + str(end)
        )
        begin, finish = bounds(start, zone)

        def within(field):
            return f"({field}.gte.{begin.isoformat()},{field}.lt.{finish.isoformat()})"

        analyses = await tracking.all(
            "skin_analyses",
            user,
            "analyzed_at.asc,id.asc",
            **{
                "and": within("analyzed_at"),
                "select": "id,overall_score,metrics,api_version,response_format,analyzed_at",
            },
        )
        journal = await tracking.all(
            "skin_journal",
            user,
            "observed_at.asc,id.asc",
            **{"and": within("observed_at"), "select": "id,concerns,severity"},
        )
        content = build_content(revisions, checkins, analyses, journal, start, end)
        response = await self.repo.request(
            "POST",
            "/rest/v1/weekly_reports",
            params={"on_conflict": "user_id,week_start"},
            json={
                "user_id": user,
                "week_start": str(start),
                "week_end": str(end),
                "timezone": zone,
                "content": content,
            },
            headers={"Prefer": "resolution=ignore-duplicates,return=representation"},
        )
        rows = response.json()
        if not rows:
            rows = await self.repo.owned("weekly_reports", user, week_start="eq." + str(start))
        if not rows:
            raise HTTPException(503, "Report save could not be confirmed. Retry safely.")
        return rows[0]

    async def read(self, user, item):
        row = await self.get(user, item)
        if row.get("read_at"):
            return row
        response = await self.repo.request(
            "PATCH",
            "/rest/v1/weekly_reports",
            params={"id": "eq." + item, "user_id": "eq." + user, "read_at": "is.null"},
            json={"read_at": self.clock().isoformat()},
            headers={"Prefer": "return=representation"},
        )
        return next(iter(response.json()), None) or await self.get(user, item)


def router(repo, authenticate):
    routes = APIRouter(prefix="/v1/weekly-reports", tags=["Weekly Beauty Brief"])
    service = WeeklyService(repo)

    @routes.get("")
    async def listing(offset: int = Query(default=0, ge=0, le=1000000), user=Depends(authenticate)):
        rows = await repo.owned(
            "weekly_reports",
            user,
            order="week_start.desc,id.asc",
            limit="21",
            offset=str(offset),
            select="id,week_start,week_end,timezone,generated_at,read_at",
        )
        unread = await repo.owned("weekly_reports", user, read_at="is.null", limit="1", select="id")
        return {"items": rows[:20], "has_more": len(rows) > 20, "has_unread": bool(unread)}

    @routes.post("/generate")
    async def generate(body: ReportAction | None = None, user=Depends(authenticate)):
        return await service.generate(user)

    @routes.get("/{item}")
    async def get(item: UUID, user=Depends(authenticate)):
        return await service.get(user, str(item))

    @routes.post("/{item}/read")
    async def read(item: UUID, body: ReportAction | None = None, user=Depends(authenticate)):
        return await service.read(user, str(item))

    return routes
