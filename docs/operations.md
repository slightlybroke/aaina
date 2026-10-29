# Phase 1 operations

## Data and retention

Consent version `skin-analysis-v1` and a server timestamp are saved before upload. Uploaded JPEG/PNG
bytes are decoded, orientation corrected, reduced to a 2560 px bounding box, re-encoded to JPEG
without EXIF/GPS, and stored in a private bucket. Invalid/small images are rejected before storage.
The original image and ZIP/masks are never written to local application files.

App-owned temporary images are due for deletion immediately on terminal job state, with a default
one-hour upper target after creation. Active jobs expire after 30 minutes. The worker expires stale
jobs and performs idempotent storage deletion. Failed cleanup is persisted with a sanitized code,
attempt count and next attempt five minutes later. It remains retryable indefinitely.

The worker must keep running. Downtime may extend physical retention; on restart it sweeps overdue
records. Monitor `cleanup_status = 'failed'` and overdue `image_delete_after` in the operator dashboard.
If database writes themselves fail, a sanitized worker error is logged and the durable pending
record is retried on a later tick. Do not log HTTP bodies, headers, selfie bytes or signed asset URLs.
Delete user Storage objects before administrative account deletion, because account cascades remove
the job metadata needed by cleanup. No account-deletion UI is included in Phase 1.

YouCam retains its own processing copy under its terms; our cleanup does not revoke or delete that
copy. Confirm the provider retention agreement before a real-user release. No permanently public
selfie bucket or Supabase signed image URL is used.

## Durable work and retries

The API creates a row before storage upload, then marks it pending. PostgreSQL uniqueness on
`(user_id, idempotency_key)` makes replay return the same job. Reusing that key with different
image bytes returns 409. A new intentional scan needs a fresh key. The frontend keeps the retry
key and image in memory across network retries; after restarting the app, check Recent scans first.

Worker claims use row locking, `SKIP LOCKED`, a 180-second lease, and a unique fencing token.
Each update checks that token/state/lease. Result insertion and job completion share a transaction.
Polling defaults to ten seconds; safe transient failures back off and stop after five failures.
Expired work is not resubmitted. Images and analysis data have independent lifecycles.

The task submission boundary is intentionally conservative. If the process dies or the connection
fails after marking `submitting`, the provider may have accepted the request. The recovered job
becomes `submission_unknown`. Do not reset it to pending. Reconcile in the provider console using
the time/account before a new scan. This prevents blind duplicate paid submissions but cannot
guarantee exactly-once external execution without provider idempotency support.

For a known saved external task ID, restarting the worker resumes status retrieval rather than
creating another task. An operator may inspect job metadata server-side; clients do not receive
provider task IDs or signed result URLs. Current public history is bounded to 50 results and 20 jobs.

## Environment verification

Flutter's Windows launcher loops while trying to open its SDK cache lock. Workspace sandboxing
denied that write and also access to `.flutter_tool_state` outside the project. Running the installed
SDK with access to those existing paths resolved `flutter --version`; no upgrade or global config
change was needed. Pip networking also required sandbox approval. The Python virtual environment
is local to `backend/.venv`; no system Python installation or PATH edit was performed.
