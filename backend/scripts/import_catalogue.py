"""Explicit, validated import of reviewed public metadata into the dev catalogue."""

import argparse
import asyncio
import json
from pathlib import Path

import httpx

from app.config import Settings
from app.discovery import CatalogueProduct
from app.repository import Supabase


def read_products(path):
    rows = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(rows, list) or not 1 <= len(rows) <= 1000:
        raise ValueError("Expected 1–1000 records.")
    products = [CatalogueProduct.model_validate(row) for row in rows]
    if len({p.id for p in products}) != len(products):
        raise ValueError("Duplicate catalogue IDs.")
    return [p.model_dump(mode="json") for p in products]


async def run(path, apply):
    rows = read_products(path)
    print("VALID: reviewed product/shade rows=" + str(len(rows)))
    if not apply:
        print("Dry run only; use --apply after migration and source review.")
        return
    s = Settings()
    if s.supabase_url != "https://zouvroynucstxqimygzd.supabase.co":
        raise RuntimeError("Unexpected project; no import performed.")
    async with httpx.AsyncClient(follow_redirects=False) as h:
        await Supabase(s, h).request(
            "POST",
            "/rest/v1/discovery_products",
            params={"on_conflict": "id"},
            json=rows,
            headers={"Prefer": "resolution=merge-duplicates"},
        )
    print("CATALOGUE_IMPORT_PASS: reviewed public rows upserted; private Vanity untouched.")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--file", default="../catalogue/products.json")
    p.add_argument("--apply", action="store_true")
    args = p.parse_args()
    try:
        asyncio.run(run(args.file, args.apply))
    except Exception as exc:
        print("CATALOGUE_IMPORT_BLOCKED:", type(exc).__name__)
        raise SystemExit(1) from None
