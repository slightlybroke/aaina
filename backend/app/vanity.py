"""Owned makeup inventory only. No provider, discovery or recommendation calls."""

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import Field, field_validator

from app.skincare import Input


class VanityItem(Input):
    name: str = Field(min_length=1, max_length=150)
    brand: str = Field(default="", max_length=150)
    category: str = Field(default="other", min_length=1, max_length=80)
    shade_name: str = Field(default="", max_length=120)
    shade_identifier: str = Field(default="", max_length=80)
    finish: str = Field(default="", max_length=80)
    undertone: str = Field(default="", max_length=80)
    notes: str = Field(default="", max_length=3000)
    expected_version: int | None = Field(default=None, ge=1)

    @field_validator("category")
    @classmethod
    def normalize_category(cls, value):
        value = value.lower()
        if len(value) > 80:
            raise ValueError("Category must be at most 80 characters.")
        return value


class VanityService:
    def __init__(self, repo):
        self.repo = repo

    async def get(self, user, item_id):
        rows = await self.repo.owned("vanity_items", user, id=f"eq.{item_id}")
        if not rows:
            raise HTTPException(404, "Product not found.")
        return rows[0]

    async def save(self, user, item_id, body):
        result = await self.repo.rpc(
            "save_vanity_item",
            {
                "p_user": user,
                "p_id": item_id,
                "p_data": body.model_dump(exclude={"expected_version"}),
                "p_expected_version": body.expected_version,
            },
        )
        if "error" in result:
            raise HTTPException(result["status"], result["error"])
        return result

    async def delete(self, user, item_id):
        response = await self.repo.request(
            "DELETE",
            "/rest/v1/vanity_items",
            params={"id": f"eq.{item_id}", "user_id": f"eq.{user}"},
            headers={"Prefer": "return=representation"},
        )
        if not response.json():
            raise HTTPException(404, "Product not found.")
        return {"deleted": True}


def router(repo, authenticated_user):
    routes = APIRouter(prefix="/v1/vanity", tags=["Digital Vanity"])
    service = VanityService(repo)

    @routes.get("")
    async def list_items(
        q: str = Query(default="", max_length=200),
        category: str = Query(default="", max_length=80),
        offset: int = Query(default=0, ge=0, le=1_000_000),
        user=Depends(authenticated_user),
    ):
        return await repo.rpc(
            "list_vanity_items",
            {
                "p_user": user,
                "p_query": q.strip(),
                "p_category": category.strip().lower(),
                "p_offset": offset,
            },
        )

    @routes.get("/{item_id}")
    async def get_item(item_id: UUID, user=Depends(authenticated_user)):
        return await service.get(user, str(item_id))

    @routes.put("/{item_id}")
    async def save_item(item_id: UUID, body: VanityItem, user=Depends(authenticated_user)):
        return await service.save(user, str(item_id), body)

    @routes.delete("/{item_id}")
    async def delete_item(item_id: UUID, user=Depends(authenticated_user)):
        return await service.delete(user, str(item_id))

    return routes
