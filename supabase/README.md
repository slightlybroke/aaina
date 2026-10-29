# Database migrations

Master Phase 4 preference foundation: `migrations/202610280003_makeup_preferences.sql` adds
one private owner-keyed settings table and owner-read RLS, no changes to previous data.
`tests/makeup_preferences.sql` runs local rolled-back isolation assertions. The live script
`backend/scripts/check_preferences_live.py` checks dedicated ordinary accounts; optional
`--gemini` uses only synthetic context and cleans its fixtures. See `docs/phase4-context.md`.

Milestone 5 adds `migrations/202610280002_product_discovery.sql`: a shared public-metadata
catalogue, two indexes, authenticated active-record read policy and server-only search RPC.
It does not change private Vanity or VTO. `tests/discovery.sql` provides rollback-only local
assertions. Apply to the confirmed dev project after review, then import the reviewed JSON
with `backend/scripts/import_catalogue.py --apply` from backend. See `docs/phase3-discovery.md`.

Apply `migrations/202610250001_phase1.sql` once in a dedicated Supabase development project.
Then apply `migrations/202610260001_phase2.sql` for private routines, immutable revisions,
daily check-ins, settings and the concern journal. Do not reapply or edit an applied migration.
The confirmed development project is `zouvroynucstxqimygzd`; the developer applied both
migrations through its SQL editor. Dated live evidence is in `../docs/validation.md`.

Phase 3 Milestone 1 adds `migrations/202610260002_digital_vanity.sql`: one inventory table,
two indexes, one owner-read policy and two server-only functions. It changes no existing
table or Storage policy. The developer confirmed application to the same development project.
Use `tests/vanity.sql` for rollback-only SQL assertions and `backend/scripts/check_vanity_live.py`
for actual ordinary-account isolation/persistence checks; see `../docs/phase3-vanity.md`.

Milestone 4 adds `migrations/202610280001_makeup_vto.sql`: independent VTO jobs, three indexes,
owner-read RLS, three server-only worker functions and the private `vto-images` bucket.
Developer confirmed application to the same development project. No direct client Storage
access is granted, even to the owner; use the authenticated backend preview route.
`tests/vto.sql` is a rollback-only local PostgreSQL harness with a Storage table stub.
For real RLS/Storage checks, stop the VTO worker, then run from backend:
`python scripts/check_vto_live.py --worker-stopped`. Synthetic test jobs must never be picked
up by a provider worker. See `../docs/phase3-vto.md` for retention and paid acceptance.

`tests/ownership.sql` is a transaction that asserts database and storage ownership isolation,
denies direct client writes, and checks worker RPC access. Run it as the SQL editor's postgres
role after creating two confirmed development users. It rolls back all fixtures. It does not
test actual object bytes or external APIs. Do not run it on a production database.

The backend owns job mutations; authenticated clients may read only their own rows and
unexpired private temporary objects. No anonymous policies exist. Do not add broader bucket
policies to make images accessible to YouCam; the worker uses the provider File API instead.

Phase 2 adds no Storage objects or policies. `tests/phase2.sql` provides transactional SQL
assertions; `backend/scripts/check_phase2_live.py` additionally checks actual ordinary-user
Supabase sessions and persistence. See `../docs/phase2.md` for commands and semantics.
