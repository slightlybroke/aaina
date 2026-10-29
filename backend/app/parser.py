"""Documentation-backed ZIP adapter. Live v2.1 verification remains pending."""

import io
import json
import math
import zipfile

from app.domain import ContractError

SINGLE = {
    "redness",
    "oiliness",
    "age_spot",
    "radiance",
    "moisture",
    "dark_circle",
    "dark_circle_v2",
    "eye_bag",
    "droopy_upper_eyelid",
    "droopy_lower_eyelid",
    "firmness",
    "tear_trough",
    "texture",
    "acne",
    "pore",
    "wrinkle",
}
REGIONS = {
    "whole",
    "forehead",
    "nose",
    "cheek",
    "glabellar",
    "crowfeet",
    "periocular",
    "nasolabial",
    "marionette",
}


def score(value, field):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ContractError(f"invalid_{field}")
    if not math.isfinite(value) or not 1 <= value <= 100:
        raise ContractError(f"invalid_{field}")
    if field == "ui_score" and not isinstance(value, int):
        raise ContractError("invalid_ui_score")
    return value


def normalize(document: dict, requested: list[str]):
    if not isinstance(document, dict):
        raise ContractError("invalid_score_document")
    overall = document.get("all")
    if not isinstance(overall, dict) or "score" not in overall:
        raise ContractError("missing_overall_score")
    overall_score = score(overall["score"], "overall_score")
    metrics, warnings = [], []
    for concern in requested:
        if concern.removeprefix("hd_") not in SINGLE:
            raise ContractError("unsupported_concern")
        node = document.get(concern)
        if node is None:
            warnings.append(f"missing_concern:{concern}")
            continue
        if not isinstance(node, dict):
            raise ContractError("invalid_concern")
        nodes = [(None, node)] if {"raw_score", "ui_score"} & node.keys() else list(node.items())
        if not nodes:
            warnings.append(f"missing_scores:{concern}")
        for region, values in nodes:
            if region is not None and region not in REGIONS:
                warnings.append(f"unsupported_region:{concern}:{region}")
                continue
            if not isinstance(values, dict):
                raise ContractError("invalid_region")
            metric = {"concern": concern, "region": region}
            for field in ("raw_score", "ui_score"):
                metric[field] = score(values[field], field) if field in values else None
                if field not in values:
                    warnings.append(f"missing_{field}:{concern}:{region or 'whole'}")
            if metric["raw_score"] is not None or metric["ui_score"] is not None:
                metrics.append(metric)
    if not metrics:
        raise ContractError("missing_concern_scores")
    # No masks, image URLs, unknown fields, or unverified skin-age value are persisted.
    return {"overall_score": overall_score, "metrics": metrics, "warnings": warnings}


def parse_zip(content: bytes, requested: list[str]):
    try:
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            entries = [
                i for i in archive.infolist() if i.filename == "skinanalysisResult/score_info.json"
            ]
            if len(entries) != 1 or entries[0].file_size > 1_000_000:
                raise ContractError("missing_or_oversized_score_file")
            # Read only this member in memory; never extract provider paths to disk.
            document = json.loads(archive.read(entries[0]))
        return normalize(document, requested)
    except (zipfile.BadZipFile, UnicodeError, json.JSONDecodeError, RuntimeError) as exc:
        raise ContractError("invalid_result_zip") from exc
