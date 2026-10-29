"""Authenticated search of reviewed product facts; no shopping/VTO claims."""

from datetime import date
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import Field, field_validator

from app.skincare import Input

TRUSTED_SOURCES = {"www.elfcosmetics.com.au", "www.maybelline.com"}


class CatalogueProduct(Input):
    id: UUID
    name: str = Field(min_length=1, max_length=150)
    brand: str = Field(min_length=1, max_length=150)
    category: str = Field(min_length=1, max_length=80)
    shade_name: str = Field(default="", max_length=120)
    finish: str = Field(default="", max_length=80)
    source_url: str = Field(max_length=1000)
    source_region: str = Field(min_length=1, max_length=80)
    checked_on: date
    active: bool = True

    @field_validator("source_url")
    @classmethod
    def source_valid(cls, value):
        from urllib.parse import urlsplit

        parsed = urlsplit(value)
        if (
            parsed.scheme != "https"
            or parsed.hostname not in TRUSTED_SOURCES
            or parsed.username
            or parsed.password
            or parsed.port not in (None, 443)
        ):
            raise ValueError("A reviewed official source URL is required.")
        return value

    @field_validator("checked_on")
    @classmethod
    def not_future(cls, value):
        from datetime import timedelta

        from app.domain import utcnow

        # Review dates are local calendar dates (sources/maintainer can be ahead of UTC).
        if value > utcnow().date() + timedelta(days=1):
            raise ValueError("Source check cannot be in the future.")
        return value


def router(repo, authenticate):
    routes = APIRouter(prefix="/v1/discovery", tags=["Product discovery"])

    @routes.get("")
    async def search(
        q: str = Query(default="", max_length=200),
        category: str = Query(default="", max_length=80),
        brand: str = Query(default="", max_length=150),
        offset: int = Query(default=0, ge=0, le=1000000),
        user=Depends(authenticate),
    ):
        result = await repo.rpc(
            "search_discovery",
            {
                "p_query": q.strip(),
                "p_category": category.strip().lower(),
                "p_brand": brand.strip(),
                "p_offset": offset,
            },
        )
        # No inferred colors, prices, stock, URLs or VTO parameters generated here.
        result["exact_vto_available"] = False
        return result

    @routes.get("/{product_id}")
    async def detail(product_id: UUID, user=Depends(authenticate)):
        rows = await repo.rows(
            "discovery_products",
            id=f"eq.{product_id}",
            active="eq.true",
            select="id,name,brand,category,shade_name,finish,source_url,source_region,checked_on",
        )
        if not rows:
            raise HTTPException(404, "Catalogue product not found.")
        return {**rows[0], "exact_vto_available": False}

    return routes
