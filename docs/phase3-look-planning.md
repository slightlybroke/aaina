# Phase 3 Milestone 2 — makeup look planning

This is a deterministic category/label planner using existing owned Vanity metadata. No Gemini,
VTO, discovery, new credentials, migration, bucket or saved-look history is added. Plans are
computed read-only when requested. Inventory and all Phase 1/2 records remain unchanged.

## Inputs and behavior

`POST /v1/looks/plan` requires the existing verified Supabase bearer identity. Optional occasion
and outfit strings are accepted as context, with explicit UI/API disclosure that this first
version cannot infer color harmony, suitability or wear performance from them. Conversational
interpretation remains Milestone 3. Nothing is sent to a language model or external provider.

`style` chooses an editable category plan:

| Style | Default roles |
| --- | --- |
| natural | blush, mascara, lipstick |
| soft_glam | foundation, blush, eyeshadow, mascara, lipstick |
| bold | eyeshadow, eyeliner, mascara, lipstick |
| custom | explicit categories required |

These are planning templates, not claims that arbitrary products produce those visual styles.
`categories` overrides the defaults, including free-form custom categories. `excluded_categories`
removes roles. Both arrays accept at most 12 category strings of 1–80 characters, normalize to
lowercase and deduplicate. Empty custom plans/all-excluded plans ask which categories to use.

`preferred_shade` is a literal case-insensitive substring of the recorded **shade_name** for
lipstick, blush, eyeshadow and eyeliner. It does not infer a color from product/brand names,
shade identifiers, undertones or notes. It does not select a foundation shade or claim a match
to skin tone. `preferred_finish` similarly matches the recorded finish, for **every** selected
category. Blank preference means unrestricted, not an invented product property.

Missing labels never satisfy explicit preferences. If known labels conflict or are incomplete,
the affected role is left unfilled, with missing-field details and a question to update labels
or change preferences. If a category has no owned product, the gap is stated without inventing
a product, brand or shopping URL. No automatic product creation or out-of-inventory suggestion.

One eligible product per role is chosen; more populated brand/shade/finish records are preferred,
then IDs break ties deterministically. This ordering is not a quality, confidence or beauty score.
Products are returned with their stored identity/metadata and reasons tied only to their actual
category and explicit label matches. Unknown shade/finish/undertone remain marked missing.
The API returns `ready` for fully filled category plans, `partial` for a plan with gaps, or
`needs_information` when it cannot suggest anything. It always returns its limitations.

## Access, scale and UI

The backend obtains the user solely from the existing Auth verification dependency and queries
only that owner's `vanity_items`. It paginates past the first displayed 50 rows, including
databases configured with a lower page cap. The selected fields exclude private notes and
timestamps; notes cannot become instructions. Client user IDs, unknown fields and invalid
style/length/category values are rejected. Existing RLS remains unchanged. Upstream failures
use the existing 503 response rather than returning an apparently valid empty plan.

This initial service reads all owned candidate metadata server-side; the phone receives only
the small plan. Huge-inventory performance has not been benchmarked. Future optimization
should measure this path before introducing indexes, candidate limits or a separate service.

Open Digital vanity → **Plan a makeup look**. Flutter collects context, style/category roles,
exclusions and literal shade/finish preferences. Results show real products, reasons, missing
labels, gaps and clarification questions. Empty/error/loading/retry states are explicit.
Changing inputs clears an old result; planning runs only on button submission. A session-bound
route hides results if the account changes. No new Flutter package or permission is needed.

## Verification

From project root:

```powershell
.\backend\.venv\Scripts\python.exe -m pytest backend/tests -q -p no:cacheprovider --basetemp=backend/.pytest-tmp-looks
.\backend\.venv\Scripts\python.exe -m ruff check backend/app backend/tests backend/scripts
.\backend\.venv\Scripts\python.exe -m pip check
cd frontend
flutter analyze --no-pub
flutter test --no-pub --timeout 60s
flutter build apk --debug --no-pub --dart-define-from-file=.env
flutter build web --no-pub --dart-define-from-file=.env
```

From `backend/`, `./.venv/Scripts/python.exe scripts/check_looks_live.py` verifies actual Auth,
database reads, deterministic results and owner restriction using two existing test accounts.
It uses their actual existing inventory, prints only counts/check labels, fingerprints inventory
before/after, and creates no fixtures or provider requests. It does not prove a visually
successful look, huge-inventory performance, or device interaction. See `docs/validation.md`
for executed results, mocked/live distinctions and pending platform checks.
