# YouCam contract checkpoint — 2026-10-25

Live verification now includes a failed task (`error_src_face_too_small`) and a successful
phone-selfie task. The production File API/src_file_id/ZIP-parser flow persisted overall score
92.25 and 13 concern/region entries across hd_wrinkle, hd_pore, hd_texture and hd_acne. Every
entry contains raw_score and ui_score; there were no parser warnings. This verifies the selected
scope for that run, not every optional provider field. Skin age remains excluded. No face image,
mask ZIP, signed asset URL or secret was copied into the repository.

Official sources inspected before writing the parser:

- https://docs.perfectcorp.com/reference/ai_skin_analysis/v2.1
- https://docs.perfectcorp.com/_bundle/reference/ai_skin_analysis.json
- https://docs.perfectcorp.com/reference/ai_skin_analysis/section/overview
- https://docs.perfectcorp.com/_bundle/reference/file.json

Implementation choices: request ZIP, upload using the File API, and analyze a fixed all-HD scope.
Supabase upload is a separate private staging step. The worker downloads those bytes and explicitly
uploads them to the provider's returned PUT destination. Supabase paths never become provider inputs.

The task status adapter accepts the two conflicting documented ZIP URL shapes. It does not guess
other response shapes. Asset URLs require HTTPS and an exact configured provider-owned host;
redirects and credentials in URLs are rejected, and bearer credentials are sent only to the API host.
Add a new asset hostname only after checking its ownership against a real response. Do not allow
arbitrary hosts, wildcard S3 domains, or user-provided URLs.

ZIP parsing reads only `skinanalysisResult/score_info.json` in memory. It never extracts mask files.
The normalization tests use hand-built fixtures based on documentation examples. Missing requested
concerns or score components produce warnings/nulls; malformed values and missing overall scores fail.
Unknown fields are not normalized. Region scores remain separate. No computed replacement score exists.

The worker maps documented running/success/error states and bounded retries for safe reads.
File uploads, invalid parameters/authentication, rate limits, download failures and task timeouts are
handled without retaining raw provider error bodies. Uncertain task creation is not automatically repeated.

Pending live verification: entitlement and credits for this action set; actual File API headers/host;
v2.1 task envelope; ZIP contents; overall-score availability for the selected scope; numeric semantics;
provider copy retention/deletion and current unit costs. Inspect these locally without logging signed URLs
or uploading fixtures containing real face data to Git.
