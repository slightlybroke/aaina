# Beauty Memory and contextual education

Entry: **Digital vanity → Plan a makeup look → Beauty Memory** or **Learn ingredients and sunscreen**.
Chat and Talk remain separate experiences. Existing saved makeup preferences remain available.

## Memory contract

Apply forward-only `supabase/migrations/202610280004_beauty_memory.sql` to the intended
development project. It adds `beauty_memories`, owner/history and full-text indexes,
`memories_read_own`, and the server-only `search_beauty_memories` function. There are no
Storage changes or new environment variables/dependencies. The developer confirmed applying
it to `zouvroynucstxqimygzd`; live ordinary-user checks passed.

Four categories: preferences, product experiences, routine/progress observations, events.
These are user-reported records, not AI skin results or verified product properties.
Records preserve source, source words, timestamps, certainty, sensitive flag and version.
Facts saved explicitly by a user are confirmed. Inferences and entries marked sensitive
start pending and private. Confirmation never converts an inference into a fact.
Edits to sensitive/inferred entries request confirmation again. Version checks reject stale
edits/confirmations. Identical repeated creates and normalized duplicate content do not
create additional records. Events require an explicit timezone-aware expiry; stable facts
do not expire arbitrarily. Expired entries remain visible for review but cannot enter AI context.

Every record defaults to private. Sharing requires **both** per-entry permission and a
session's **Use shared Beauty Memory** switch, initially off. Only confirmed, shared,
unexpired entries are eligible. The backend uses at most six literal keywords, bounded
full-text lookups, and at most eight distinct results. This is deliberately literal retrieval,
not a claim of semantic search. Only category/text/certainty/update time go to Gemini;
owner IDs, source quotes and the complete memory/history are not sent. Memories are
untrusted context, current requests take precedence, and inferences remain uncertain.
Saved makeup preference exclusions continue to be enforced by the existing planner.

The optional **Remember clearly stated finish preferences** switch in typed Chat accepts
only an entire utterance like `I prefer matte finishes.` from a small cosmetic finish
vocabulary. It saves the statement privately with exact source words, only after a successful
conversation response. Mixed/uncertain/health/product-identity sentences are not extracted.
Save failures are reported separately. This is a narrow automatic-save foundation, not
general conversational extraction. Voice does not automatically save memories, because
speech recognition ambiguity needs a separate review journey. Other facts can be added in
the review screen. Deleting stops future retrieval; already shared provider context cannot
be recalled. Start a fresh conversation after changing sharing/deleting context.

Routes (all authenticated; client-supplied user IDs rejected):

- `GET /v1/beauty-memories?q=&offset=` — owner search, pages of 50.
- `GET /v1/beauty-memories/{id}` — owner record.
- `PUT /v1/beauty-memories/{id}` — create/update; update requires `expected_version`.
- `POST /v1/beauty-memories/{id}/confirm` — reviewed confirmation with version/sharing choice.
- `DELETE /v1/beauty-memories/{id}` — delete own record.

Chat adds default-false `use_beauty_memory` and `remember_stable_preferences` flags.
Live voice's authenticated initial message adds default-false `use_beauty_memory`.
Memory is retrieved by the existing owner-bound planning tool, never arbitrary SQL or a
model-provided owner. No model memory-write tool exists.

## Education contract

The initial scope is two reviewed topics: sunscreen labels and salicylic acid. No new
ingredient catalogue, diagnosis, routine interaction checker, personalized treatment,
concentration schedule or guarantee is implemented. Existing makeup explanations remain
grounded in actual inventory metadata. These short lessons are an optional entry point,
not an academy or an unrestricted medical chatbot.

- `GET /v1/education/topics` — supported topics.
- `POST /v1/education/lesson` — topic, optional question, default-false `use_ai` and
  `use_beauty_memory`; AI requires explicit `beauty-education-v1` consent.

Reference mode makes no Gemini call and reads no memories. Optional Gemini selection uses
the same backend provider transport, a dedicated instruction and validated function schema.
The model chooses approved fact IDs; the server renders reviewed text and actual source URLs.
Unrecognized IDs, duplicate references, provider errors or malformed output return the
reference lesson with an explicit fallback status. Raw model medical prose is never shown.
Optional memory uses the same double opt-in, bounded relevance and minimized fields.
No routine, journal, image, skin analysis or product ingredient list is automatically retrieved.
The UI shows processing mode, limitations, caution, source URLs and review date.

Reviewed 2026-10-28 against primary references:

- [AAD: How to select a sunscreen](https://www.aad.org/public/everyday-care/sun-protection/shade-clothing-sunscreen/how-to-select-sunscreen).
- [MedlinePlus: Salicylic Acid Topical](https://medlineplus.gov/druginfo/meds/a607072.html).

Future topic expansion needs separate source review and tests; unsupported topics return 422.
No niacinamide claims or product ingredient assumptions were added.

## Validation commands

From the repository root:

```powershell
.\backend\.venv\Scripts\python.exe -m pytest backend/tests -q -p no:cacheprovider
.\backend\.venv\Scripts\python.exe -m pip check
.\backend\.venv\Scripts\python.exe -m ruff check backend/app backend/tests/test_beauty_memory.py backend/tests/test_education.py backend/scripts/check_memory_live.py
# Isolated local PostgreSQL, rollback-only:
& 'C:\Program Files\PostgreSQL\17\bin\psql.exe' -h 127.0.0.1 -p 55432 -U postgres -d postgres -v ON_ERROR_STOP=1 -f supabase/tests/beauty_memory.sql
```

From `backend`, after the remote migration and local test-account configuration:

```powershell
.\.venv\Scripts\python.exe -m scripts.check_memory_live
# Optional two small synthetic Gemini requests; consumes API credits:
.\.venv\Scripts\python.exe -m scripts.check_memory_live --gemini
```

The live script creates uniquely identified synthetic fixtures, tests real ordinary-user
RLS, denies direct writes/privileged RPC, checks authenticated API CRUD/confirmation/expiry,
re-logs in, and deletes/verifies only its own fixtures. Cleanup failures are raised.

From `frontend`:

```powershell
flutter analyze
flutter test --reporter compact
flutter build apk --debug --no-pub --dart-define-from-file=.env
flutter build web --no-pub --dart-define-from-file=.env
```

Actual counts/build results and platform limitations are recorded in `validation.md`.
Samsung walkthrough and iOS runtime are separate from these automated/live API checks.

## Community Wisdom

The configured DevRelay research tools were unavailable. No community result or consensus
is claimed; provider contracts, repository conventions and the primary references above
are the basis for this increment.
