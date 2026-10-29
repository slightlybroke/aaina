# Phase 3 Milestone 4 — Makeup preview

Entry: **Digital vanity → Try makeup preview**. Independent of inventory, Gemini and skin
analysis. No automatic image submission on navigation, template loading or job refresh.

## Provider contract checked 2026-10-28

Official [Makeup reference](https://docs.perfectcorp.com/reference/makeup_vto/v1.0),
[effect and file guide](https://docs.perfectcorp.com/reference/makeup_vto/section/overview),
[Look workflow](https://docs.perfectcorp.com/reference/ai_look_vto/section/overview) and
[Look reference](https://docs.perfectcorp.com/reference/ai_look_vto/v1.0) were inspected.

Uses File API registration plus its returned PUT upload before submitting `src_file_id`.
Makeup tasks use `/s2s/v2.0/task/makeup-vto`, specification version 1.0. First effect is
original-shape, full-style matte lip color with a selected hex/intensity. Skin smoothing
is explicitly zero (the provider otherwise applies a default). No retail shade mapping.
Look mode uses real IDs from the first 20 provider templates, then `/s2s/v2.0/task/look-vto`.
Look can apply several beauty effects; it does not reproduce owned products.

Both are asynchronous: poll the corresponding task-ID endpoint. Parser accepts documented
running/queued/processing, success and error states; it accepts `results.url` and the guide's
single-item `results[].download_url`. Other shapes fail closed. Result is an image, not the
skin-analysis ZIP. Downloads require approved HTTPS asset hosts, carry no API bearer key,
reject redirects and are size-bounded and decoded/re-encoded before private storage.

The guide's long-side limit and error's height limit conflict. This implementation keeps
both width <1920 and height <1080, without upscaling; minimum each side 100, source under
10 MB, maximum decoded area 25 MP. Provider still validates face width, position and pose.
Flutter photo preparation now has optional VTO dimensions; its default HD-analysis behavior
is unchanged. Existing gallery/camera selection is reused, with local review before upload.

Documentation-based interfaces and mocked tests are not successful live task evidence.
Public template listing and, subsequently, one actual lip task and one actual listed Look
task passed using an explicitly consented public provider demo image. Exact scope and browser
gallery fix evidence are in the 2026-10-28 acceptance entry in `validation.md`.

## Schema, privacy and recovery

Forward-only migration `202610280001_makeup_vto.sql` adds `vto_jobs`, three indexes, owner-read
RLS, three server-only worker functions, and the private `vto-images` bucket. No existing
tables, policies, files or applied migrations are rewritten. The developer confirmed applying
it to `zouvroynucstxqimygzd`; ordinary-token live checks are in the validation report.

Clients cannot write VTO rows or access Storage directly, including their own images. Backend
validates Supabase Auth and scopes every lookup to that identity. Preview bytes are returned
through an owner-authenticated route with `no-store, private`; no asset URL is exposed to
Flutter. Privileged credentials stay server-side. Flutter's displayed preview is dropped and
evicted at expiry or when leaving the screen. The app does not intentionally save selected
source photos to disk; transient Flutter image-cache and OS picker/camera copies can remain
according to platform behavior. Backend retention is separate from those local caches.

Consent is separate: `makeup-vto-v1`, stored with timestamp and each job. It covers sending
the selected image to Perfect Corp and possible credits. Our application retention does not
promise provider-side deletion; provider data terms apply independently.

Image access expires one hour from job creation, including after fresh login. Source deletion
is attempted as soon as work reaches a terminal state; preview is retained only until expiry.
Deletion needs the VTO worker. Failures persist in source/result cleanup state, attempt count,
safe error and retry time. An additional expiry+10-minute verification sweep catches late
uploads, even if an earlier pass marked deletion complete. Metadata remains for job recovery;
no image URL or source pixels are stored in metadata. Worker downtime can delay physical
deletion; API expiry still denies access. Monitor cleanup failures and run the worker.

Per-owner idempotency keys bind image SHA256 plus validated effect options. Unique constraints
arbitrate concurrent creates. Same request replays its job; changed input/key starts new work.
Flutter retains its key for unchanged-input retry on this screen, not across app restarts.
It offers job refresh after a lost reply. Pending/submitting/processing and terminal states
are durable. A row lease/transaction guards worker claim and completion. A recovered
`submitting` job becomes `submission_unknown`, never an automatic paid resubmission. Safe
polls/downloads retry with bounded backoff; existing preview bytes must match on recovery.
Changing input is an explicit new request and can consume credits.

## Local commands and API

Backend `.env`: `YOUCAM_VTO_ENABLED=true` only after migration/entitlement review; default is
false. Existing `YOUCAM_API_KEY`, Supabase configuration and approved asset hosts are reused.
No Flutter secrets or new third-party dependencies.

```powershell
cd backend
.\.venv\Scripts\python.exe -m uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000 --ws-max-size 65536
# Separate terminal, VTO only; do not start analysis work for VTO:
.\.venv\Scripts\python.exe -m app.vto_worker
```

- `GET /v1/vto/templates`: first 20 validated provider IDs/titles, authenticated.
- `POST /v1/vto/jobs`: multipart image, `consent_version`, JSON-string `options`, UUID
  `Idempotency-Key`; 202. Options: mode lip_color or look, hex color, integer intensity 1–100,
  listed template_id for Look. Invalid input 422; changed retry payload 409.
- `GET /v1/vto/jobs`: up to 50 own jobs, newest first. Metadata only.
- `GET /v1/vto/jobs/{id}`: owner-scoped state; missing/other user 404.
- `GET /v1/vto/jobs/{id}/preview`: authenticated JPEG; unavailable/expired 410, other user 404.
  The same routes appear in FastAPI `/docs`.

Checks from repository root:

```powershell
.\backend\.venv\Scripts\python.exe -m pytest backend/tests -q -p no:cacheprovider --basetemp=backend/.pytest-tmp-vto
.\backend\.venv\Scripts\python.exe -m ruff check backend/app backend/tests backend/scripts
.\backend\.venv\Scripts\python.exe -m pip check
# From backend, STOP app.vto_worker first so synthetic jobs cannot reach YouCam:
.\.venv\Scripts\python.exe scripts/check_vto_live.py --worker-stopped
```

`supabase/tests/vto.sql` executes the migration/RLS/lease tests in a rolled-back local
PostgreSQL harness. Its Storage bucket table is a stub; it does not prove real Supabase
Storage policies. Live ordinary-token checks cover actual project isolation separately.

Explicit paid acceptance later, only with a newly consented permitted image:

```powershell
cd backend
.\.venv\Scripts\python.exe scripts/live_vto_smoke.py --image C:/path/to/consented.jpg --consent
# Separately authorized Look task; first currently listed template:
.\.venv\Scripts\python.exe scripts/live_vto_smoke.py --image C:/path/to/consented.jpg --consent --mode look
```

This signs in with ignored test-account configuration, submits one lip task and same-key
replay, checks lifecycle/preview decode and source deletion. It does not export photos or
print credentials/URLs/transcripts. It must actually end LIVE_VTO_PASS before claiming success.
Final one-hour preview cleanup and Look rendering need separate checks. Missing provider
entitlement/credits or a permitted consented image are live-acceptance blockers, not mocked
test failures. No personal selfie is needed for build/unit/security work.

## Deferred acceptance batch

1. Browser/device: consent gating, gallery cancellation/error, front camera/switch, hex/template
   selection, processing/refresh, failure/retry and private preview. No auto-submission.
2. One consented lip effect: verify visible change and no unexpected smoothing, pose errors,
   same-key replay, source deletion, fresh login, second-user denial, expiry and cleanup.
3. One provider-listed Look only after consent/cost review. Confirm actual template/image.
4. Remaining Talk checks: spoken inventory lookup after Other/Others fallback, English under
   ordinary noise, interruption, Stop/background mic/routing release. Keep each result separate.

The later browser acceptance found and fixed an encoded-ImageDescriptor dimension API that
Flutter does not implement on web. Browser JPEG/PNG/WebP now use the existing image library
with bounded header checks, single-frame decode, orientation baking and pixel-only JPEG
re-encoding. Native codecs remain unchanged. Browser gallery/review/consent and private preview
rendering now have actual UI evidence; native camera/Talk still need their separate checks.
Android and web builds alone do not establish interactive acceptance; iOS needs macOS/Xcode.
Milestone 5 is implemented separately; see `phase3-discovery.md`.
