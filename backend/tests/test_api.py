import io
from uuid import uuid4

import httpx
import pytest
from PIL import Image

from app.config import Settings
from app.main import create_app
from app.repository import Supabase
from tests.fakes import MemoryRepository

A, B = str(uuid4()), str(uuid4())


@pytest.fixture
def settings():
    return Settings(
        _env_file=None,
        supabase_url="https://project.supabase.co",
        supabase_publishable_key="public",
        supabase_service_role_key="server-secret",
        youcam_api_key="provider-secret",
    )


@pytest.fixture
def photo():
    buffer = io.BytesIO()
    Image.new("RGB", (1200, 1400), "gray").save(buffer, format="JPEG")
    return buffer.getvalue()


@pytest.fixture
async def api(settings):
    repo = MemoryRepository()

    def auth(request):
        token = request.headers.get("authorization", "")
        if token not in ("Bearer alice", "Bearer bob"):
            return httpx.Response(401)
        return httpx.Response(200, json={"id": A if token.endswith("alice") else B})

    async with httpx.AsyncClient(transport=httpx.MockTransport(auth)) as upstream:
        app = create_app(settings, repo, upstream)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app), base_url="http://test"
        ) as client:
            yield client, repo


async def submit(client, photo, key, token="alice", consent="skin-analysis-v1"):
    return await client.post(
        "/v1/analyses",
        headers={"Authorization": f"Bearer {token}", "Idempotency-Key": key},
        data={"consent_version": consent},
        files={"image": ("photo.jpg", photo)},
    )


async def test_retry_returns_same_job_without_reupload(api, photo):
    client, repo = api
    key = str(uuid4())
    first, retry = await submit(client, photo, key), await submit(client, photo, key)
    assert first.status_code == retry.status_code == 202
    assert first.json()["id"] == retry.json()["id"]
    assert repo.uploads == len(repo.jobs) == 1
    assert "image_path" not in first.json()
    assert "external_task_id" not in first.json()


async def test_retry_different_content_conflicts(api, photo):
    client, repo = api
    key = str(uuid4())
    await submit(client, photo, key)
    response = await submit(client, photo + b"different", key)
    assert response.status_code == 409
    assert repo.uploads == 1


async def test_cross_user_cannot_get_job_or_history(api, photo):
    client, repo = api
    response = await submit(client, photo, str(uuid4()))
    job = response.json()["id"]
    repo.analyses.append({"job_id": job, "user_id": A, "overall_score": 75})
    assert (
        await client.get(f"/v1/jobs/{job}", headers={"Authorization": "Bearer bob"})
    ).status_code == 404
    assert (await client.get("/v1/analyses", headers={"Authorization": "Bearer bob"})).json() == []
    assert (await client.get("/v1/jobs", headers={"Authorization": "Bearer bob"})).json() == []
    # Reusing another user's key creates a distinct job owned by the verified caller.
    key = next(iter(repo.jobs.values()))["idempotency_key"]
    bob = await submit(client, photo, key, "bob")
    assert repo.jobs[bob.json()["id"]]["user_id"] == B


@pytest.mark.parametrize("token", [None, "forged"])
async def test_requires_valid_auth(api, token):
    client, repo = api
    headers = {} if token is None else {"Authorization": f"Bearer {token}"}
    assert (await client.get("/v1/analyses", headers=headers)).status_code == 401
    assert not repo.jobs


async def test_consent_and_input_validation(api, photo):
    client, repo = api
    assert (await submit(client, photo, str(uuid4()), consent="no")).status_code == 422
    assert (await submit(client, b"bad image", str(uuid4()))).status_code == 422
    assert not repo.jobs


async def test_repository_filters_owner_even_with_service_key(settings):
    def inspect(request):
        assert request.url.params["user_id"] == f"eq.{A}"
        assert request.url.params["id"] == "eq.some-job"
        assert request.headers["authorization"] == "Bearer server-secret"
        return httpx.Response(200, json=[])

    async with httpx.AsyncClient(transport=httpx.MockTransport(inspect)) as client:
        assert await Supabase(settings, client).owned("analysis_jobs", A, id="eq.some-job") == []


async def test_concurrent_retries_create_one_job(api, photo):
    import asyncio

    client, repo = api
    key = str(uuid4())
    responses = await asyncio.gather(*(submit(client, photo, key) for _ in range(5)))
    assert all(r.status_code == 202 for r in responses)
    assert len({r.json()["id"] for r in responses}) == 1
    assert len(repo.jobs) == repo.uploads == 1


async def test_oversized_request_rejected_before_storage(api):
    client, repo = api
    response = await client.post(
        "/v1/analyses", content=b"x", headers={"Content-Length": "20000000"}
    )
    assert response.status_code == 413 and not repo.jobs


async def test_client_supplied_user_id_does_not_change_owner(api, photo):
    client, repo = api
    response = await client.post(
        "/v1/analyses",
        headers={"Authorization": "Bearer alice", "Idempotency-Key": str(uuid4())},
        data={"consent_version": "skin-analysis-v1", "user_id": B},
        files={"image": ("image.jpg", photo)},
    )
    assert response.status_code == 202
    assert repo.jobs[response.json()["id"]]["user_id"] == A


async def test_mocked_api_worker_journey_persists_and_retrieves(api, photo, settings):
    from datetime import timedelta

    from app.domain import utcnow
    from app.worker import Worker
    from tests.test_provider_worker import ProviderFake

    client, repo = api
    created = await submit(client, photo, str(uuid4()))
    row = repo.jobs[created.json()["id"]].copy()
    row.update(lease_token=str(uuid4()), lease_until=(utcnow() + timedelta(minutes=3)).isoformat())
    repo.jobs[row["id"]].update(row)
    worker = Worker(repo, ProviderFake(), settings)
    await worker.process(row)
    row.update(lease_token=str(uuid4()), lease_until=(utcnow() + timedelta(minutes=3)).isoformat())
    repo.jobs[row["id"]].update(row)
    await worker.process(row)
    response = await client.get("/v1/jobs/" + row["id"], headers={"Authorization": "Bearer alice"})
    assert response.json()["status"] == "completed"
    assert response.json()["analysis"]["overall_score"] == 70.5
    history = await client.get("/v1/analyses", headers={"Authorization": "Bearer alice"})
    assert history.json()[0]["job_id"] == row["id"]
