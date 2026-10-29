"""Deterministic owned-product planning, independent of language models and VTO."""

from typing import Literal

from fastapi import APIRouter, Depends
from pydantic import Field, field_validator

from app.skincare import Input, SkincareService

ROLES = {
    "natural": ["blush", "mascara", "lipstick"],
    "soft_glam": ["foundation", "blush", "eyeshadow", "mascara", "lipstick"],
    "bold": ["eyeshadow", "eyeliner", "mascara", "lipstick"],
}
COLOR_ROLES = {"lipstick", "blush", "eyeshadow", "eyeliner"}


class LookRequest(Input):
    occasion: str = Field(default="", max_length=300)
    outfit: str = Field(default="", max_length=500)
    style: Literal["natural", "soft_glam", "bold", "custom"] = "natural"
    categories: list[str] = Field(default_factory=list, max_length=12)
    excluded_categories: list[str] = Field(default_factory=list, max_length=12)
    preferred_shade: str = Field(default="", max_length=120)
    preferred_finish: str = Field(default="", max_length=80)

    @field_validator("categories", "excluded_categories")
    @classmethod
    def categories_valid(cls, values):
        normalized = [value.strip().lower() for value in values]
        if any(not value or len(value) > 80 for value in normalized):
            raise ValueError("Each category needs 1–80 characters.")
        return list(dict.fromkeys(normalized))


def matches(value, preference):
    # A literal recorded label match, not inferred color/finish semantics.
    return bool(value.strip()) and preference.casefold() in value.casefold()


def plan_look(items, request: LookRequest):
    roles = request.categories or ROLES.get(request.style, [])
    roles = [r for r in roles if r not in request.excluded_categories]
    suggestions, gaps, questions = [], [], []
    if not roles:
        questions.append(
            "Which product categories would you like in this look? Choose categories that are not excluded."
        )
    for role in roles:
        available = [item for item in items if item["category"] == role]
        eligible = available
        shade_applies = role in COLOR_ROLES and bool(request.preferred_shade)
        if shade_applies:
            eligible = [i for i in eligible if matches(i["shade_name"], request.preferred_shade)]
        if request.preferred_finish:
            eligible = [i for i in eligible if matches(i["finish"], request.preferred_finish)]
        if not eligible:
            if not available:
                gaps.append(
                    {"category": role, "reason": "No owned product is recorded in this category."}
                )
            else:
                fields = (["shade_name"] if shade_applies else []) + (
                    ["finish"] if request.preferred_finish else []
                )
                gaps.append(
                    {
                        "category": role,
                        "reason": "No recorded product matches all explicit preferences.",
                        "missing_fields": sorted(
                            {f for f in fields if any(not i[f].strip() for i in available)}
                        ),
                    }
                )
                questions.append(
                    f"For {role}, can you add the missing labels in Vanity or change the shade/finish preference?"
                )
            continue
        # Prefer recorded detail, then deterministic ID ordering; not a cosmetic quality score.
        eligible.sort(
            key=lambda i: (
                -sum(bool(i[k].strip()) for k in ("shade_name", "finish", "brand")),
                i["id"],
            )
        )
        item = eligible[0]
        reasons = [f"Fills the {role} step in the selected category plan."]
        if shade_applies:
            reasons.append(
                f"Recorded shade label ‘{item['shade_name']}’ contains your requested text ‘{request.preferred_shade}’."
            )
        if request.preferred_finish:
            reasons.append(
                f"Recorded finish ‘{item['finish']}’ contains your requested text ‘{request.preferred_finish}’."
            )
        else:
            reasons.append("No finish restriction was supplied; this is a category-based option.")
        suggestions.append(
            {
                "category": role,
                "product": {
                    k: item[k]
                    for k in (
                        "id",
                        "name",
                        "brand",
                        "category",
                        "shade_name",
                        "shade_identifier",
                        "finish",
                        "undertone",
                    )
                },
                "reasons": reasons,
                "missing_fields": [
                    k for k in ("shade_name", "finish", "undertone") if not item[k].strip()
                ],
            }
        )
    return {
        "context": request.model_dump(),
        "suggestions": suggestions,
        "gaps": gaps,
        "questions": list(dict.fromkeys(questions)),
        "inventory_count": len(items),
        "status": "ready"
        if suggestions and not gaps and not questions
        else "partial"
        if suggestions
        else "needs_information",
        "limitations": [
            "Style chooses product categories, not verified visual effects.",
            "Occasion and outfit are context only; color harmony, suitability and wear time are not inferred.",
            "Matches use user-recorded labels, not verified product properties. No exact try-on is implied.",
            "Shade preference applies to lipstick, blush, eyeshadow and eyeliner; finish preference applies to every selected category.",
        ],
    }


def router(repo, authenticated_user):
    routes = APIRouter(prefix="/v1/looks", tags=["Makeup look planning"])

    @routes.post("/plan")
    async def plan(body: LookRequest, user=Depends(authenticated_user)):
        # Use all owned pages, not just the first 50 visible inventory rows.
        items = await SkincareService(repo).all(
            "vanity_items",
            user,
            "id.asc",
            select="id,name,brand,category,shade_name,shade_identifier,finish,undertone",
        )
        return plan_look(items, body)

    return routes
