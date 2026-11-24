# Test results — development

Executed in an isolated JavaScript runtime against the production Code.gs dispatch/core, simulated data store, mocked spreadsheet ranges, and mocked fetch transport. No Google services or physical device browser tests were used.

- PASS admin and host authentication
- PASS invite expiry, revoke and single redemption
- PASS game creation, retry, ownership
- PASS Assassins registration, privacy, circular targets
- PASS Assassins verify, pause, idempotency, reassignment and winner
- PASS Assassins reset, settings and wipe
- PASS Mafia role assignment and privacy
- PASS Mafia investigations and cooldown
- PASS Mafia voting, permissions, retraction, expiry, threshold
- PASS Mafia reset and digital Mafia action
- PASS archive, restore, export, deletion and credits
- PASS session expiry and revocation
- PASS toggle lifecycle and late registrations
- 13 groups passed
- PASS workbook adapter mock: headers, round-trip, text escaping, nested JSON, wipe
- PASS browser API mock: POST body, redirects, credentials, endpoint validation, error envelopes

Frontend app.js and api.js syntax checked. Actual DOM rendering, real CORS/HTTP transport, Google Sheets operations, LockService contention, workbook permissions, deployment, and mobile tests remain pending. The committed Node test entrypoints use the same test bodies; the JavaScript isolate used assertion and browser shims. No live backend claimed.
