# Weekly Beauty Brief and focused polish

Open **Today → Weekly Beauty Brief**. A bell and “new report” label indicate an unread
snapshot. Opening the inbox, returning to Today or refreshing Today reloads availability.
This is an in-app notification, not a push notification or OS background task on the phone.
Reports load independently so an error cannot prevent routine check-ins.

## What a report means

A report covers the **last fully completed Monday–Sunday week in the saved tracking IANA
timezone**. UTC timestamps bound the actual local calendar week, including DST changes.
Use **Set report timezone** in the inbox before first generation. It can also explicitly
confirm the existing locked UTC default for legacy routine accounts without a settings row. The existing Phase 2 timezone lock
after routine creation remains intact. No server-local timezone is inferred.

Each report keeps three signals separate:

- Routine scheduled opportunities, complete and partial routine-days, completion percentage,
  and per-routine streaks as of week end. Existing immutable revisions/check-ins and the
  existing adherence calculation are reused. Unscheduled days do not count or break streaks;
  missing check-ins are not treated as completion. Longest streak means through week end,
  not only within this week. No scheduled opportunities means no adherence percentage.
- Actual saved YouCam results from that week. Latest valid overall score is preserved.
  A change is calculated only between first and last valid results with compatible v2.1 ZIP
  HD concern sets, matching the existing progress view. Regional metrics compare only when
  both sides have the same concern/region and a valid score in the same raw/UI field. Missing
  fields are omitted, never averaged or filled. Incompatible/insufficient data is explicit.
  Lighting/camera/angle may affect comparisons; no routine/product causation is asserted.
- Counts of user-reported journal concerns and severity labels. No journal notes are copied;
  these observations are not presented as AI findings. A report does not diagnose conditions.

Suggestions are short deterministic next actions based on available records. They do not
invent product experiences or treatment effects, require daily scans, or call Gemini/YouCam.
The existing source-reviewed education screen remains available separately.

Snapshots are **immutable after their first successful generation**. Later check-in or
journal corrections do not rewrite them; this limitation is shown in every report. Existing
source histories remain editable. Read acknowledgement is the only mutable report field.
There is at most one report per owner/local week, including across concurrent requests or
worker restarts. An empty week is valid and explicitly shows missing data rather than fake
scores. Changing an unlocked timezone does not rewrite a previously generated week's zone.

## Scheduling and reliability

After applying the migration, run this separate backend process:

```powershell
cd backend
.\.venv\Scripts\python.exe -m app.weekly_worker
```

It sweeps saved tracking settings every five minutes and creates the latest completed week's
report if absent. Monday local midnight makes that week eligible; no future/current partial
week is generated. Keep the worker running under the deployment's process supervisor along
with the API. A desktop development process is not a deployed scheduler.

The saved settings and unique report key are the durable source of pending work. A crash
before save leaves that week eligible for retry; report content and its unread notification
are a **single atomic row**, avoiding an outbox split or duplicate notifications. A concurrent
unique conflict reads the already saved report. Failures are logged by exception class and
retried on the next sweep; one user failure does not prevent other users being processed.
HTTP request logging is suppressed to avoid logging owner IDs from query strings. A failure
before persistence does not create a fake success or notification. There is no separate
durable failure dashboard in this initial worker.

The worker catches up the **latest completed week only**, not every missed historical week.
An explicit **Prepare last week’s brief** button uses the same service and works when the
worker is unavailable. It never creates duplicate reports or resets a read notification.
No weekly provider credits, new dependencies or additional environment keys are required.

## Schema and API

Forward-only migration `202610280005_weekly_reports.sql` adds:

- `weekly_reports`: owner, local week start/end, timezone snapshot, versioned JSON content,
  generation timestamp and nullable read timestamp; unique `(user_id, week_start)`.
- Owner/history and unread indexes; owner-only SELECT RLS policy `weekly_read_own`.
- No client writes, anonymous reads, Storage changes, new RPC or changes to existing tables.

The backend validates bearer tokens with Supabase Auth and scopes every read/write to that
verified identity. The privileged key stays server-side. All routes require authentication:

- `GET /v1/weekly-reports?offset=0`: metadata pages of 20, `has_more`, `has_unread`.
- `POST /v1/weekly-reports/generate`: prepare/read last complete week. Optional body can
  only be `{}`; client owners, periods and computed report data are rejected.
- `GET /v1/weekly-reports/{id}`: own full report, 404 for unknown/foreign records.
- `POST /v1/weekly-reports/{id}/read`: idempotent owner acknowledgement using server UTC time.

The Flutter inbox includes loading, empty, error/retry, pagination and manual acknowledgement.
It does not mark a report read merely because an HTTP request began. Navigation uses the
existing auth-owner guard. This polish adds a dashboard destination and clear report labels,
without redesigning or replacing the existing routine, analysis, journal or vanity screens.

## Validation

From the repository root:

```powershell
.\backend\.venv\Scripts\python.exe -m pytest backend/tests -q -p no:cacheprovider
.\backend\.venv\Scripts\python.exe -m ruff check backend/app backend/tests/test_weekly_reports.py backend/scripts/check_weekly_live.py
.\backend\.venv\Scripts\python.exe -m pip check
# Isolated local PostgreSQL only, rollback-only migration/RLS test:
& 'C:\Program Files\PostgreSQL\17\bin\psql.exe' -h 127.0.0.1 -p 55432 -U postgres -d postgres -v ON_ERROR_STOP=1 -f supabase/tests/weekly_reports.sql
```

From `backend`, with existing local dedicated test account variables (never paste secrets):

```powershell
.\.venv\Scripts\python.exe -m scripts.check_weekly_live
```

The live script verifies two ordinary Auth users, owner persistence, both-direction RLS/API
isolation, direct write denial, repeat generation/read acknowledgement and fresh-login state.
It refuses pre-existing reports for the test period, creates UTC settings only if absent,
then verifies deletion of its new report fixtures and timestamp-matched temporary settings.
It never overwrites a user's existing timezone or report. Cleanup failures are raised.
Do not run it concurrently with another generator against the same dedicated accounts.

From `frontend`:

```powershell
flutter analyze --no-pub
flutter test --no-pub --reporter compact
flutter build apk --debug --no-pub --dart-define-from-file=.env
flutter build web --no-pub --dart-define-from-file=.env
```

See `validation.md` for actual commands/results. Phone walkthrough, iOS, natural weekly
rollover, deployment uptime and previously deferred Phase 3/5/6 acceptance remain separate.
No MCP, onboarding redesign, push notifications or new provider work was introduced.

## Community Wisdom

The configured DevRelay research tools are unavailable in this session. No community
provenance or consensus is claimed. The implementation reuses the repository's existing
time, authorization and progress conventions rather than adding a scheduling dependency.
