import hashlib
from datetime import timedelta
from uuid import uuid4

from fastapi import HTTPException

from app.domain import utcnow
from app.images import prepare_image

PUBLIC_JOB_FIELDS = ("id", "status", "error_code", "created_at", "updated_at", "cleanup_status")


def public_job(job):
    return {key: job.get(key) for key in PUBLIC_JOB_FIELDS}


class AnalysisService:
    def __init__(self, repository, settings):
        self.repo, self.s = repository, settings

    async def create(self, user_id, key, content, consent):
        if consent != "skin-analysis-v1":
            raise HTTPException(422, "Explicit skin-analysis-v1 consent is required.")
        # Original bytes define the retry identity, independent of JPEG encoder versions.
        digest = hashlib.sha256(content).hexdigest()
        existing = await self.repo.owned("analysis_jobs", user_id, idempotency_key=f"eq.{key}")
        if existing:
            return self.replay(existing[0], digest)
        try:
            prepared = prepare_image(content)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        now, job_id = utcnow(), str(uuid4())
        job = {
            "id": job_id,
            "user_id": user_id,
            "idempotency_key": key,
            "image_sha256": digest,
            "image_path": f"{user_id}/{job_id}/source.jpg",
            "consent_version": consent,
            "status": "uploading",
            "expires_at": (now + timedelta(seconds=self.s.job_timeout_seconds)).isoformat(),
            "image_delete_after": (now + timedelta(seconds=self.s.image_ttl_seconds)).isoformat(),
        }
        created = await self.repo.insert_job(job)
        if not created:  # Another request won the database unique constraint.
            existing = await self.repo.owned("analysis_jobs", user_id, idempotency_key=f"eq.{key}")
            return self.replay(existing[0], digest)
        try:
            await self.repo.upload(job["image_path"], prepared)
            updated = await self.repo.patch(
                job_id,
                {"status": "pending", "updated_at": utcnow().isoformat()},
                user_id=f"eq.{user_id}",
                status="eq.uploading",
            )
            if not updated:
                # A timed-out upload can finish after expiry/cleanup; remove that late object.
                await self.repo.patch(
                    job_id,
                    {
                        "cleanup_status": "pending",
                        "cleanup_next_at": utcnow().isoformat(),
                        "image_delete_after": utcnow().isoformat(),
                    },
                    user_id=f"eq.{user_id}",
                )
                try:
                    await self.repo.delete(job["image_path"])
                except Exception:
                    await self.repo.patch(
                        job_id,
                        {
                            "cleanup_status": "failed",
                            "cleanup_error": "late_upload_delete_failed",
                        },
                        user_id=f"eq.{user_id}",
                    )
                raise HTTPException(
                    409, "Upload expired. Select the image again to start a new scan."
                )
            return public_job(updated[0])
        except HTTPException:
            raise
        except Exception:
            # Keep a durable record, including failures with uncertain upload outcomes.
            await self.repo.patch(
                job_id,
                {
                    "status": "failed",
                    "error_code": "upload_failed",
                    "image_delete_after": utcnow().isoformat(),
                    "cleanup_status": "pending",
                },
                user_id=f"eq.{user_id}",
                status="eq.uploading",
            )
            raise HTTPException(
                503, "Upload failed. Check this job before starting a new scan."
            ) from None

    @staticmethod
    def replay(job, digest):
        if job["image_sha256"] != digest:
            raise HTTPException(409, "This retry key belongs to a different image.")
        return public_job(job)

    async def get(self, user_id, job_id):
        jobs = await self.repo.owned("analysis_jobs", user_id, id=f"eq.{job_id}")
        if not jobs:
            raise HTTPException(404, "Analysis job not found.")
        result = public_job(jobs[0])
        if result["status"] == "completed":
            analyses = await self.repo.owned("skin_analyses", user_id, job_id=f"eq.{job_id}")
            result["analysis"] = analyses[0] if analyses else None
        return result

    async def history(self, user_id, offset=0):
        return await self.repo.owned(
            "skin_analyses", user_id, order="analyzed_at.desc,id.asc", limit="50", offset=str(offset)
        )

    async def jobs(self, user_id):
        rows = await self.repo.owned("analysis_jobs", user_id, order="created_at.desc", limit="20")
        return [public_job(row) for row in rows]
