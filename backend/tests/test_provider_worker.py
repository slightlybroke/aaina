import io
import json
import zipfile
from datetime import timedelta
from types import SimpleNamespace
from uuid import uuid4

import httpx
import pytest

from app.domain import ContractError, ProviderError, utcnow
from app.provider import YouCam
from app.worker import Worker
from tests.fakes import MemoryRepository


def config():
    return SimpleNamespace(
        youcam_base_url="https://provider.test",
        youcam_api_key="secret",
        youcam_asset_hosts=["assets.test"],
        poll_seconds=10,
    )


def zip_result():
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr(
            "skinanalysisResult/score_info.json",
            json.dumps(
                {"all": {"score": 70.5}, "hd_acne": {"whole": {"raw_score": 50.5, "ui_score": 65}}}
            ),
        )
    return output.getvalue()


@pytest.mark.parametrize("wrapped", [True, False])
async def test_file_upload_submit_poll_and_zip_download(wrapped):
    calls = []

    def transport(request):
        calls.append((request.method, request.url.path))
        if request.url.host == "assets.test":
            assert "authorization" not in request.headers
            if request.method == "PUT":
                assert request.content == b"image"
                return httpx.Response(200)
            return httpx.Response(200, content=zip_result())
        assert request.headers["authorization"] == "Bearer secret"
        if request.url.path == "/s2s/v2.0/file":
            assert json.loads(request.content)["files"][0]["file_size"] == 5
            data = {
                "files": [
                    {
                        "file_id": "file-id",
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
        elif request.method == "POST":
            body = json.loads(request.content)
            assert body["src_file_id"] == "file-id" and "src_file_url" not in body
            assert body["format"] == "zip"
            data = {"task_id": "task-id"}
        else:
            data = {
                "task_status": "success",
                "results": {"url": "https://assets.test/result"}
                if wrapped
                else "https://assets.test/result",
            }
        return httpx.Response(200, json={"status": 200, "data": data})

    async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as client:
        provider = YouCam(config(), client)
        file_id = await provider.upload(b"image")
        task = await provider.submit(file_id)
        state, url = await provider.status(task)
        assert state == "success" and await provider.download(url) == zip_result()
    assert calls[:3] == [
        ("POST", "/s2s/v2.0/file"),
        ("PUT", "/input"),
        ("POST", "/s2s/v2.1/task/skin-analysis"),
    ]


@pytest.mark.parametrize(
    "url",
    [
        "http://assets.test/a",
        "https://localhost/a",
        "https://assets.test.evil/a",
        "https://assets.test@evil.test/a",
        "https://assets.test:8443/a",
    ],
)
def test_unapproved_asset_url_rejected(url):
    with pytest.raises(ContractError):
        YouCam(config(), None).asset_url(url)


@pytest.mark.parametrize("status,retryable", [(400, False), (401, False), (429, True), (500, True)])
async def test_provider_http_errors(status, retryable):
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(lambda r: httpx.Response(status))
    ) as client:
        with pytest.raises(ProviderError) as error:
            await YouCam(config(), client).status("task")
        assert error.value.retryable == retryable


def job(state="pending"):
    return {
        "id": str(uuid4()),
        "user_id": str(uuid4()),
        "status": state,
        "image_path": "private/image",
        "lease_token": str(uuid4()),
        "expires_at": (utcnow() + timedelta(minutes=20)).isoformat(),
        "lease_until": (utcnow() + timedelta(minutes=3)).isoformat(),
        "external_task_id": "task",
        "cleanup_status": "pending",
        "cleanup_attempts": 0,
    }


class ProviderFake:
    submits = 0
    timeout = False

    async def upload(self, content):
        return "file"

    async def submit(self, file):
        self.submits += 1
        if self.timeout:
            raise httpx.ReadTimeout("mock")
        return "task"

    async def status(self, task):
        return "success", "https://assets.test/result"

    async def download(self, url):
        return zip_result()


async def test_worker_success_and_atomic_completion():
    repo, provider = MemoryRepository(), ProviderFake()
    row = job()
    repo.jobs[row["id"]] = row.copy()
    repo.objects[row["image_path"]] = b"image"
    worker = Worker(repo, provider, config())
    await worker.process(row)
    assert row["status"] == "processing" and provider.submits == 1
    # Simulate the next database lease, as a separate tick would claim it.
    row["lease_token"] = repo.jobs[row["id"]]["lease_token"] = str(uuid4())
    row["lease_until"] = repo.jobs[row["id"]]["lease_until"] = (
        utcnow() + timedelta(minutes=3)
    ).isoformat()
    await worker.process(row)
    assert repo.jobs[row["id"]]["status"] == "completed"
    assert repo.analyses[0]["overall_score"] == 70.5
    assert provider.submits == 1


async def test_ambiguous_submit_is_not_repeated_after_restart():
    repo, provider = MemoryRepository(), ProviderFake()
    provider.timeout = True
    row = job()
    repo.jobs[row["id"]] = row.copy()
    repo.objects[row["image_path"]] = b"image"
    worker = Worker(repo, provider, config())
    await worker.process(row)
    assert row["status"] == "failed" and row["error_code"] == "submission_unknown"
    assert provider.submits == 1
    recovered = job("submitting")
    repo.jobs[recovered["id"]] = recovered.copy()
    await worker.process(recovered)
    assert recovered["error_code"] == "submission_unknown"
    assert provider.submits == 1


async def test_poll_network_retry_and_expiry():
    repo, provider = MemoryRepository(), ProviderFake()

    async def fail(task):
        raise httpx.ConnectError("mock")

    provider.status = fail
    row = job("processing")
    repo.jobs[row["id"]] = row.copy()
    worker = Worker(repo, provider, config())
    await worker.process(row)
    assert row["status"] == "processing" and row["attempts"] == 1
    expired = job("processing")
    expired["expires_at"] = (utcnow() - timedelta(seconds=1)).isoformat()
    repo.jobs[expired["id"]] = expired.copy()
    await worker.process(expired)
    assert expired["status"] == "expired" and provider.submits == 0


async def test_cleanup_failure_persists_and_retries():
    repo = MemoryRepository()
    row = job("failed")
    repo.jobs[row["id"]] = row
    repo.objects[row["image_path"]] = b"image"
    repo.delete_fails = True
    worker = Worker(repo, ProviderFake(), config())
    await worker.cleanup()
    assert row["cleanup_status"] == "failed" and row["cleanup_attempts"] == 1
    assert row["cleanup_error"] == "storage_delete_failed"
    repo.delete_fails = False
    await worker.cleanup()
    assert row["cleanup_status"] == "deleted" and row["cleanup_attempts"] == 2
    assert not repo.objects
