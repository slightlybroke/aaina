"""Private routine tracking. UTC instants, explicit IANA dates, no provider calls."""

from datetime import UTC, date, datetime, timedelta
from typing import Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.domain import utcnow


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Preferences(Input):
    timezone: str = Field(default="UTC", max_length=100)

    @field_validator("timezone")
    @classmethod
    def valid_zone(cls, value):
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError("Choose an IANA timezone such as Asia/Kolkata or UTC.") from None
        return value


class Step(Input):
    id: UUID
    name: str = Field(min_length=1, max_length=100)
    product: str = Field(default="", max_length=200)
    notes: str = Field(default="", max_length=1000)


class Routine(Input):
    name: str = Field(min_length=1, max_length=100)
    description: str = Field(default="", max_length=1000)
    kind: Literal["morning", "evening", "custom"] = "morning"
    status: Literal["active", "paused", "archived"] = "active"
    days: list[int] = Field(min_length=1, max_length=7)
    steps: list[Step] = Field(min_length=1, max_length=30)
    expected_revision: UUID | None = None

    @model_validator(mode="after")
    def unique_steps_days(self):
        if len(set(self.days)) != len(self.days) or any(d not in range(1, 8) for d in self.days):
            raise ValueError("Select unique weekdays from 1 (Monday) to 7 (Sunday).")
        if len({s.id for s in self.steps}) != len(self.steps):
            raise ValueError("Step identifiers must be unique.")
        return self


class Checkin(Input):
    local_date: date
    revision_id: UUID
    completed_steps: list[UUID] = Field(max_length=30)

    @field_validator("completed_steps")
    @classmethod
    def unique(cls, value):
        if len(set(value)) != len(value):
            raise ValueError("A step may only be completed once.")
        return value


Concern = Literal[
    "dryness", "oiliness", "blemishes", "redness", "irritation", "texture", "sensitivity", "other"
]


class Journal(Input):
    concerns: list[Concern] = Field(min_length=1, max_length=8)
    severity: Literal["mild", "moderate", "severe"] | None = None
    notes: str = Field(default="", max_length=3000)
    observed_at: datetime

    @model_validator(mode="after")
    def valid_observation(self):
        if self.observed_at.tzinfo is None or self.observed_at.utcoffset() is None:
            raise ValueError("Observation time must include a timezone offset.")
        self.observed_at = self.observed_at.astimezone(UTC)
        if self.observed_at > utcnow() + timedelta(minutes=1):
            raise ValueError("Observation cannot be in the future.")
        if len(set(self.concerns)) != len(self.concerns):
            raise ValueError("Select each concern once.")
        return self


def revision_on(revisions, day):
    eligible = [r for r in revisions if r["effective_from"] <= day.isoformat()]
    return max(eligible, key=lambda r: (r["effective_from"], r["version"]), default=None)


def daily_state(revisions, checkins, day):
    revision = revision_on(revisions, day)
    if not revision:
        return None
    definition = revision["definition"]
    scheduled = definition["status"] == "active" and day.isoweekday() in definition["days"]
    checkin = next((c for c in checkins if c["local_date"] == day.isoformat()), None)
    done = set(checkin["completed_steps"]) if checkin else set()
    required = {s["id"] for s in definition["steps"]}
    return {
        "routine_id": revision["routine_id"],
        "revision_id": revision["id"],
        "local_date": day.isoformat(),
        "definition": definition,
        "scheduled": scheduled,
        "completed_steps": sorted(done),
        "completion": "complete"
        if scheduled and required <= done
        else "partial"
        if scheduled and done
        else "incomplete",
        "updated_at": checkin["updated_at"] if checkin else None,
    }


def summarize(revisions, checkins, today, start, end):
    """One scheduled routine-day is one opportunity. Today's pending work has grace."""
    grouped = {}
    for revision in revisions:
        grouped.setdefault(revision["routine_id"], []).append(revision)
    scheduled = completed = partial = 0
    routines = []
    for routine_id, history in grouped.items():
        records = [c for c in checkins if c["routine_id"] == routine_id]
        first = date.fromisoformat(min(r["effective_from"] for r in history))
        streak = longest = current = 0
        day = first
        while day <= min(end, today):
            state = daily_state(history, records, day)
            if state and state["scheduled"]:
                complete = state["completion"] == "complete"
                if day >= start:
                    scheduled += 1
                    completed += int(complete)
                    partial += int(state["completion"] == "partial")
                if complete:
                    streak += 1
                    longest = max(longest, streak)
                elif day != today:
                    streak = 0
                current = streak
            day += timedelta(days=1)
        routines.append(
            {"routine_id": routine_id, "current_streak": current, "longest_streak": longest}
        )
    return {
        "start": start.isoformat(),
        "end": min(end, today).isoformat(),
        "scheduled": scheduled,
        "completed": completed,
        "partial": partial,
        "adherence_percent": round(100 * completed / scheduled, 1) if scheduled else None,
        "routines": routines,
    }


