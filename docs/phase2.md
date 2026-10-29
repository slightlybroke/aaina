# Phase 2 tracking contract

Phase 1's upload, consent, worker, provider parser, private image policy and camera/gallery
implementation are preserved. Tracking and journal actions never call YouCam. Scores remain
separate from routine adherence and user observations.

## Schema and privacy

Apply `supabase/migrations/202610260001_phase2.sql` **after** the Phase 1 migration.
It adds `skincare_settings`, `routines`, `routine_revisions`, `routine_checkins`, `skin_journal`,
four retrieval indexes, five ownership SELECT policies and `skincare_write(uuid,text,jsonb)`.
No existing migration or analysis row is rewritten. No new bucket is created.

All five tables enable RLS, revoke anonymous/client mutation access and allow authenticated
users to read only rows matching `auth.uid()`. Only the backend service role can invoke the
write function. FastAPI reuses Phase 1's bearer-token verification with Supabase Auth; every
query and write receives that verified owner, never a client-provided user ID. Composite
foreign keys prevent mixing a revision, routine and check-in across owners. The RPC locks
per owner in a transaction, including settings, routine revisions and check-in upserts.
Notes, product names and steps are private account data; no analytics or AI processing is added.

## Dates, editing and deterministic summaries

- All instants are PostgreSQL `timestamptz` / timezone-aware UTC in Python. `tzdata` supplies
  IANA rules on Windows and other hosts without a system timezone database.
- Tracking defaults explicitly to **UTC**. The user can choose an IANA zone in the UI before
  the first routine. The zone then stays fixed, including while routines are paused/archived.
  Travel/device timezone changes do not reassign dates. Changing an established tracking zone
  needs a separate, explicit history migration and is outside this initial implementation.
- New routines start on the current date in that zone. Each edit creates a new immutable
  revision effective **tomorrow**, including step order, step deletion, schedule, pause or
  archive. Multiple tomorrow edits use the highest version. Optimistic `expected_revision`
  prevents stale editors overwriting one another. Existing revisions are never updated.
- A step has a stable UUID, name, optional plain product name and notes. Its list position
  is its display order. All listed steps are required; 1–30 steps, 1–7 ISO weekdays (Mon=1).
- A routine-day is scheduled only when the effective revision is active and lists that
  weekday. Paused, archived, pre-creation and unscheduled days are excluded. Archive preserves
  definitions, revisions and logs. There is no destructive routine-delete endpoint.
- A unique `(routine_id, local_date)` check-in stores the revision ID and completed step IDs.
  PUT replaces that day's selection, including an empty selection to correct a mistake.
  Repeating the request never adds a row. Historical date edits use that date's revision.
  Future dates, unknown steps and unscheduled-day submissions are rejected. No client streak
  or completion counter is accepted. Creation/update timestamps preserve basic audit metadata.
- A scheduled routine-day is complete when **all** revision steps are checked, partial when
  some are checked, otherwise incomplete. Adherence is completed / scheduled routine-days
  in the inclusive selected period, ending no later than today. No opportunities => no
  percentage (`null`), rather than an invented 0% or 100%. Partial days are counted separately.
- Each routine's streak counts consecutive completed **scheduled** days. Unscheduled and
  paused days neither add nor break it. An incomplete past scheduled day resets it; an
  incomplete *today* has until local midnight and does not yet break the previous streak.
  Best streak and streak through the selected end date use history up to that date, not
  just the selected adherence window. All totals are recomputed from revisions and logs.
- The history window defaults to 30 days; users can choose up to 366 days and correct a past
  scheduled date. Server retrieval paginates internally so Supabase's row cap cannot silently
  truncate the source data. History includes missed days explicitly rather than inventing logs.
- Journal observation timestamps must include an offset; they are normalized to UTC. The UI
  explicitly edits/displays observation times in **UTC**, independently of the routine zone.
  Entries support multiple named concerns, optional mild/moderate/severe self-reported labels,
  notes, correction and confirmed deletion. They are not AI findings or diagnoses.

## API

All routes require `Authorization: Bearer <session access token>`; see FastAPI `/docs` for
typed request bodies. Validation is 422, absent/not-owned resources 404, stale edits/timezone
conflicts 409, expired/missing auth 401, upstream unavailability 503. No new secret variables.

