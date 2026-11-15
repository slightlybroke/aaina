from contextlib import asynccontextmanager
from uuid import UUID

import httpx
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from app.beauty_memory import router as memory_router
from app.config import Settings
from app.discovery import router as discovery_router
from app.education import router as education_router
from app.gemini_looks import router as gemini_router
from app.limits import UploadLimit
from app.live_voice import router as live_router
from app.look_planner import router as look_router
from app.makeup_preferences import router as preferences_router
from app.repository import Supabase
from app.services import AnalysisService
from app.skincare import router as skincare_router
from app.vanity import router as vanity_router
from app.vto import router as vto_router
from app.weekly_reports import router as weekly_router


def create_app(settings=None, repository=None, client=None):
    settings = settings or Settings()
    http = client or httpx.AsyncClient(follow_redirects=False)
    repo = repository or Supabase(settings, http)
    service = AnalysisService(repo, settings)

    @asynccontextmanager
    async def lifespan(app):
        yield
        if client is None:
            await http.aclose()

    app = FastAPI(title="aaina", lifespan=lifespan)
    app.add_middleware(UploadLimit)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_methods=["GET", "POST", "PUT", "DELETE"],
        allow_headers=["Authorization", "Idempotency-Key", "Content-Type"],
    )

    @app.exception_handler(httpx.HTTPError)
    async def upstream_error(request, exc):
        from fastapi.responses import JSONResponse

        return JSONResponse(
            status_code=503, content={"detail": "Service temporarily unavailable. Retry safely."}
        )

    async def authenticated_user(authorization: str = Header(default="")):
        if not authorization.startswith("Bearer ") or len(authorization) > 8192:
            raise HTTPException(401, "Sign in to continue.")
        response = await http.get(
            settings.supabase_url + "/auth/v1/user",
            headers={"apikey": settings.supabase_publishable_key, "Authorization": authorization},
            timeout=15,
        )
        if response.status_code in (401, 403):
            raise HTTPException(401, "Your session expired. Sign in again.")
        response.raise_for_status()
        try:
            return str(UUID(response.json()["id"]))
        except (ValueError, KeyError, TypeError):
            raise HTTPException(401, "Invalid session.") from None

    @app.get("/health")
    async def health():
        return {"status": "ok", "provider_verification": "live_pending"}

    @app.get("/v1/account/deletion-request")
    async def account_deletion_status(user_id=Depends(authenticated_user)):
        rows = await repo.owned("account_deletion_requests", user_id, select="requested_at")
        return {"requested": bool(rows)}

    @app.post("/v1/account/deletion-request", status_code=202)
    async def request_account_deletion(user_id=Depends(authenticated_user)):
        await repo.request_account_deletion(user_id)
        return {"requested": True}

    @app.post("/v1/analyses", status_code=202)
    async def create_analysis(
        image: UploadFile = File(),
        consent_version: str = Form(),
        idempotency_key: UUID = Header(),
        user_id=Depends(authenticated_user),
    ):
        try:
            content = await image.read(10_000_000)
        finally:
            await image.close()
        if len(content) >= 10_000_000:
            raise HTTPException(413, "Choose an image under 10 MB.")
        return await service.create(user_id, str(idempotency_key), content, consent_version)

    @app.get("/v1/jobs")
    async def jobs(user_id=Depends(authenticated_user)):
        return await service.jobs(user_id)

    @app.get("/v1/jobs/{job_id}")
    async def get_job(job_id: UUID, user_id=Depends(authenticated_user)):
        return await service.get(user_id, str(job_id))

    @app.get("/v1/analyses")
    async def history(offset: int = Query(default=0, ge=0), user_id=Depends(authenticated_user)):
        return await service.history(user_id, offset)

    app.include_router(skincare_router(repo, authenticated_user))
    app.include_router(vanity_router(repo, authenticated_user))
    app.include_router(look_router(repo, authenticated_user))
    app.include_router(gemini_router(repo, settings, http, authenticated_user))
    app.include_router(live_router(repo, settings, authenticated_user))
    app.include_router(vto_router(repo, settings, http, authenticated_user))
    app.include_router(discovery_router(repo, authenticated_user))
    app.include_router(preferences_router(repo, authenticated_user))
    app.include_router(memory_router(repo, authenticated_user))
    app.include_router(education_router(repo, settings, http, authenticated_user))
    app.include_router(weekly_router(repo, authenticated_user))
    return app