class SkincareService:
    def __init__(self, repo, clock=utcnow):
        self.repo, self.clock = repo, clock

    async def all(self, table, user, order, **filters):
        result = []
        while True:
            page = await self.repo.owned(
                table, user, order=order, limit="500", offset=str(len(result)), **filters
            )
            result.extend(page)
            # A project can configure a lower PostgREST row cap than our page size.
            # Advance by actual rows until empty rather than silently losing history.
            if not page:
                return result

    async def preferences(self, user):
        rows = await self.repo.owned("skincare_settings", user)
        locked = bool(await self.repo.owned("routines", user, limit="1"))
        zone = rows[0]["timezone"] if rows else "UTC"
        return {
            "timezone": zone,
            "timezone_locked": locked,
            "today": self.clock().astimezone(ZoneInfo(zone)).date().isoformat(),
        }

    async def write(self, user, action, data):
        result = await self.repo.rpc(
            "skincare_write", {"p_user": user, "p_action": action, "p_data": data}
        )
        if "error" in result:
            raise HTTPException(result["status"], result["error"])
        return result

    async def routines(self, user, day=None):
        preferences = await self.preferences(user)
        day = day or date.fromisoformat(preferences["today"])
        if day > date.fromisoformat(preferences["today"]):
            raise HTTPException(422, "Future check-ins are not available.")
        revisions = await self.all("routine_revisions", user, "routine_id.asc,version.asc")
        checkins = await self.all("routine_checkins", user, "id.asc", local_date=f"eq.{day}")
        result = []
        for routine_id in dict.fromkeys(r["routine_id"] for r in revisions):
            history = [r for r in revisions if r["routine_id"] == routine_id]
            state = daily_state(
                history, [c for c in checkins if c["routine_id"] == routine_id], day
            )
            if state:
                state["latest_revision"] = max(history, key=lambda r: r["version"])
                result.append(state)
        return {**preferences, "date": day.isoformat(), "routines": result}

    async def history(self, user, start, end):
        prefs = await self.preferences(user)
        today = date.fromisoformat(prefs["today"])
        end = min(end or today, today)
        start = start or end - timedelta(days=29)
        if start > end or (end - start).days > 365:
            raise HTTPException(
                422, "Choose a date range of at most 366 days ending today or earlier."
            )
        revisions = await self.all("routine_revisions", user, "routine_id.asc,version.asc")
        checkins = await self.all("routine_checkins", user, "id.asc")
        summary = summarize(revisions, checkins, today, start, end)
        days = []
        for routine_id in dict.fromkeys(r["routine_id"] for r in revisions):
            history = [r for r in revisions if r["routine_id"] == routine_id]
            records = [c for c in checkins if c["routine_id"] == routine_id]
            for offset in range((end - start).days + 1):
                state = daily_state(history, records, start + timedelta(days=offset))
                if state and state["scheduled"]:
                    days.append(state)
        return {
            **prefs,
            "summary": summary,
            "days": sorted(days, key=lambda r: (r["local_date"], r["routine_id"]), reverse=True),
        }


def router(repo, authenticated_user):
    routes = APIRouter(prefix="/v1/skincare", tags=["Skincare tracking"])
    service = SkincareService(repo)

    @routes.get("/settings")
    async def preferences(user=Depends(authenticated_user)):
        return await service.preferences(user)

    @routes.put("/settings")
    async def save_preferences(body: Preferences, user=Depends(authenticated_user)):
        return await service.write(user, "settings", body.model_dump())

    @routes.get("/routines")
    async def routines(day: date | None = None, user=Depends(authenticated_user)):
        return await service.routines(user, day)

    @routes.put("/routines/{routine_id}")
    async def save_routine(routine_id: UUID, body: Routine, user=Depends(authenticated_user)):
        data = body.model_dump(mode="json", exclude={"expected_revision"})
        return await service.write(
            user,
            "routine",
            {
                "id": str(routine_id),
                "definition": data,
                "expected_revision": str(body.expected_revision)
                if body.expected_revision
                else None,
            },
        )

    @routes.put("/routines/{routine_id}/checkins")
    async def checkin(routine_id: UUID, body: Checkin, user=Depends(authenticated_user)):
        return await service.write(
            user, "checkin", {"id": str(routine_id), **body.model_dump(mode="json")}
        )

    @routes.get("/history")
    async def history(
        start: date | None = None, end: date | None = None, user=Depends(authenticated_user)
    ):
        return await service.history(user, start, end)

    @routes.get("/journal")
    async def journal(offset: int = Query(default=0, ge=0), user=Depends(authenticated_user)):
        return await repo.owned(
            "skin_journal", user, order="observed_at.desc,id.asc", limit="50", offset=str(offset)
        )

    @routes.put("/journal/{entry_id}")
    async def save_journal(entry_id: UUID, body: Journal, user=Depends(authenticated_user)):
        return await service.write(
            user, "journal", {"id": str(entry_id), **body.model_dump(mode="json")}
        )

    @routes.delete("/journal/{entry_id}")
    async def delete_journal(entry_id: UUID, user=Depends(authenticated_user)):
        return await service.write(user, "journal_delete", {"id": str(entry_id)})

    return routes
