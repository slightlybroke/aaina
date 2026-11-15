<p align="center"><img src="frontend/assets/branding/aaina.png" width="160" alt="aaina mirror logo"></p>

# aaina

**Remember. Understand. Explain. Personalize.**

aaina is a mobile-first personal beauty intelligence app built with Flutter, FastAPI,
Supabase, YouCam and Gemini. It helps people understand visible skin characteristics,
build routines that fit their lives, and explore makeup using products they own.

## What works

- Consented skin analysis, saved YouCam scores and compatible progress comparisons.
- Custom skincare routines, individual step check-ins, adherence, streaks and a private journal.
- Digital Vanity with incomplete product metadata, search and custom categories.
- Owned-product look planning, typed Gemini Chat and continuous Talk with transcripts.
- Generic lip/curated Look try-on, temporary private previews and a small reviewed discovery catalogue.
- Reviewable Beauty Memory with explicit sharing controls and source-linked introductory education.
- Weekly Beauty Briefs that keep routine completion, skin results and reported concerns separate.

Scores are estimates of visible characteristics, not diagnoses. Missing product properties,
metrics and retail mappings are not invented. The application does not combine these signals
into a new beauty score. Brand name: **aaina**, lowercase.

## Architecture

```text
frontend/   Flutter Android/iOS/web app
backend/    FastAPI, authenticated services, provider integrations and separate workers
supabase/   Forward-only migrations, RLS and private Storage policies
catalogue/  Small source-reviewed product metadata catalogue
```

Provider keys and Supabase service-role access stay on the backend. Flutter uses only public
configuration and the signed-in user's session. Images are temporary; results persist separately.
See [validation](docs/validation.md) for exact automated/live evidence and pending platform checks.

## Status and limits

Android and web builds have passed; real Supabase/YouCam/Gemini paths have separate live
acceptance evidence. Not every screen/platform has an interactive acceptance pass. iOS runtime,
several deferred phone flows and production worker supervision remain unverified.
Education and automatic memory capture are deliberately narrow; discovery is a small reviewed
catalogue, not a retailer search engine. Generic VTO is not an exact retail-product reproduction.
No MCP adapter, push notifications or medical diagnosis is included.

See the [public launch runbook](docs/launch.md) for the web host, signed Android
APK, GitHub release workflow, account deletion operations, and acceptance checks.

Feature contracts:
[routines](docs/phase2.md), [vanity](docs/phase3-vanity.md),
[Gemini](docs/phase3-gemini.md), [voice](docs/phase3-live-voice.md),
[VTO](docs/phase3-vto.md), [discovery](docs/phase3-discovery.md),
[memory/education](docs/phase6-memory-education.md),
[weekly reports](docs/phase7-weekly-reports.md).

## Local setup (PowerShell)

Use Python 3.12+ and Flutter stable. The verified local versions are Python 3.12.14,
Flutter 3.47.5 and Dart 3.13.4. Python was located in the Codex bundled runtime:

```powershell
python -m venv backend/.venv
.\backend\.venv\Scripts\python.exe -m pip install -r backend/requirements.lock
.\backend\.venv\Scripts\python.exe -m pip install --no-deps -e ./backend
Copy-Item backend/.env.example backend/.env
Copy-Item frontend/.env.example frontend/.env
```

For dependency development use `python -m pip install -e './backend[dev]'`.
Never paste secrets into chat or add them to version control. Only the Supabase publishable key,
URL, app name and backend URL belong in the frontend JSON. The service-role and YouCam keys
belong exclusively in `backend/.env`.

## Supabase setup

Use a dedicated development project. Apply `supabase/migrations/202610250001_phase1.sql`
using its SQL editor or your existing migration tooling. This creates only two tables,
the private `analysis-incoming` bucket, ownership policies, and server-only worker RPCs.
Keep the configured bucket name equal to the migration's name.

Enable email/password authentication and configure confirmation email URLs in Supabase Auth.
Create/confirm two development users for isolation testing. The SQL test in
`supabase/tests/ownership.sql` requires those users and rolls back its fixture records.
Migrations through `202610280005_weekly_reports.sql` have been applied to the confirmed
development project; actual live test evidence is recorded in `docs/validation.md`. Apply
all migration files in filename order on a new project.

