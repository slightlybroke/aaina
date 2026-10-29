# Master Phase 4 — explicit preference context foundation

Inspection found owned-product planning, explanations and Gemini Chat/Talk already implemented
under expanded Phase 3 milestones 2–3. Missing was persistent profile context. This slice adds
only the explicit settings needed for that capability, not the full Phase 6 Beauty Memory UI
or automatic conversation extraction. See `master-phase-map.md` for numbering and gaps.

## User journey

Digital vanity → Plan a makeup look → **Saved makeup preferences**. Optional preferred shade
label, preferred finish label and up to 12 excluded categories. Save is explicit confirmation,
not an inferred fact. Source/timestamp are shown; users can edit/delete. Stable preferences
have no arbitrary expiry. No profession, skin condition, allergy, journal, routine notes or
free-form life history fields are added. This is not full onboarding.

Chat and Talk each have **Use saved makeup preferences**, off by default. Existing requests
retain their behavior when it is off, including no preference-table lookup. With it on, the
authenticated backend fetches only the three fields for the verified owner. Gemini receives
those bounded labels as untrusted contextual data, never user IDs or all profile/history rows.
The ordinary owned-inventory planner still chooses products and supplies factual reasons.

Saved shade/finish fill missing planning fields; nonempty current request values win. Saved
exclusions are unioned with current exclusions, never silently dropped. Switch saved context
off for a plan without those exclusions. Combined exclusions above 12 produce a validation
error instead of silently truncating constraints. The actual fields applied as defaults are
shown with the plan; if Gemini already included the same label, it is not falsely attributed
as a separately applied backend default. Existing literal-label/category and styling limits
remain; no scientific suitability/color-harmony claim is introduced.

Chat loads relevant settings per opted-in request. The UI locks its switch once messages exist
until a new conversation. Talk reads one snapshot at start; Stop/start reloads after edits or
deletion. Prior model context cannot be recalled after it has been sent: start a fresh session
to avoid retained conversational references. Google's processing terms still apply. No chat,
audio, automatic inference or sensitive memory write tool is added. Models cannot mutate settings.

## Schema / service / routes

Forward-only migration `202610280003_makeup_preferences.sql`: one owner-keyed table with
labels, exclusions, explicit_profile provenance, UTC created/updated timestamps and owner-read
RLS. Authenticated clients cannot mutate directly; anonymous access denied. Service-role key
remains server-side. Table foreign key cascades on account deletion. Repeated PUT updates the
same row; no duplicate fact records. Minimal settings use last-save-wins, not an audit history.

- `GET /v1/makeup-preferences`: own values plus source/updated_at; unsaved returns empty defaults.
- `PUT /v1/makeup-preferences`: complete validated settings replacement, no user ID accepted.
- `DELETE /v1/makeup-preferences`: idempotently remove own settings. UI asks before deletion.
- Optional `use_saved_preferences` in the existing conversation body and Live first hello.
  No new Gemini endpoint, model or credentials; existing provider consent is still required.

Shared `PreferenceService`, context minimization and precedence helpers are backend functions.
Existing FastAPI Auth chooses identity. Gemini-generated IDs/SQL/foreign profile lookups are
never accepted. Text and Live tools invoke the same deterministic owned-product service.
No new dependency/environment variable is required. Apply migration before opting in; ordinary
off-by-default conversations still work if the new table is unavailable.

## Validation commands

From root run existing Ruff/backend/Flutter checks. Local rolled-back RLS harness is
`supabase/tests/makeup_preferences.sql`; it does not replace real ordinary-token checks.
From backend:

```powershell
.\.venv\Scripts\python.exe scripts/check_preferences_live.py
# Optional actual Gemini conversation, restricted to synthetic profile/product fixtures:
.\.venv\Scripts\python.exe scripts/check_preferences_live.py --gemini
```

The live script targets only confirmed dev project zouvroynucstxqimygzd and requires both
dedicated test profiles to be empty before temporary writes. It validates ordinary-token RLS,
Auth routes, fresh-login persistence and deletion, then removes only its fixtures. The optional
provider test creates one exact synthetic inventory category and refuses unrelated retrieval;
no real user history is sent. API credits may be consumed. Actual results are in validation.md.

Full Phase 6 memory policy remains future work: eligible automatic facts versus ambiguous/
sensitive proposals, product experiences, expiring events, provenance per memory and broader
review/search. This slice provides explicit stable preferences only. Weekly reports, education,
MCP and new provider/image calls remain outside this change.
