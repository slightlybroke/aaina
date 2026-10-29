from urllib.parse import quote, urlsplit

import httpx

from app.domain import ContractError, ProviderError

# Fixed minimal HD scope. Change deliberately after checking account cost/entitlement.
ACTIONS = ["hd_wrinkle", "hd_pore", "hd_texture", "hd_acne"]
ENGINE_ERRORS = {
    "error_src_face_too_small",  # Verified in the live v2.1 acceptance response.
    "error_exceed_max_image_size",
    "exceed_max_filesize",
    "invalid_parameter",
    "error_download_image",
    "error_download_mask",
    "error_decode_image",
    "error_decode_mask",
    "error_nsfw_content_detected",
    "error_no_face",
    "error_pose",
    "error_face_parsing",
    "error_inference",
    "exceed_nsfw_retry_limits",
    "error_upload",
    "unknown_internal_error",
}


class YouCam:
    def __init__(self, settings, client: httpx.AsyncClient):
        self.s, self.client = settings, client

    def asset_url(self, url):
        if not isinstance(url, str):
            raise ContractError("invalid_asset_url")
        parsed = urlsplit(url)
        if (
            parsed.scheme != "https"
            or parsed.hostname not in self.s.youcam_asset_hosts
            or parsed.port not in (None, 443)
            or parsed.username
            or parsed.password
        ):
            raise ContractError("unapproved_asset_host")
        return url

    async def api(self, method, path, payload=None):
        response = await self.client.request(
            method,
            self.s.youcam_base_url + path,
            json=payload,
            headers={"Authorization": f"Bearer {self.s.youcam_api_key}"},
            timeout=25,
        )
        if response.status_code != 200:
            code = {
                401: "provider_auth_failed",
                429: "provider_rate_limited",
                400: "provider_invalid_request",
                500: "provider_unavailable",
            }.get(response.status_code, "provider_http_error")
            # Only safe GETs may be retried after ambiguous failures.
            raise ProviderError(
                code, method == "GET" and response.status_code in (429, 500, 502, 503, 504)
            )
        try:
            body = response.json()
            if body["status"] != 200 or not isinstance(body["data"], dict):
                raise ValueError()
            return body["data"]
        except (ValueError, KeyError, TypeError) as exc:
            raise ContractError("invalid_provider_envelope") from exc

    async def upload(self, content: bytes):
        data = await self.api(
            "POST",
            "/s2s/v2.0/file",
            {
                "files": [
                    {
                        "file_name": "source.jpg",
                        "content_type": "image/jpeg",
                        "file_size": len(content),
                    }
                ]
            },
        )
        try:
            file = data["files"][0]
            request = file["requests"][0]
            file_id = file["file_id"]
            if request["method"] != "PUT" or not isinstance(file_id, str) or not file_id:
                raise ValueError()
            url = self.asset_url(request["url"])
            headers = {k: str(v) for k, v in request["headers"].items()}
            if any(
                k.lower() not in {"content-type", "content-length", "x-amz-acl"} for k in headers
            ):
                raise ValueError()
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            raise ContractError("invalid_file_upload_contract") from exc
        # No provider bearer key is ever sent to the asset host. Redirects stay disabled.
        response = await self.client.put(url, content=content, headers=headers, timeout=25)
        if not response.is_success:
            raise ProviderError("provider_file_upload_failed")
        return file_id

    async def submit(self, file_id):
        data = await self.api(
            "POST",
            "/s2s/v2.1/task/skin-analysis",
            {"src_file_id": file_id, "dst_actions": ACTIONS, "format": "zip"},
        )
        task_id = data.get("task_id")
        if not isinstance(task_id, str) or not task_id:
            raise ContractError("missing_task_id")
        return task_id

    async def status(self, task_id):
        data = await self.api("GET", "/s2s/v2.1/task/skin-analysis/" + quote(task_id, safe=""))
        state = data.get("task_status")
        if state == "running":
            return state, None
        if state == "error":
            error = data.get("error")
            raise ProviderError(error if error in ENGINE_ERRORS else "provider_analysis_failed")
        if state != "success":
            raise ContractError("unknown_provider_status")
        results = data.get("results")
        url = results.get("url") if isinstance(results, dict) else results
        return state, self.asset_url(url)

    async def download(self, url):
        # Bound compressed size as well as the score member's uncompressed size.
        content = bytearray()
        async with self.client.stream("GET", self.asset_url(url), timeout=25) as response:
            if not response.is_success:
                raise ProviderError("result_download_failed", True)
            async for chunk in response.aiter_bytes():
                content.extend(chunk)
                if len(content) > 40_000_000:
                    raise ContractError("result_zip_too_large")
        return bytes(content)
