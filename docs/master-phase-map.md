# Master plan alignment (2026-10-28)

Earlier work used an expanded “Phase 3” with five milestones. Those names are historical;
they do not map one-to-one to the phases in the master brief re-supplied on 2026-10-28.

| Master phase | Repository implementation | Remaining scope / evidence |
| --- | --- | --- |
| 0–1: foundation / skin analysis | Auth, private upload, real YouCam scores/results/history | Platform/operational limits in validation report; do not repeat successful selfie calls merely as proof |
| 2: routines/history | Routines, immutable revisions, check-ins, adherence/streaks, journal, progress | Existing platform acceptance limitations remain |
| 3: Vanity | Expanded Phase 3 milestone 1 | Core CRUD/isolation passed; optional inventory product images not implemented |
| 4: conversational makeup | Expanded milestones 2–3: deterministic planner, Gemini Chat/Live Talk, validated owned-product tools; now explicit saved-preference context | New preference editor/native Talk-context walkthrough pending; broad free-form memory is Phase 6, not silently invented here |
| 5: VTO/discovery | Expanded milestones 4–5: actual demo-image lip/Look tasks, private jobs/previews, reviewed six-record catalogue | Native checks pending; full-hour wall-clock retention not observed; global completion notifications not implemented |
| 6: Beauty Memory/education | Private memory CRUD/review/confirmation/expiry, opt-in relevant Chat/Talk context, narrow typed finish-preference capture; two source-reviewed education topics with optional Gemini fact selection | Native walkthrough pending; automatic extraction deliberately limited to exact finish utterances; no voice auto-save, broad ingredient library or routine interaction checker. See phase6-memory-education.md |
| 7: weekly reports/polish | Deterministic local-week reports, restart-safe worker, private unread inbox, dashboard shortcut, clear missing-data/retry states | Native walkthrough, deployed worker supervision and natural weekly rollover pending. Global VTO notifications and broader visual polish are not included; see phase7-weekly-reports.md |
| 8: MCP | Shared services remain adapter-compatible | No MCP adapter implemented |

Use `validation.md` for passed versus pending checks; an implemented row is not universal
device/live acceptance. The developer explicitly deferred USB/native checks while continuing
implementation. The confirmed product name is aaina (lowercase). APP_NAME defaults to aaina.

Repository search found no independently maintained event schedule. The master brief's
November 2, 2026 deadline remains a developer-supplied planning target, not a freshly verified
official event deadline. This change does not assert a deadline extension or new event facts.
