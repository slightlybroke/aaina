"""python -m app.weekly_worker. Restart-safe scheduled weekly snapshots, no external AI."""

import asyncio
import logging

import httpx

from app.config import Settings
from app.repository import Supabase
from app.weekly_reports import WeeklyService

log = logging.getLogger(__name__)


async def sweep(repo):
    offset = 0
    generated = failed = 0
    while True:
        rows = await repo.rows(
            "skincare_settings",
            select="user_id",
            order="user_id.asc",
            limit="100",
            offset=str(offset),
        )
        if not rows:
            break
        for row in rows:
            try:
                await WeeklyService(repo).generate(row["user_id"])
                generated += 1
            except Exception as exc:
                # No identifiers/notes/provider bodies in logs. Retry on next sweep.
                failed += 1
                log.warning("Weekly generation failed (%s); retry next sweep", type(exc).__name__)
        offset += len(rows)
    return {"checked": generated + failed, "failed": failed}


async def main():
    settings = Settings()
    async with httpx.AsyncClient(follow_redirects=False) as http:
        repo = Supabase(settings, http)
        while True:
            try:
                log.info("Weekly sweep: %s", await sweep(repo))
            except Exception as exc:
                log.warning(
                    "Weekly sweep unavailable (%s); retry in five minutes", type(exc).__name__
                )
            await asyncio.sleep(300)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    # Request URLs can contain owner IDs; keep routine HTTP traffic out of logs.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    asyncio.run(main())
