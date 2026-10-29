import io
import json
import zipfile

import pytest

from app.domain import ContractError, transition
from app.parser import normalize, parse_zip


def example():
    # Mock derived from the official score_info.json documentation, NOT a live result.
    return {
        "all": {"score": 75.75},
        "hd_acne": {"whole": {"raw_score": 59.92, "ui_score": 76}},
        "skin_age": 37,
    }


def test_preserve_provider_scores_without_derivation():
    result = normalize(example(), ["hd_acne"])
    assert result["overall_score"] == 75.75
    assert result["metrics"] == [
        {"concern": "hd_acne", "region": "whole", "raw_score": 59.92, "ui_score": 76}
    ]
    assert "skin_age" not in result


@pytest.mark.parametrize("value", [None, True, "75", 0, 101, float("nan"), float("inf")])
def test_reject_malformed_overall(value):
    document = example()
    document["all"]["score"] = value
    with pytest.raises(ContractError):
        normalize(document, ["hd_acne"])


def test_missing_overall_does_not_average_concerns():
    document = example()
    del document["all"]
    with pytest.raises(ContractError, match="missing_overall_score"):
        normalize(document, ["hd_acne"])


def test_missing_optional_score_is_explicit():
    document = example()
    del document["hd_acne"]["whole"]["raw_score"]
    result = normalize(document, ["hd_acne", "hd_texture"])
    assert result["metrics"][0]["raw_score"] is None
    assert "missing_raw_score:hd_acne:whole" in result["warnings"]
    assert "missing_concern:hd_texture" in result["warnings"]


@pytest.mark.parametrize("value", [True, "76", 76.5, 0, 101, None])
def test_malformed_ui_score(value):
    document = example()
    document["hd_acne"]["whole"]["ui_score"] = value
    with pytest.raises(ContractError):
        normalize(document, ["hd_acne"])


def test_zip_reader_and_no_extraction(tmp_path):
    content = io.BytesIO()
    with zipfile.ZipFile(content, "w") as archive:
        archive.writestr("skinanalysisResult/score_info.json", json.dumps(example()))
        archive.writestr("../../untrusted.txt", "ignored")
    assert parse_zip(content.getvalue(), ["hd_acne"])["overall_score"] == 75.75
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize("payload", [b"not zip", b""])
def test_bad_zip(payload):
    with pytest.raises(ContractError):
        parse_zip(payload, ["hd_acne"])


def test_completed_cannot_restart_or_skip_submission():
    transition("processing", "completed")
    with pytest.raises(ValueError):
        transition("completed", "pending")
    with pytest.raises(ValueError):
        transition("pending", "completed")
