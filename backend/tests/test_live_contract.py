from types import SimpleNamespace

import httpx
import pytest

from app.domain import ProviderError
from app.provider import YouCam


async def test_verified_face_too_small_error_is_preserved():
    """Mock of the verified live error, without photo, task ID, or signed URL."""
    settings = SimpleNamespace(youcam_base_url="https://provider.test", youcam_api_key="test")
    response = {
        "status": 200,
        "data": {"task_status": "error", "error": "error_src_face_too_small"},
    }
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(lambda request: httpx.Response(200, json=response))
    ) as client:
        with pytest.raises(ProviderError) as caught:
            await YouCam(settings, client).status("test-task")
        assert caught.value.code == "error_src_face_too_small"
        assert caught.value.retryable is False
