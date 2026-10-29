"""Run as a separate process: python -m app.worker. Durable leases live in PostgreSQL."""

import asyncio
import logging
from datetime import datetime, timedelta
from uuid import uuid4

import httpx

from app.config import Settings
from app.domain import ContractError, ProviderError, transition, utcnow
from app.parser import parse_zip
from app.provider import ACTIONS, YouCam
from app.repository import Supabase

log = logging.getLogger(__name__)


class Worker:
    def __init__(self, repo, provider, settings):
        self.repo, self.provider, self.s = repo, provider, settings

    async def update(self, job, **values):
        if "status" in values:
            transition(job["status"], values["status"])
        values.update(updated_at=utcnow().isoformat())
        rows = await self.repo.patch(
            job["id"],
            values,
            lease_token=f"eq.{job['lease_token']}",
            status=f"eq.{job['status']}",
            lease_until=f"gt.{utcnow().isoformat()}",
        )
        if not rows:
            raise ProviderError("lease_lost")
        job.update(rows[0])

    async def fail(self, job, code):
        await self.update(
            job,
            status="failed",
            error_code=code,
            lease_until=None,
            lease_token=None,
            image_delete_after=utcnow().isoformat(),
        )

    async def process(self, job):
        if datetime.fromisoformat(job["expires_at"].replace("Z", "+00:00")) < utcnow():
            await self.update(
                job,
                status="expired",
                error_code="job_expired",
                lease_until=None,
                lease_token=None,
                image_delete_after=utcnow().isoformat(),
            )
            return
        if job["status"] == "submitting":
            # Crash between POST and saving task_id: cannot prove whether provider accepted it.
            await self.fail(job, "submission_unknown")
            return
        try:
            if job["status"] == "pending":
                content = await self.repo.download(job["image_path"])
                file_id = await self.provider.upload(content)
                # Commit boundary BEFORE a potentially billable POST.
                await self.update(job, status="submitting")
                task_id = await self.provider.submit(file_id)
                await self.update(
                    job,
                    status="processing",
                    external_task_id=task_id,
                    next_poll_at=(utcnow() + timedelta(seconds=self.s.poll_seconds)).isoformat(),
                    lease_until=None,
                    lease_token=None,
                )
                return
            state, url = await self.provider.status(job["external_task_id"])
            if state == "running":
                await self.update(
                    job,
                    next_poll_at=(utcnow() + timedelta(seconds=self.s.poll_seconds)).isoformat(),
                    lease_until=None,
                    lease_token=None,
                )
                return
            result = parse_zip(await self.provider.download(url), ACTIONS)
            await self.repo.rpc(
                "complete_analysis_job",
                {
                    "p_job": job["id"],
                    "p_token": job["lease_token"],
                    "p_score": result["overall_score"],
                    "p_metrics": result["metrics"],
                    "p_warnings": result["warnings"],
                },
            )
        except (ProviderError, ContractError, httpx.HTTPError) as exc:
            if job["status"] == "submitting":
                await self.fail(job, "submission_unknown")
                return
            retryable = isinstance(exc, httpx.HTTPError) or getattr(exc, "retryable", False)
            attempts = job.get("attempts", 0) + 1
            if retryable and attempts < 5:
                await self.update(
                    job,
                    attempts=attempts,
                    next_poll_at=(
                        utcnow() + timedelta(seconds=min(300, 10 * 2**attempts))
                    ).isoformat(),
                    lease_until=None,
                    lease_token=None,
                )
            else:
                code = (
                    str(exc)
                    if isinstance(exc, ContractError)
                    else getattr(exc, "code", "network_failed")
                )
                await self.fail(job, code)

    async def cleanup(self):
        rows = await self.repo.rows(
            "analysis_jobs",
            cleanup_status="neq.deleted",
            image_delete_after=f"lte.{utcnow().isoformat()}",
            cleanup_next_at=f"lte.{utcnow().isoformat()}",
            limit="20",
        )
        for job in rows:
            try:
                await self.repo.delete(job["image_path"])
                await self.repo.patch(
                    job["id"],
                    {
                        "cleanup_status": "deleted",
                        "cleanup_error": None,
                        "cleanup_attempts": job["cleanup_attempts"] + 1,
                    },
                )
            except httpx.HTTPError:
                await self.repo.patch(
                    job["id"],
                    {
                        "cleanup_status": "failed",
                        "cleanup_error": "storage_delete_failed",
                        "cleanup_attempts": job["cleanup_attempts"] + 1,
                        "cleanup_next_at": (utcnow() + timedelta(minutes=5)).isoformat(),
                    },
                )
                log.warning("Temporary-image deletion failed; retry recorded")

    async def tick(self):
        await self.repo.rpc("expire_analysis_jobs")
        await self.cleanup()
        jobs = await self.repo.rpc("claim_analysis_job", {"p_token": str(uuid4())})
        if jobs:
            await self.process(jobs[0])
        return bool(jobs)


async def main():
    settings = Settings()
    async with httpx.AsyncClient(follow_redirects=False) as client:
        worker = Worker(Supabase(settings, client), YouCam(settings, client), settings)
        while True:
            try:
                busy = await worker.tick()
            except Exception:
                # Do not print exceptions containing signed URLs, headers, or image data.
                log.error("Worker tick failed; durable lease will allow recovery")
                busy = False
            await asyncio.sleep(1 if busy else 5)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main())
