import io
import json
from copy import deepcopy
from datetime import timedelta
from types import SimpleNamespace
from uuid import uuid4

import httpx
import pytest
from fastapi import HTTPException
from PIL import Image

from app.domain import ContractError, ProviderError, utcnow
from app.main import create_app
from app.vto import CONSENT, VtoService
from app.vto_provider import VtoOptions, VtoProvider, prepare_vto_image
from app.vto_worker import VtoWorker
from tests.test_api import settings as settings

A, B = str(uuid4()), str(uuid4())


def photo(size=(800, 1000)):
    out = io.BytesIO()
    Image.new("RGB", size, "green").save(out, format="JPEG")
    return out.getvalue()


class Repo:
    def __init__(self):
        self.jobs = {}
        self.objects = {}
        self.deletes_fail = False
        self.calls = []

    async def owned(self, user, **filters):
        return [
            deepcopy(j)
            for j in self.jobs.values()
            if j["user_id"] == user
            and all(str(j.get(k)) == v[3:] for k, v in filters.items() if v.startswith("eq."))
        ]

    async def insert(self, job):
        if await self.owned(job["user_id"], idempotency_key="eq." + job["idempotency_key"]):
            return []
        j = {
            **job,
            "source_cleanup": "pending",
            "result_cleanup": "pending",
            "cleanup_attempts": 0,
            "cleanup_verified": False,
            "attempts": 0,
            "created_at": utcnow().isoformat(),
        }
        self.jobs[j["id"]] = j
        return [deepcopy(j)]

    async def patch(self, job_id, values, **filters):
        j = self.jobs[job_id]
        for k, v in filters.items():
            if v.startswith("eq.") and str(j.get(k)) != v[3:]:
                return []
            if v.startswith("gt.") and (not j.get(k) or j[k] <= v[3:]):
                return []
        j.update(values)
        return [deepcopy(j)]

    async def upload(self, path, content):
        self.objects[path] = content

    async def download(self, path):
        return self.objects[path]

    async def delete(self, path):
        if self.deletes_fail:
            raise httpx.ConnectError("mock")
        self.objects.pop(path, None)

    async def rows(self, **filters):
        return deepcopy(list(self.jobs.values()))

    async def rpc(self, name, payload=None):
        self.calls.append(name)
        if name == "complete_vto_job":
            j = self.jobs[payload["p_job"]]
            if j["lease_token"] != payload["p_token"] or j["status"] != "processing":
                return False
            j["status"] = "completed"
            j["lease_token"] = None
            j["lease_until"] = None
            return True
        raise AssertionError(name)


class Provider:
    submissions = 0
    state = "success"

    async def templates(self):
        return [{"id": "real-template", "title": "Listed title"}]

    async def upload(self, content):
        return "file-id"

    async def submit_vto(self, file_id, options):
        self.submissions += 1
        return "task-id"

    async def status_vto(self, task, mode):
        return self.state, "https://assets.test/result"

    async def preview(self, url):
        return photo()


@pytest.mark.parametrize("size", [(60, 200), (200, 60)])
def test_vto_rejects_too_small(size):
    with pytest.raises(ValueError):
        prepare_vto_image(photo(size))


def test_vto_dimensions_are_independent_of_hd():
    image = Image.open(io.BytesIO(prepare_vto_image(photo((2200, 3000)))))
    assert 100 <= image.width < 1920 and 100 <= image.height < 1080
    with pytest.raises(ValueError):
        prepare_vto_image(b"not-an-image")


@pytest.mark.parametrize(
    "options",
    [{"intensity": True}, {"color": "red"}, {"mode": "look"}, {"template_id": "x"}, {"user_id": A}],
)
def test_vto_options_reject_invalid(options):
    with pytest.raises(ValueError):
        VtoOptions(**options)


async def test_consent_idempotency_changed_effect_and_cross_owner():
    repo = Repo()
    service = VtoService(repo, Provider())
    key = str(uuid4())
    content = photo()
    with pytest.raises(HTTPException) as err:
        await service.create(A, key, content, "", VtoOptions())
    assert err.value.status_code == 422 and not repo.jobs
    first = await service.create(A, key, content, CONSENT, VtoOptions())
    replay = await service.create(A, key, content, CONSENT, VtoOptions())
    assert first["id"] == replay["id"] and len(repo.jobs) == 1
    with pytest.raises(HTTPException) as err:
        await service.create(A, key, content, CONSENT, VtoOptions(color="#FFFFFF"))
    assert err.value.status_code == 409
    with pytest.raises(HTTPException) as err:
        await service.get(B, first["id"])
    assert err.value.status_code == 404
    other = await service.create(B, key, content, CONSENT, VtoOptions())
    assert other["id"] != first["id"]
    assert "source_path" not in first and "external_task_id" not in first


async def test_template_must_be_currently_listed():
    repo = Repo()
    service = VtoService(repo, Provider())
    with pytest.raises(HTTPException):
        await service.create(
            A, str(uuid4()), photo(), CONSENT, VtoOptions(mode="look", template_id="invented")
        )
    assert not repo.jobs


async def job_fixture():
    repo = Repo()
    p = Provider()
    service = VtoService(repo, p)
    public = await service.create(A, str(uuid4()), photo(), CONSENT, VtoOptions())
    j = repo.jobs[public["id"]]
    j.update(lease_token="lease", lease_until=(utcnow() + timedelta(minutes=3)).isoformat())
    return repo, p, service, j, VtoWorker(repo, p, SimpleNamespace(poll_seconds=10))


