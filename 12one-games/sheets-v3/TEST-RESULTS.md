# Test results — development

Executed in a JavaScript runtime against the production Code.gs dispatch/core with a simulated data store. Test hash and IDs are deterministic; Google services are not simulated by these core tests.

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

Frontend app.js and api.js syntax checked. Actual DOM rendering, HTTP transport, Google Sheets operations, LockService contention, workbook permissions, deployment, and mobile tests are pending. No live backend claimed.
