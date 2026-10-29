"""Opt-in real test via running API + worker. Never prints tokens, photos, or signed URLs."""

import argparse
import asyncio
import json
import os
from pathlib import Path
from uuid import uuid4

import httpx
from dotenv import load_dotenv


async def run(args):
    load_dotenv()
    required = ("SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "LIVE_TEST_EMAIL", "LIVE_TEST_PASSWORD")
    missing = [name for name in required if not os.getenv(name)]
    if missing:
        raise SystemExit("Configure locally: " + ", ".join(missing))
    if not args.consent:
        raise SystemExit("Use --consent only for an image you consent to sending to YouCam.")
    async with httpx.AsyncClient(timeout=65, follow_redirects=False) as client:
        auth = await client.post(
            os.environ["SUPABASE_URL"] + "/auth/v1/token?grant_type=password",
            headers={"apikey": os.environ["SUPABASE_PUBLISHABLE_KEY"]},
            json={
                "email": os.environ["LIVE_TEST_EMAIL"],
                "password": os.environ["LIVE_TEST_PASSWORD"],
            },
        )
        if auth.status_code != 200:
            raise SystemExit("Test-account authentication failed; no token printed.")
        headers = {"Authorization": "Bearer " + auth.json()["access_token"]}
        key = str(uuid4())
        content = Path(args.image).read_bytes()

        async def submit():
            response = await client.post(
                args.api + "/v1/analyses",
                headers={**headers, "Idempotency-Key": key},
                data={"consent_version": "skin-analysis-v1"},
                files={"image": ("selfie", content)},
            )
            if response.status_code != 202:
                raise SystemExit(
                    f"Submission failed (HTTP {response.status_code}); inspect API response locally."
                )
            return response.json()

        first, retry = await submit(), await submit()
        if first["id"] != retry["id"]:
            raise SystemExit("Idempotency verification failed.")
        print("Submitted once; replay returned the same job:", first["id"])
        for _ in range(190):
            response = await client.get(args.api + "/v1/jobs/" + first["id"], headers=headers)
            if response.status_code != 200:
                raise SystemExit(f"Status failed (HTTP {response.status_code}).")
            job = response.json()
            if job["status"] == "completed":
                history = await client.get(args.api + "/v1/analyses", headers=headers)
                history.raise_for_status()
                if not any(item["job_id"] == first["id"] for item in history.json()):
                    raise SystemExit("Result was not retrieved from account history.")
                print(
                    json.dumps(
                        {
                            "result": "LIVE_PASS",
                            "job_id": first["id"],
                            "overall_score": job["analysis"]["overall_score"],
                            "metrics": job["analysis"]["metrics"],
                            "history_verified": True,
                        },
                        indent=2,
                    )
                )
                return
            if job["status"] in ("failed", "expired"):
                raise SystemExit("Live check did not pass: " + str(job.get("error_code")))
            await asyncio.sleep(10)
        raise SystemExit("Timed out waiting; inspect saved job before submitting again.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--api", default="http://localhost:8000")
    parser.add_argument("--consent", action="store_true")
    try:
        asyncio.run(run(parser.parse_args()))
    except httpx.HTTPError:
        raise SystemExit(
            "Network/service error; inspect the saved job before starting another scan."
        ) from None
