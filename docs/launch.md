# aaina public release

The release has three destinations: the GitHub source repository, an HTTPS web app,
and a signed Android APK attached to a GitHub Release. The Android application ID
is `com.overfitlabs.aaina`. Builds using the old example ID are separate installs.
Use the same signing key and increasing build numbers for APK updates.

## Deploy the backend

1. Create or designate the production Supabase project. Apply the SQL migrations
   in filename order and verify the private buckets and ordinary-user isolation.
   Include the account deletion request migration before enabling the Account page.
2. Configure the backend environment from `backend/.env.example` on the host.
   Set the exact web origin in `CORS_ORIGINS` and review the provider account,
   entitlements, enabled features and usage limits. Keep provider and service-role
   keys on the host.
3. Run `docker compose up -d --build` on a container host. The API binds to host
   loopback. Point the host's TLS reverse proxy at that port, enable WebSocket
   upgrades for Talk, and test the externally reachable HTTPS endpoint. Each
   worker has its own process and restart policy.
4. Alert on API availability, worker errors, stale queues and overdue image
   cleanup. The API health check only proves the API process answers. Exercise
   database, provider and worker readiness with controlled staging accounts and
   a consented test image before routing real users to it.
5. Configure Supabase email delivery, sender identity, confirmation and reset
   templates. Allow the exact web app base URL and its `?recovery=1` variant,
   plus `aaina://auth/confirm` and `aaina://auth/recovery` for Android. Keep the
   hosted app's base path and Supabase allowlist in sync. Test links on the same
   device and browser that requested them because the SDK uses PKCE.

## Build and publish

1. Create the GitHub Actions environment named `release`. Set
   `AAINA_SUPABASE_URL`, `AAINA_SUPABASE_PUBLISHABLE_KEY` and
   `AAINA_API_BASE_URL` as environment variables. Set `AAINA_WEB_BASE` to `/`
   for a root domain or `/aaina/` for a GitHub Pages project site.
2. Supply an owner-controlled Android keystore. Store its base64 encoding and
   credentials in the environment secrets `AAINA_KEYSTORE`, `AAINA_STORE_PASSWORD`,
   `AAINA_KEY_ALIAS` and `AAINA_KEY_PASSWORD`. Keep an offline backup of the key.
3. Run **Build release candidates** on the reviewed Git ref. Download its web
   bundle and signed APK. Serve the web bundle from its configured HTTPS base
   path. Verify CORS and auth redirects from the public origin.
4. Install the signed APK on a physical phone. Also test an upgrade signed with
   the same key. Walk the checklist below in the web app and APK against the
   release backend, then publish the verified APK and checksum in GitHub Releases.
   Link the live web app and GitHub Release from the README and portfolio.

## Acceptance checklist

- Fresh account: welcome, registration, email confirmation, sign-in, sign-out,
  password recovery, expired or already-used links, and sign-in with the new password.
- First and returning sessions: create a routine without a photo, check off steps,
  create, edit and delete a journal entry, and verify persistence after signing back in.
- Photo flows: decline consent, deny permissions, retry photo selection, resume a
  pending scan after closing the app, view saved results, and verify image cleanup
  after a worker restart. Verify an ambiguous paid submission creates no automatic retry.
- Beauty flows: add and edit Vanity products, plan an owned-product look, exercise
  Chat and Talk permissions and recovery, try on a supported look, save or remove
  memory, and open the Weekly Beauty Brief after a populated weekly rollover.
- Account and operations: prove two users cannot read each other's data or deletion
  request status. Submit and complete a deletion request for a disposable account.
  Observe worker recovery, cleanup alerts, and provider usage limits in staging.

## Process account deletion requests

The app records a private, idempotent request for the signed-in account. It displays
the pending state until an operator completes the request. Establish who reviews
requests, how often, and how users are notified before accepting real accounts.

During a controlled maintenance window, stop API writes and drain and stop
photo-processing workers so they cannot create new uploads or previews during
cleanup. Inspect the requested user's skin and try-on job rows, remove their
objects from the respective private Storage buckets, and verify absence in
both buckets before deleting the Supabase Auth user. The foreign keys then
remove the associated app records and request row. Verify deletion, return the
service to operation and record a minimal, private completion receipt.

Review provider-side retention and applicable deletion processes separately.
Publish privacy and support information with verified operator and provider
details before opening registration to the public.
