import hashlib
from datetime import datetime, timedelta
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import ValidationError

from app.domain import ContractError, ProviderError, utcnow
from app.vto_provider import VtoOptions, VtoProvider, prepare_vto_image
from app.vto_repository import VtoRepository

CONSENT = "makeup-vto-v1"
FIELDS = (
    "id",
    "status",
    "error_code",
    "options",
    "created_at",
    "updated_at",
    "expires_at",
    "source_cleanup",
    "result_cleanup",
)


def public(job):
    return {key: job.get(key) for key in FIELDS}


class VtoService:
    def __init__(self, repo, provider):
        self.repo, self.provider = repo, provider

    async def create(self, user, key, content, consent, options):
        if consent != CONSENT:
            raise HTTPException(422, "Explicit makeup-vto-v1 consent is required.")
        digest = hashlib.sha256(content).hexdigest()
        rows = await self.repo.owned(user, idempotency_key=f"eq.{key}")
        if rows:
            return self.replay(rows[0], digest, options)
        try:
            prepared = prepare_vto_image(content)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        if options.mode == "look":
            if options.template_id not in {r["id"] for r in await self.provider.templates()}:
                raise HTTPException(422, "Choose a currently listed Look template.")
        now, job_id = utcnow(), str(uuid4())
        job = {
            "id": job_id,
            "user_id": user,
            "idempotency_key": key,
            "image_sha256": digest,
            "options": options.model_dump(),
            "consent_version": consent,
            "status": "uploading",
            "source_path": f"{user}/{job_id}/source.jpg",
            "result_path": f"{user}/{job_id}/preview.jpg",
            "expires_at": (now + timedelta(hours=1)).isoformat(),
        }
        created = await self.repo.insert(job)
        if not created:
            rows = await self.repo.owned(user, idempotency_key=f"eq.{key}")
            return self.replay(rows[0], digest, options)
        try:
            await self.repo.upload(job["source_path"], prepared)
            rows = await self.repo.patch(
                job_id,
                {"status": "pending", "updated_at": utcnow().isoformat()},
                user_id=f"eq.{user}",
                status="eq.uploading",
                expires_at=f"gt.{utcnow().isoformat()}",
            )
            if not rows:
                raise ValueError("late_upload")
            return public(rows[0])
        except Exception:
            # Reset cleanup even when an upload finished after an expiry cleanup pass.
            await self.repo.patch(
                job_id,
                {
                    "source_cleanup": "pending",
                    "cleanup_verified": False,
                    "cleanup_next_at": utcnow().isoformat(),
                },
                user_id=f"eq.{user}",
            )
            await self.repo.patch(
                job_id,
                {"status": "failed", "error_code": "upload_failed"},
                user_id=f"eq.{user}",
                status="eq.uploading",
            )
            raise HTTPException(
                503,
                "Upload could not be confirmed. Refresh VTO jobs before retrying; reuse the same request.",
            ) from None

    @staticmethod
    def replay(job, digest, options):
        if job["image_sha256"] != digest or job["options"] != options.model_dump():
            raise HTTPException(409, "This retry key belongs to a different image or effect.")
        return public(job)

    async def get(self, user, job_id):
        rows = await self.repo.owned(user, id=f"eq.{job_id}")
        if not rows:
            raise HTTPException(404, "VTO job not found.")
        return rows[0]

    async def preview(self, user, job_id):
        job = await self.get(user, job_id)
        if (
            job["status"] != "completed"
            or job["result_cleanup"] == "deleted"
            or datetime.fromisoformat(job["expires_at"].replace("Z", "+00:00")) <= utcnow()
        ):
            raise HTTPException(
                410, "Preview is not available or its one-hour retention has ended."
            )
        return await self.repo.download(job["result_path"])


def router(repository, settings, http, authenticate):
    routes = APIRouter(prefix="/v1/vto", tags=["Makeup VTO"])
    provider = VtoProvider(settings, http)
    service = VtoService(VtoRepository(repository), provider)

    async def user(user_id=Depends(authenticate)):
        if not settings.youcam_vto_enabled:
            raise HTTPException(
                503, "VTO is not enabled yet. Complete its migration and provider setup first."
            )
        return user_id

    @routes.get("/templates")
    async def templates(owner=Depends(user)):
        try:
            return await provider.templates()
        except (ProviderError, ContractError):
            raise HTTPException(
                503, "Look templates are unavailable. Retry or use lip color."
            ) from None

    @routes.post("/jobs", status_code=202)
    async def create(
        image: UploadFile = File(),
        consent_version: str = Form(),
        options: str = Form(),
        idempotency_key: UUID = Header(),
        owner=Depends(user),
    ):
        try:
            content = await image.read(10_000_000)
        finally:
            await image.close()
        if len(content) >= 10_000_000:
            raise HTTPException(413, "Choose an image under 10 MB.")
        try:
            if len(options) > 2000:
                raise ValueError()
            parsed = VtoOptions.model_validate_json(options)
        except (ValidationError, ValueError):
            raise HTTPException(422, "Invalid VTO effect options.") from None
        try:
            return await service.create(
                owner, str(idempotency_key), content, consent_version, parsed
            )
        except (ProviderError, ContractError):
            raise HTTPException(503, "Provider configuration unavailable. Retry safely.") from None

    @routes.get("/jobs")
    async def history(owner=Depends(user)):
        return [
            public(j)
            for j in await service.repo.owned(owner, order="created_at.desc,id.asc", limit="50")
        ]

    @routes.get("/jobs/{job_id}")
    async def get(job_id: UUID, owner=Depends(user)):
        return public(await service.get(owner, str(job_id)))

    @routes.get("/jobs/{job_id}/preview")
    async def preview(job_id: UUID, owner=Depends(user)):
        return Response(
            await service.preview(owner, str(job_id)),
            media_type="image/jpeg",
            headers={"Cache-Control": "no-store, private", "X-Content-Type-Options": "nosniff"},
        )

    return routes