RLS grants clients read access to their own rows; job/result writes and storage uploads/deletes
are server-only. The API verifies each bearer token with Supabase Auth and derives ownership
from that verified identity. Every API lookup also filters by owner because service-role access bypasses RLS.

## Run

In one terminal, from the project root:

```powershell
cd backend
.\.venv\Scripts\python.exe -m uvicorn app.main:create_app --factory --reload --host 127.0.0.1 --port 8000
```

In a second terminal:

```powershell
cd backend
.\.venv\Scripts\python.exe -m app.worker
```

In a third terminal:

```powershell
cd frontend
flutter pub get
flutter run -d chrome --web-port 3000 --dart-define-from-file=.env
```

`http://localhost:3000` is allowed by default CORS. Use a matching origin if changing ports.
For Android emulator development, use `http://10.0.2.2:8000` for `API_BASE_URL`, bind the
API to `0.0.0.0` only on a trusted local network, and use a debug build. iOS needs macOS/Xcode;
its source is scaffolded but cannot be built on this Windows host. Production API URLs must use HTTPS.
Web offers photo selection; Android/iOS also offer camera capture.

For a USB-connected Android phone, map its configured localhost port with `adb reverse`.
If port 8000 belongs to another project, run this backend on 8001 and use a matching
`API_BASE_URL`, or map phone port 8000 to host 8001 with `adb reverse tcp:8000 tcp:8001`.
Verify the OpenAPI title is **aaina** rather than relying only on a healthy port response.
Run `python -m app.vto_worker` and `python -m app.weekly_worker` from separate backend
terminals when using try-on and automatic weekly reports. Keep workers supervised in deployment.

Open the API documentation at `http://localhost:8000/docs`. `/health` checks the API process
only, not Supabase, the worker, credentials, or provider readiness.

## Checks

From the project root:

```powershell
.\backend\.venv\Scripts\python.exe -m pytest backend/tests -q --basetemp=backend/.pytest-tmp
.\backend\.venv\Scripts\python.exe -m ruff check backend/app backend/tests backend/scripts
.\backend\.venv\Scripts\python.exe -m pip check
cd frontend
flutter analyze
flutter test
flutter build web --dart-define-from-file=.env
```

Backend tests use mock HTTP transports and an in-memory repository double. They do not prove
PostgreSQL locking, RLS, Storage, email delivery, or live YouCam behavior. Run the SQL test and
live smoke check below before treating Phase 1 as accepted.

## Live acceptance check

1. Apply the migration, configure local environment files, start the API and worker.
2. Check the account's v2.1 entitlement and cost for `hd_wrinkle`, `hd_pore`, `hd_texture`,
   and `hd_acne` before the paid call. A real scan may consume credits.
3. Use an explicitly consented JPEG/PNG: under 10 MB, at least 1080 px on the short side
   after resizing the long side to 2560. Face suitability is ultimately validated by YouCam.
4. Set `LIVE_TEST_EMAIL` and `LIVE_TEST_PASSWORD` locally, in the shell or ignored backend `.env`.
5. From `backend/` run:

```powershell
.\.venv\Scripts\python.exe scripts/live_smoke.py --image C:/path/to/consented-selfie.jpg --consent
```

This signs in, submits through the API, replays the same idempotency key, polls the saved job,
and checks history. It never prints tokens, photos, signed URLs, or passwords. A terminal
`LIVE_PASS` is evidence of that one run only. Save only redacted results in ignored `evidence/`.
Verify both users cannot access each other's jobs/results/Storage; run the SQL assertions.
Verify cleanup reaches `deleted`, including a deliberately interrupted worker/restart test.

See `docs/provider-contract.md` for documented fields, known contradictions, and pending checks.
See `docs/operations.md` for recovery and image-retention behavior.


## Branding and public-source preparation

The supplied aaina logo is included under `frontend/assets/branding/`. Rebuild platform
icons with `python backend/scripts/generate_brand_icons.py` using the backend environment.
Before staging, run `python backend/scripts/audit_public_tree.py` with that environment.
See [public release notes](docs/public-release.md) and [third-party notices](THIRD_PARTY_NOTICES.md).
No remote deployment or app-store release is implied by this source repository.
