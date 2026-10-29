# Phase 3 Milestone 3 — Gemini look conversation

Gemini interprets natural-language look requests, asks necessary questions and selects factual
explanation references. The existing deterministic planner still chooses owned products and
builds product facts. No VTO, discovery, Beauty Memory, MCP, chat database or new migration.

## Configuration and API choice

Backend-only, ignored `.env`:

```dotenv
GEMINI_API_KEY=configure-locally-never-in-chat
GEMINI_MODEL=gemini-3.5-flash-lite
```

The key is optional for the rest of the app, stored as Pydantic `SecretStr` and sent only in
the `x-goog-api-key` header to the fixed Google endpoint. It never goes into Flutter, query
strings, prompts, logs or responses. Model names are restricted to a safe identifier pattern.
No new Python/Flutter package is needed: the adapter uses the established HTTPX client and
documented REST `v1beta/models/{model}:generateContent` API.

The official SDK/API examples, function declarations, signatures, structured output and
model capabilities were reviewed before implementation. Initial default Gemini 3.8 Flash
had readable model metadata but generation timed out and a minimal request returned 503
UNAVAILABLE. The explicit final default is **Gemini 3.5 Flash-Lite**, whose model access,
generation and actual function-call flows passed. There is no automatic runtime model switch.
An explicit `GEMINI_MODEL` setting overrides the default; developers must verify its access
and capability. The 3.8 adapter option uses its documented LOW thinking level.
Restart the backend after changing its environment; keys/models are loaded at process startup.

## Conversation route and tool boundary

`POST /v1/looks/conversation` reuses verified Supabase bearer authentication. Body:

```json
{
  "consent_version": "gemini-look-v1",
  "messages": [{"role": "user", "text": "Help me choose a look for dinner"}]
}
```

Messages allow only alternating `user`/`assistant` text, starting/ending with user; maximum
10 messages, 1200 characters each (at most five user turns). No client system messages,
tool results, trusted IDs, SQL, provider options or unknown fields are accepted. Client
history and inventory labels are always untrusted content, never authorization evidence.

At most two model calls per request, each bounded to 35 seconds/2048 output tokens, with a
90-second overall service deadline. Flutter allows 110 seconds including Auth/network time.
There are no automatic paid retries; explicit retry can consume credits again. These bounds
are per request, not a distributed production billing/rate-limit system.

1. Force one of `ask_clarification` or `plan_owned_look`. Unknown/parallel/malformed calls,
   blocked/truncated results and invalid arguments are rejected. Look arguments are validated
   against the existing `LookRequest`; user IDs and arbitrary database actions are not tools.
2. The backend queries only requested, nonexcluded categories using the **verified** caller.
   It selects needed metadata, excluding notes, health records and timestamps. Pagination
   handles a lower database row cap. At most 20 candidates per role (12 roles maximum) are
   considered; a 21st row detects truncation. A visible limitation directs large inventories
   to the manual planner for complete retrieval. No claim of exhaustive matching under a cap.
3. Run the independent `plan_look` service. Only selected products, factual reasons and gaps
   reach Gemini's explanation step; no unselected candidate list or owner ID is forwarded.
   Original model content/signatures and optional call ID are preserved for the tool roundtrip.
4. Force `explain_owned_plan` with constrained product IDs/reason indexes. Every reference must
   identify a selected owned product and an existing factual reason. Duplicate/foreign IDs,
   bool/noninteger/out-of-range indexes and missing explanations are rejected. The backend
   renders the referenced reasons rather than accepting newly generated product claims.
   A failed explanation step returns the deterministic plan with a visible fallback status.

Gemini-authored clarifying questions are bounded free text, not verified product facts.
Opening messages, product facts and reasons are server-rendered. This deliberately limits
free-form prose: no ungrounded shade, brand, wear-performance, skin-tone or medical claim is
accepted as product metadata. Outfit color preferences require clarification rather than an
automatic assumption about matching versus contrast. Interpreted fields are reviewable in UI.
Model interpretation can still be mistaken; users can correct it in a follow-up or use the
manual planner. This is look planning, not unrestricted beauty/health chat.

Missing key => 503 with manual-planner guidance. Provider HTTP/quota/configuration and transport
errors => redacted 503; unsupported/malformed model tool output => 502. Provider bodies, keys,
thought text and signatures are never returned. No security policies are relaxed.

## Consent, privacy and Flutter

Open Digital vanity → Plan a makeup look → **Talk through a look with Gemini**. Explicit
checkbox consent is required before sending. The server also requires the exact consent
version. Conversation text and relevant selected makeup labels may be sent to Google. No
photos, YouCam results, journal notes, routine history or stored private notes are queried
for the model. The UI provides clarification/follow-up, loading/error/explicit retry,
interpreted-preference review, factual product cards, fallback labels and a manual exit.
Session-bound routing hides the screen on account changes.

History is held only in this screen's memory, cleared by new-conversation/revoking consent/
leaving the screen. No app-side transcript persistence, user preference memory or server-side
chat cache is created. This is **not a promise that Google retains nothing**: its account-tier
data handling/retention terms apply. Review the official terms before using real personal
information, particularly unpaid services. Tests and live acceptance send synthetic content.

## Checks

From root:

```powershell
.\backend\.venv\Scripts\python.exe -m pytest backend/tests -q -p no:cacheprovider --basetemp=backend/.pytest-tmp-gemini
.\backend\.venv\Scripts\python.exe -m ruff check backend/app backend/tests backend/scripts
.\backend\.venv\Scripts\python.exe -m pip check
cd frontend
flutter analyze --no-pub
flutter test --no-pub --timeout 60s
flutter build apk --debug --no-pub --dart-define-from-file=.env
flutter build web --no-pub --dart-define-from-file=.env
```

From `backend/`, after configuring the key, provider-only synthetic check:

```powershell
.\.venv\Scripts\python.exe scripts/check_gemini_live.py
```

Full Auth/database/provider synthetic check (may consume credits):

```powershell
.\.venv\Scripts\python.exe -m scripts.check_gemini_owned_live
```

The full check pins the existing dev hostname, uses two ordinary password logins, inserts one
clearly synthetic product with an isolated generated category and invokes the actual route.
A restrictive adapter refuses any category outside that exact fixture, preventing real user
inventory from reaching Gemini during the check. The owner gets the fixture; the other user
gets none. Cleanup targets only a successfully created fixture UUID/owner; inventory baselines
must match afterward. It does not upload images, call YouCam or weaken RLS. Mocked tests
remain separate from these live checks and from manual device acceptance.

Primary references reviewed:

- [Official REST generation reference](https://ai.google.dev/api/generate-content)
- [Function calling and SDK examples](https://ai.google.dev/gemini-api/docs/function-calling)
- [Structured outputs](https://ai.google.dev/gemini-api/docs/structured-output)
- [Gemini 3.5 Flash-Lite capabilities](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite)
- [Gemini 3.8 Flash capabilities](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash)
- [API key handling](https://ai.google.dev/gemini-api/docs/api-key)
- [Google API data terms](https://ai.google.dev/gemini-api/terms)

Actual results, failures and platform gaps are recorded in `docs/validation.md`.
## Continuous voice extension

The original typed Chat contract above remains. A separate Talk screen now uses Gemini Live
audio, its own consent and bounded session. See [Live voice](phase3-live-voice.md) for transport,
permissions, data handling and the distinct limits of spoken model output. Actual execution
results and remaining native acceptance checks are recorded in `validation.md`.
