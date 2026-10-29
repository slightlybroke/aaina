"""Explicitly consented paid live VTO check; never run automatically by tests."""

import argparse
import asyncio
import io
import json
from pathlib import Path
from uuid import uuid4

import httpx
from dotenv import dotenv_values
from PIL import Image

from app.config import Settings
from app.vto_provider import prepare_vto_image


async def run(args):
    if not args.consent:
        raise RuntimeError(
            "Use --consent only for an image you may send to Perfect Corp; API credits may be consumed."
        )
    content = prepare_vto_image(Path(args.image).read_bytes())
    s = Settings()
    env = dotenv_values(".env")
    if s.supabase_url != "https://zouvroynucstxqimygzd.supabase.co":
        raise RuntimeError("This smoke is restricted to the confirmed development project.")
    async with httpx.AsyncClient(timeout=70, follow_redirects=False) as h:
        r = await h.post(
            s.supabase_url + "/auth/v1/token?grant_type=password",
            headers={"apikey": s.supabase_publishable_key},
            json={"email": env.get("LIVE_TEST_EMAIL"), "password": env.get("LIVE_TEST_PASSWORD")},
        )
        if r.status_code != 200:
            raise RuntimeError("Ordinary test login failed.")
        headers = {
            "Authorization": "Bearer " + r.json()["access_token"],
            "Idempotency-Key": str(uuid4()),
        }
        options = {"mode": args.mode}
        if args.mode == "look":
            listed = await h.get(args.api + "/v1/vto/templates", headers=headers)
            if listed.status_code != 200 or not listed.json():
                raise RuntimeError("No listed Look template available.")
            options["template_id"] = listed.json()[0]["id"]
            print("INFO: using first validated provider Look template", flush=True)
        data = {"consent_version": "makeup-vto-v1", "options": json.dumps(options)}

        async def submit():
            return await h.post(
                args.api + "/v1/vto/jobs",
                headers=headers,
                data=data,
                files={"image": ("consented.jpg", content, "image/jpeg")},
            )

        first = await submit()
        if first.status_code != 202:
            raise RuntimeError(
                "Submission rejected; check API setup before creating another request."
            )
        job = first.json()
        job_id = job["id"]
        if args.evidence:
            # Non-secret metadata only, allows read-only follow-up without resubmission.
            Path(args.evidence).write_text(
                json.dumps({"job_id": job_id, "mode": args.mode}), encoding="utf-8"
            )
        replay = await submit()
        if replay.status_code != 202 or replay.json()["id"] != job_id:
            raise RuntimeError("Idempotency check failed.")
        print("PASS: one consented " + args.mode + " job and idempotent replay", flush=True)
        states = []
        for _ in range(60):
            r = await h.get(args.api + "/v1/vto/jobs/" + job_id, headers=headers)
            r.raise_for_status()
            job = r.json()
            if job["status"] not in states:
                states.append(job["status"])
                print("STATE: " + job["status"], flush=True)
            if job["status"] in {"completed", "failed", "expired"}:
                break
            await asyncio.sleep(10)
        if job["status"] != "completed":
            raise RuntimeError(
                "VTO did not complete: " + str(job.get("error_code") or job["status"])
            )
        preview = await h.get(args.api + "/v1/vto/jobs/" + job_id + "/preview", headers=headers)
        preview.raise_for_status()
        with Image.open(io.BytesIO(preview.content)) as image:
            image.verify()
        print("PASS: real task completed and private preview decoded", flush=True)
        for _ in range(12):
            job = (await h.get(args.api + "/v1/vto/jobs/" + job_id, headers=headers)).json()
            if job["source_cleanup"] == "deleted":
                break
            await asyncio.sleep(5)
        if job["source_cleanup"] != "deleted":
            raise RuntimeError("Source cleanup still pending/failed; inspect worker.")
        print(
            "LIVE_VTO_PASS: real "
            + args.mode
            + " task, private preview, source deletion. Preview expires at one hour; final sweep still requires verification.",
            flush=True,
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--consent", action="store_true")
    parser.add_argument("--api", default="http://127.0.0.1:8000")
    parser.add_argument("--mode", choices=["lip_color", "look"], default="lip_color")
    parser.add_argument(
        "--evidence", help="Optional local metadata JSON path; never stores image or token."
    )
    args = parser.parse_args()
    if args.api != "http://127.0.0.1:8000":
        parser.error("Only the local development API is supported by this smoke.")
    try:
        asyncio.run(run(args))
    except Exception as exc:
        print(
            "LIVE_VTO_NOT_PASSED:",
            str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__,
        )
        raise SystemExit(1) from None
