# Phase 3 — Milestone 1: Digital Vanity

This milestone stores products a user owns. It contains no product discovery catalogue,
recommendation engine, Gemini client, VTO, MCP or Beauty Memory. Existing skincare routines
continue to hold plain product names; no speculative linkage or data conversion is added.

## Data and security

Apply `supabase/migrations/202610260002_digital_vanity.sql` after the two existing migrations.
It creates only `vanity_items`, two owner-based indexes, one ownership SELECT policy and two
server-only functions. Applied migrations and existing user data are never rewritten.

Each item has a stable UUID, Auth owner, UTC creation/update instants, version, product name,
brand, category, shade name, shade identifier, finish, undertone and notes. Only the name is
required (1–150 characters). Optional metadata is stored as empty strings when unknown;
category defaults to `other`. Categories accept free text, normalize to lowercase and allow
lipstick, foundation, blush, eyeshadow, mascara, eyeliner or any custom category. Fields have
explicit limits; the schema and API do not claim user-entered properties are verified facts.

Product images are **not supported in this minimal milestone**. No image URL, upload route,
bucket, object, external image fetch or new device permission is introduced. This is an
explicit limitation, not a partially secured upload workflow. Product photos can be considered
separately with private storage and cleanup when needed.

FastAPI reuses the existing Supabase `/auth/v1/user` bearer verification. Every read, search,
save and delete uses the verified owner. Client-supplied user IDs and unknown fields are
rejected. Direct authenticated access is SELECT-own-only; anonymous access and client writes
are denied. Service-role credentials stay in the backend. Both fixed RPCs revoke execution
from PUBLIC/anon/authenticated and set a fixed search path; no dynamic SQL is used.

`save_vanity_item` serializes writes for the same UUID, verifies ownership and atomically
checks optimistic `expected_version`. Identical content retries return the existing row
without increasing its version. Changed stale content returns 409; editing a deleted or
another user's item returns 404. A create editor keeps its UUID across uncertain-response
retries, preventing accidental duplicate products. Changed metadata applies immediately to
inventory; routine revision rules are unaffected. Deletion physically removes only the
specified owned item, after UI confirmation. No existing history references it.

## Routes

All require an ordinary signed-in bearer token; typed schemas are also available in `/docs`.

| Method | Route | Behavior |
| --- | --- | --- |
| GET | `/v1/vanity?q=&category=&offset=0` | Search/filter owned inventory; 50 rows, `has_more`, owned categories |
| GET | `/v1/vanity/{uuid}` | Read one owned product; absent/not-owned => 404 |
| PUT | `/v1/vanity/{uuid}` | Create or replace metadata; `expected_version` for changed existing items |
| DELETE | `/v1/vanity/{uuid}` | Delete only the verified caller's matching item |

Search is a case-insensitive **literal substring** across product name, brand, category, shade,
identifier, finish, undertone and notes. `%`, `_`, quotes, commas and filter-like strings are
literal characters. `list_vanity_items` receives bound JSON parameters and uses `strpos`,
not interpolated SQL or client-generated PostgREST OR expressions. Category filtering is exact
after lowercasing/trimming. Categories come only from this owner's inventory, independent of
the current query, so another user's metadata cannot leak through filter choices.

Lists have stable creation-time/UUID ordering and offset pagination. The owner/category
indexes support retrieval; substring matching scans only owned candidates. No external
catalogue, search service or extra dependency is needed for this initial personal inventory.
Offset paging reflects current data; refresh starts again at page zero after inventory edits.

## Flutter

The existing dashboard gets a Digital vanity action and shortcut, preserving all five
Phase 1/2 destinations. A separate `VanityPage` provides add, view/details, edit, confirmed
delete, search, category filtering, clear filters, pagination and loading/empty/error/retry
states. Its route guards account changes so another session cannot retain the prior owner's
visible inventory. It reuses the authenticated `AnalysisApi`, not a client service-role key.

`VanityEditor` supports incomplete metadata, free-form categories with convenience chips,
and explicit stale-item reload. Reload clearly discards unsaved edits. Unknown brands/shades
are labelled not recorded; no production example products or inferred shades are generated.
Failed/uncertain saves keep the editor open; failed deletions can refresh authoritative data.
Mobile and web use the same screens; no new Flutter package or platform permission is added.

## Checks

From project root:

```powershell
.\backend\.venv\Scripts\python.exe -m pytest backend/tests -q -p no:cacheprovider --basetemp=backend/.pytest-tmp-vanity
.\backend\.venv\Scripts\python.exe -m ruff check backend/app backend/tests backend/scripts
.\backend\.venv\Scripts\python.exe -m pip check
cd frontend
flutter analyze --no-pub
flutter test --no-pub --timeout 60s
flutter build apk --debug --no-pub --dart-define-from-file=.env
flutter build web --no-pub --dart-define-from-file=.env
```

After applying the migration to the confirmed dev project, from `backend/`:

```powershell
.\.venv\Scripts\python.exe scripts/check_vanity_live.py
```

The live script pins `zouvroynucstxqimygzd`, reads the two dedicated test credentials from
ignored local configuration, uses ordinary password logins and actual FastAPI/Supabase
requests, and creates UUID-scoped disposable inventory. It checks concurrent retries,
incomplete metadata, edits, literal search/filtering, stale versions, ordinary-token RLS,
denied direct mutations/privileged RPCs, cross-owner API denial, fresh-login persistence,
delete and cleanup. Baselines of existing Phase 1 history and raw Phase 2 records must remain
unchanged. Privileged fixture setup/cleanup is not used as proof of user isolation. It makes
no provider/image requests and fails on cleanup errors without printing credentials/metadata.

`supabase/tests/vanity.sql` is rollback-only SQL coverage using simulated claims. For an empty
isolated local PostgreSQL database, use the local-only Auth stub, then the Vanity migration,
then this SQL test. Never install the local Auth stub into Supabase. Mocked pytest/widgets
do not prove live RLS; actual device/browser interactions are reported separately.

Primary security reference: [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).
Actual outcomes and the full file manifest are in `docs/validation.md`.
