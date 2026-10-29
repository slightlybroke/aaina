"""Documented Makeup/Look VTO interfaces; independent of analysis scoring."""

import io
import warnings
from typing import Literal
from urllib.parse import quote

from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import Field, model_validator

from app.domain import ContractError, ProviderError
from app.provider import YouCam
from app.skincare import Input


class VtoOptions(Input):
    mode: Literal["lip_color", "look"] = "lip_color"
    color: str = Field(default="#B5445C", pattern=r"^#[0-9A-Fa-f]{6}$")
    intensity: int = Field(default=60, ge=1, le=100, strict=True)
    template_id: str = Field(default="", max_length=160, pattern=r"^[a-zA-Z0-9_-]*$")

    @model_validator(mode="after")
    def valid_mode(self):
        if (self.mode == "look") != bool(self.template_id):
            raise ValueError("Choose a listed template for Look mode only.")
        return self


def prepare_vto_image(content):
    if not content or len(content) >= 10_000_000:
        raise ValueError("Choose a JPEG/PNG under 10 MB.")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(content)) as image:
                if image.format not in {"JPEG", "PNG"} or image.width * image.height > 25_000_000:
                    raise ValueError("Choose a JPEG/PNG under 25 megapixels.")
                image = ImageOps.exif_transpose(image)
                image.thumbnail((1919, 1079))
                if min(image.size) < 100:
                    raise ValueError("VTO needs at least 100 pixels on each side after resizing.")
                result = io.BytesIO()
                image.convert("RGB").save(result, format="JPEG", quality=92)
                return result.getvalue()
    except (
        OSError,
        UnidentifiedImageError,
        Image.DecompressionBombWarning,
        Image.DecompressionBombError,
    ) as exc:
        raise ValueError("The VTO image could not be decoded safely.") from exc


class VtoProvider(YouCam):
    async def templates(self):
        data = await self.api("GET", "/s2s/v2.0/task/template/look-vto?page_size=20")
        rows = data.get("templates")
        if not isinstance(rows, list):
            raise ContractError("invalid_template_list")
        result = []
        for row in rows[:20]:
            try:
                choice = VtoOptions(mode="look", template_id=row["id"])
                title = row["title"]
                if not isinstance(title, str) or not title or len(title) > 200:
                    raise ValueError()
                result.append({"id": choice.template_id, "title": title})
            except (KeyError, TypeError, ValueError) as exc:
                raise ContractError("invalid_template") from exc
        return result

    async def submit_vto(self, file_id, options):
        if options.mode == "look":
            path = "look-vto"
            payload = {"src_file_id": file_id, "template_id": options.template_id}
        else:
            path = "makeup-vto"
            payload = {
                "src_file_id": file_id,
                "version": "1.0",
                "effects": [
                    {
                        "category": "skin_smooth",
                        "skinSmoothStrength": 0,
                        "skinSmoothColorIntensity": 0,
                    },
                    {
                        "category": "lip_color",
                        "shape": {"name": "original"},
                        "style": {"type": "full"},
                        "palettes": [
                            {
                                "color": options.color,
                                "texture": "matte",
                                "colorIntensity": options.intensity,
                            }
                        ],
                    },
                ],
            }
        data = await self.api("POST", "/s2s/v2.0/task/" + path, payload)
        task = data.get("task_id")
        if not isinstance(task, str) or not task or len(task) > 500:
            raise ContractError("missing_task_id")
        return task

    async def status_vto(self, task_id, mode):
        path = "look-vto" if mode == "look" else "makeup-vto"
        data = await self.api("GET", "/s2s/v2.0/task/" + path + "/" + quote(task_id, safe=""))
        state = data.get("task_status")
        if state in {"running", "queued", "processing"}:
            return "running", None
        if state == "error":
            safe = {
                "error_below_min_image_size",
                "error_exceed_max_image_size",
                "error_face_position_invalid",
                "error_face_position_too_small",
                "error_face_position_out_of_boundary",
                "error_face_angle_invalid",
            }
            code = data.get("error")
            raise ProviderError(
                code if isinstance(code, str) and code in safe else "vto_provider_failed"
            )
        if state != "success":
            raise ContractError("unknown_vto_status")
        results = data.get("results")
        if isinstance(results, dict):
            url = results.get("url")
        elif isinstance(results, list) and len(results) == 1 and isinstance(results[0], dict):
            url = results[0].get("download_url")
        else:
            raise ContractError("invalid_vto_result")
        return state, self.asset_url(url)

    async def preview(self, url):
        content = bytearray()
        async with self.client.stream("GET", self.asset_url(url), timeout=25) as response:
            if not response.is_success:
                raise ProviderError("preview_download_failed", True)
            async for chunk in response.aiter_bytes():
                content.extend(chunk)
                if len(content) >= 10_000_000:
                    raise ContractError("preview_too_large")
        try:
            return prepare_vto_image(bytes(content))
        except ValueError as exc:
            raise ContractError("invalid_preview_image") from exc