async def test_worker_lifecycle_private_preview_and_cleanup():
    repo, p, service, j, w = await job_fixture()
    await w.process(deepcopy(j))
    assert j["status"] == "processing" and p.submissions == 1
    j.update(lease_token="second", lease_until=(utcnow() + timedelta(minutes=3)).isoformat())
    await w.process(deepcopy(j))
    assert j["status"] == "completed" and await service.preview(A, j["id"])
    with pytest.raises(HTTPException):
        await service.preview(B, j["id"])
    await w.cleanup()
    assert j["source_cleanup"] == "deleted" and j["result_path"] in repo.objects
    j["expires_at"] = (utcnow() - timedelta(minutes=11)).isoformat()
    with pytest.raises(HTTPException) as err:
        await service.preview(A, j["id"])
    assert err.value.status_code == 410
    # Final sweep catches a late object even if a prior sweep had marked it deleted.
    repo.objects[j["source_path"]] = b"late-upload"
    await w.cleanup()
    assert not repo.objects and j["cleanup_verified"] is True


async def test_ambiguous_submission_is_never_repeated():
    repo, p, service, j, w = await job_fixture()
    j["status"] = "submitting"
    await w.process(deepcopy(j))
    assert (
        j["status"] == "failed" and j["error_code"] == "submission_unknown" and p.submissions == 0
    )


@pytest.mark.parametrize("same", [True, False])
async def test_safe_poll_recovers_only_identical_existing_preview(same):
    repo, p, service, j, w = await job_fixture()
    j.update(status="processing", external_task_id="task")
    repo.objects[j["result_path"]] = photo() if same else b"conflicting bytes"

    async def duplicate(path, content):
        request = httpx.Request("POST", "https://storage.test/object")
        response = httpx.Response(400, request=request)
        raise httpx.HTTPStatusError("duplicate", request=request, response=response)

    repo.upload = duplicate
    await w.process(deepcopy(j))
    assert p.submissions == 0
    assert j["status"] == ("completed" if same else "failed")
    if not same:
        assert j["error_code"] == "preview_conflict"


async def test_poll_retry_and_cleanup_failure_are_durable():
    repo, p, service, j, w = await job_fixture()
    j.update(status="processing", external_task_id="task")

    async def bad(*args):
        raise ProviderError("provider_rate_limited", True)

    p.status_vto = bad
    await w.process(deepcopy(j))
    assert j["status"] == "processing" and j["attempts"] == 1 and j["lease_token"] is None
    j["status"] = "failed"
    repo.deletes_fail = True
    await w.cleanup()
    assert j["source_cleanup"] == "failed" and j["cleanup_error"] == "storage_delete_failed"
    assert j["cleanup_verified"] is False


@pytest.mark.parametrize("shape", ["object", "array"])
async def test_provider_file_sequence_effect_and_result(settings, shape):
    settings.youcam_asset_hosts = ["assets.test"]

    def transport(req):
        if req.url.host == "assets.test":
            assert "authorization" not in req.headers
            return httpx.Response(200, content=photo())
        if req.url.path.endswith("/file"):
            data = {
                "files": [
                    {
                        "file_id": "file",
                        "requests": [
                            {
                                "method": "PUT",
                                "url": "https://assets.test/input",
                                "headers": {"Content-Type": "image/jpeg"},
                            }
                        ],
                    }
                ]
            }
        elif req.method == "POST":
            body = json.loads(req.content)
            assert body["src_file_id"] == "file" and "src_file_url" not in body
            assert body["effects"][0]["skinSmoothStrength"] == 0
            assert body["effects"][1]["category"] == "lip_color"
            data = {"task_id": "task"}
        else:
            data = {
                "task_status": "success",
                "results": {"url": "https://assets.test/result"}
                if shape == "object"
                else [{"download_url": "https://assets.test/result"}],
            }
        return httpx.Response(200, json={"status": 200, "data": data})

    async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as h:
        p = VtoProvider(settings, h)
        assert await p.upload(b"image") == "file"
        assert await p.submit_vto("file", VtoOptions()) == "task"
        state, url = await p.status_vto("task", "lip_color")
        assert state == "success" and await p.preview(url)
        with pytest.raises(ContractError):
            p.asset_url("http://127.0.0.1/secret")


@pytest.mark.parametrize("state", ["error", "mystery"])
async def test_provider_errors_redacted(settings, state):
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda r: httpx.Response(
                200,
                json={
                    "status": 200,
                    "data": {"task_status": state, "error": "secret-provider-detail"},
                },
            )
        )
    ) as h:
        p = VtoProvider(settings, h)
        with pytest.raises((ProviderError, ContractError)) as err:
            await p.status_vto("task", "lip_color")
        assert "secret-provider-detail" not in str(err.value)


async def test_vto_auth_and_disabled_gate(settings):
    def transport(req):
        return httpx.Response(401)

    async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as http:
        app = create_app(settings, client=http)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as c:
            assert (await c.get("/v1/vto/jobs")).status_code == 401

    def authenticated(req):
        return httpx.Response(200, json={"id": A})

    async with httpx.AsyncClient(transport=httpx.MockTransport(authenticated)) as http:
        app = create_app(settings, client=http)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
            headers={"Authorization": "Bearer test"},
        ) as c:
            assert (await c.get("/v1/vto/jobs")).status_code == 503
