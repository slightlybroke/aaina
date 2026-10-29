# Gemini continuous Talk (Milestone 3 extension)

Digital vanity → Plan a makeup look now offers Chat and Talk. Existing typed conversation
and manual planning remain separate. Talk starts only after its own consent checkbox and
Start Talk, followed by OS microphone permission. Stop, leaving the screen, sign-out, or
backgrounding ends the session. There is no automatic reconnect or background recording.
The in-memory transcript remains on screen after Stop; a new session clears it. No app
audio/transcript files or database records are created. Google's API-account data terms apply.

## Contract and security

- Authenticated WebSocket `/v1/looks/live`; first JSON has `access_token` and
  `consent_version: gemini-live-v1`. Auth uses the same Supabase `/auth/v1/user` validation
  as existing routes. JWTs are not in URLs and are never forwarded to Google.
- Google connection and `GEMINI_API_KEY` stay server-side. Use WSS/HTTPS outside local debug.
  Start uvicorn with `--ws-max-size 65536` to bound inbound frames before application parsing.
- Client binary messages are PCM16 little-endian mono, 16 kHz; server binary messages are
  PCM16 mono, 24 kHz. Provider input/output transcription is rendered as separate roles.
  Provider interruption events discard queued playback. Transcript text can include generated
  words that had not played before an interruption; it is not a playback receipt.
- Only validated `plan_owned_look` calls are allowed. The authenticated backend identity owns
  every query; model-supplied IDs/SQL are rejected. The shared deterministic planner selects
  relevant metadata, excludes private notes, and returns recorded-product cards.
  It can choose/check recorded products for requested categories, not browse the full inventory
  or fetch arbitrary backend data. Talk instructions explicitly describe this access.
  Category matching is literal, with one narrow other↔others fallback when the exact category
  is empty and the alternate is not excluded. Exact populated categories win; no stored labels
  are changed. Applied fallback is disclosed in plan limitations.
- Replies are instructed to stay in English and ask for repetition instead of interpreting
  unclear speech/noise. Native-audio models do not support a languageCode lock; this is a
  model instruction, not deterministic ASR filtering. Automatic VAD uses low speech-onset/end
  sensitivity, 80 ms prefix padding and 600 ms silence. Device noise suppression/AEC remain
  enabled. These settings reduce false triggers but do not guarantee noise rejection.
- Spoken styling is model-generated and may be mistaken; recorded-product cards remain the
  inventory facts. Audio cannot be constrained to reference-only text in the same manner as
  the typed explanation validator. No medical or exact-shade-preview claim is made.
- Defaults: model `gemini-3.8-live`, 300 seconds/session; settings allow 30–600 seconds.
  One session/account/process, 10 tool calls/session, 3 calls/provider message, bounded frames
  and byte budgets. This is not a distributed production billing/quota solution.
- Stop independently closes recording, playback and transport, with bounded cleanup waits.
  Cleanup errors are shown. Delayed permission/start and interruption work are guarded so
  they cannot restart audio after Stop. Native audio sample logging is disabled.

## Platforms and checks

Uses `record` 7.1.2, `flutter_pcm_sound` 3.3.3 and `web_socket_channel` 3.0.3.
PCM playback is vendored under `frontend/third_party/flutter_pcm_sound` with its license
and `LOCAL_PATCH.md`: Android playback uses voice-communication/speech attributes rather
than upstream media/music attributes, matching the recorder's communication source/mode.
This addresses a concrete routing mismatch after the Samsung reported a speaker echo loop;
device acoustic performance still requires retesting. The microphone is not muted during
playback, so continuous double-talk/interruption remains available.
Android API 31+ explicitly selects the built-in communication speaker and clears the request
on cleanup. MODIFY_AUDIO_SETTINGS is declared for routing; microphone permission still needs
explicit user approval. Older Android relies on the recorder's legacy speakerphone path.
Android intentionally adds RECORD_AUDIO and an optional microphone feature. Still-camera
capture remains audio-disabled. No storage permission is added. iOS has a microphone purpose
string but cannot be built/tested on this Windows host. Web builds retain Chat; Talk is disabled
because the chosen PCM playback package does not support web. Bluetooth routing is not enabled
or verified. Echo cancellation depends on device hardware and requires physical acceptance.

`backend/scripts/check_live_audio.py` streams only the ignored synthetic WAV generated with
Windows System.Speech, not a person recording. Run from backend with
`.\.venv\Scripts\python.exe scripts/check_live_audio.py`; `--tool-test` separately checks Live
function calling against synthetic inventory. It sends no actual vanity/journal/skin data and
prints counts rather than audio, secrets or transcripts. These are provider protocol checks,
not microphone/speaker proof. See the dated validation report for actual results.

Official contracts inspected:
[Live capabilities](https://ai.google.dev/gemini-api/docs/live-api/capabilities),
[Live protocol](https://ai.google.dev/api/live),
[Google SDK implementation](https://github.com/googleapis/python-genai/blob/main/google/genai/live.py),
[record](https://pub.dev/packages/record),
[PCM playback](https://pub.dev/packages/flutter_pcm_sound),
[Google API terms](https://ai.google.dev/gemini-api/terms).

Physical acceptance: allow microphone only after Start, speak a non-private makeup request,
hear a reply and see both transcript roles, interrupt speech, request a plan from an owned
category, then Stop and background the app. Confirm microphone indicator ends and typed Chat
still works. No selfie or new YouCam analysis is involved.
