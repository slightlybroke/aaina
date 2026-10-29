from datetime import timedelta
from pathlib import Path
from uuid import uuid4

import httpx
import pytest

from app.discovery import CatalogueProduct
from app.domain import utcnow
from app.main import create_app
from scripts.import_catalogue import read_products
from tests.test_api import settings as settings

SEED = Path(__file__).resolve().parents[2] / "catalogue" / "products.json"


def test_reviewed_seed_has_real_metadata_without_invented_commerce():
    rows = read_products(SEED)
    assert len(rows) == 6 and len({r["id"] for r in rows}) == 6
    assert {r["brand"] for r in rows} == {"e.l.f. Cosmetics", "Maybelline"}
    assert all("price" not in r and "sku" not in r and "vto" not in r for r in rows)


@pytest.mark.parametrize(
    "url",
    [
        "http://www.maybelline.com/",
        "https://attacker.test/",
        "https://secret@www.maybelline.com/",
        "https://www.maybelline.com:81/",
    ],
)
def test_import_rejects_unreviewed_links(url):
    row = read_products(SEED)[0]
    row["source_url"] = url
    with pytest.raises(ValueError):
        CatalogueProduct.model_validate(row)


def test_import_validation_duplicate_missing_and_future(tmp_path):
    import json

    rows = read_products(SEED)
    file = tmp_path / "data.json"
    file.write_text(json.dumps([rows[0], rows[0]]))
    with pytest.raises(ValueError):
        read_products(file)
    row = rows[0].copy()
    row.pop("name")
    with pytest.raises(ValueError):
        CatalogueProduct.model_validate(row)
    row = rows[0].copy()
    row["checked_on"] = (utcnow().date() + timedelta(days=3)).isoformat()
    with pytest.raises(ValueError):
        CatalogueProduct.model_validate(row)


class Repo:
    def __init__(self):
        self.calls = []

    async def rpc(self, name, payload):
        assert name == "search_discovery"
        self.calls.append(payload)
        return {
            "items": read_products(SEED)[:1],
            "has_more": True,
            "categories": ["lipstick"],
            "brands": ["e.l.f. Cosmetics"],
        }

    async def rows(self, table, **filters):
        assert table == "discovery_products" and filters["active"] == "eq.true"
        return []


async def test_auth_filters_paging_and_no_catalogue_mutations(settings):
    owner = str(uuid4())
    repo = Repo()

    def auth(req):
        return httpx.Response(200, json={"id": owner})

    async with httpx.AsyncClient(transport=httpx.MockTransport(auth)) as http:
        app = create_app(settings, repo, http)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as c:
            assert (await c.get("/v1/discovery")).status_code == 401
            c.headers["Authorization"] = "Bearer test"
            result = await c.get(
                "/v1/discovery",
                params={
                    "q": "%_' OR 1=1",
                    "category": "Lipstick",
                    "brand": "e.l.f. Cosmetics",
                    "offset": 20,
                },
            )
            assert result.status_code == 200 and result.json()["exact_vto_available"] is False
            assert repo.calls[-1] == {
                "p_query": "%_' OR 1=1",
                "p_category": "lipstick",
                "p_brand": "e.l.f. Cosmetics",
                "p_offset": 20,
            }
            assert (await c.get("/v1/discovery", params={"offset": -1})).status_code == 422
            assert (await c.get("/v1/discovery", params={"q": "x" * 201})).status_code == 422
            assert (await c.get("/v1/discovery/" + str(uuid4()))).status_code == 404
            assert (await c.post("/v1/discovery", json={"name": "injected"})).status_code == 405