| Method | Route | Behavior |
| --- | --- | --- |
| GET / PUT | `/v1/skincare/settings` | Zone/date/lock state; choose zone before routines |
| GET | `/v1/skincare/routines?day=YYYY-MM-DD` | Effective steps, schedule and check-in for date; latest editable revision |
| PUT | `/v1/skincare/routines/{uuid}` | Create or revise complete ordered definition; archive via status |
| PUT | `/v1/skincare/routines/{uuid}/checkins` | Replace selected step IDs for one date/revision |
| GET | `/v1/skincare/history?start=...&end=...` | Scheduled day history plus authoritative adherence/streak summary |
| GET | `/v1/skincare/journal?offset=0` | Observation history, 50 per page |
| PUT / DELETE | `/v1/skincare/journal/{uuid}` | Create/edit own entry, or delete own entry |
| GET | `/v1/analyses?offset=0` | Existing Phase 1 saved results; adds optional pagination, default stays 50 |

Routine and journal UUIDs are generated once per editor session so a retry uses the same ID.
A lost routine-save response can result in a stale-revision conflict; reload to see the saved
definition instead of creating another routine. Check-in PUT is safe to retry unchanged.

## Flutter and progress

The authenticated app has Today, Routines, Journal, Progress and Skin analysis destinations,
using existing Material styling and StatefulWidget conventions. The existing scan screen
stays mounted once opened so switching tabs preserves its preview/job state. Returning from
it refreshes saved tracking/results. Error, loading, empty and retry states are explicit.
Routine edits explicitly save for tomorrow. When the saved revision differs from the selected
date's checklist, a dated expandable preview shows the saved name, step count and steps while
leaving that day's checkboxes attached to its original revision.

Saved analyses display overall scores, timestamps, raw/UI regional metrics and provider
warnings. Missing values are marked unavailable. A small Flutter-painted chart uses real
timestamps and saved overall scores only. No chart dependency or new score is introduced.
Comparison requires at least two finite saved scores with valid times, known v2.1 ZIP data,
and identical HD concern sets. Unknown modes, SD/mixed modes and differing concern sets are
conservatively refused; common concern+region keys are compared, without inventing missing
components. Camera conditions can affect results. No new analysis is submitted by navigation.
More precise future mode compatibility would require explicit mode metadata at capture time.

## Validation commands and limits

From project root:

```powershell
.\backend\.venv\Scripts\python.exe -m pytest backend/tests -q --basetemp=backend/.pytest-tmp
.\backend\.venv\Scripts\python.exe -m ruff check backend/app backend/tests backend/scripts
.\backend\.venv\Scripts\python.exe -m pip check
cd frontend
flutter analyze --no-pub
flutter test --no-pub --timeout 60s
flutter build apk --debug --no-pub --dart-define-from-file=.env
flutter build web --no-pub --dart-define-from-file=.env
```

From `backend/`, after applying the migration and configuring dedicated test accounts locally:

```powershell
.\.venv\Scripts\python.exe scripts/check_phase2_live.py
```

This script pins the confirmed development hostname, signs in two ordinary accounts and
executes the actual FastAPI app with a real Supabase adapter. It uses user tokens for direct
RLS assertions, not service-role reads as isolation proof. Only test-fixture setup/cleanup uses
privileged access. It exercises persisted partial/full/corrected check-ins, revision history,
journal CRUD, stale edits, cross-owner API denial, denied direct table writes/privileged RPC,
actual sign-out/fresh password login and unchanged Phase 1 history. It never sends images or
starts a worker. Cleanup is limited to generated fixture UUIDs and checked; failures fail the run.

`supabase/tests/phase2.sql` is supplementary rollback-only SQL coverage, using two Auth users
and simulated claims. Local PostgreSQL with a minimal Auth stub proves SQL execution, not
live Supabase Auth. Neither that test nor mocked widgets proves native device interaction.
Actual dated outcomes and platform limitations belong in `docs/validation.md`.

For a **new isolated local test database only**, execute `supabase/tests/local_auth_stub.sql`,
then the Phase 2 migration, then `supabase/tests/phase2.sql` with `psql -v ON_ERROR_STOP=1`.
The stub is not a migration and must never be applied to Supabase. The local test cluster
must bind to loopback; stop it when finished. There is no dependency on PostgreSQL binaries
for running the mocked pytest suite.

Primary design references: [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)
and [PostgreSQL date/time](https://www.postgresql.org/docs/current/functions-datetime.html).
