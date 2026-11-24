# Feature parity and release gate

Legend: Implemented = present in source; Simulated = exercised in the backend core tests; Pending = not verified or missing.

| Area | New edition | Verification / differences |
|---|---|---|
| Independent games, game codes, host ownership, single-use invitations, credits | Implemented | Simulated; tombstones preserve consumed credits |
| Admin directory, invitations, defaults, host disable/recovery, game management | Implemented | Authentication/invite core simulated; browser & all admin actions pending |
| One workbook, _ADMIN and per-game columns | Implemented | Real Sheets initialization and round-trip pending |
| Host workspace, tabs, search/filter, export, lifecycle | Implemented | Manual browser tests pending |
| Registration, PIN, hall/phone, instructions, remember session | Implemented | Core authentication and toggles simulated; field/UI coverage pending |
| Assassins circular assignment, shuffle, verify, digital elimination, reassignment, winner | Implemented | Core tests; shuffle/reactivate/no-first-elimination edge cases pending |
| Assassins late registration & action controls | Implemented | Simulated; at least three players as in migration 021 |
| Assassins feed | Implemented | Deliberate privacy change: codenames instead of public real names |
| Assassins reset/wipe, pause, lock | Implemented | Simulated |
| Mafia random roles, role visibility, investigation, digital elimination | Implemented | Simulated |
| Mafia vote threshold, expiration, retraction, role permissions, cooldown | Implemented | Simulated; real concurrent writes pending |
| Mafia automatic winner and reset | Implemented | Simulated citizen victory; other end cases pending |
| Host player edit/remove/reactivate, role reassignment | Implemented | Edge tests pending |
| Existing footer, Montserrat, responsive layout | Implemented | Shared site-footer files referenced; mobile/desktop rendering pending |
| Real time updates | Manual refresh | Apps Script is not Supabase Realtime; auto-refresh deliberately deferred to reduce quotas |
| Forms during background refresh | Manual refresh avoids background form overwrites | Explicit refresh can discard edits; draft persistence pending |
| Password/PIN handling and server session | Implemented | Salted keyed HMAC (not slow KDF), cache-based rate limit, persistent/global rate limit and security review pending |
| Per-game transaction locking | Script-wide lock | Simulated sequential conflict tests only; real concurrent requests and cross-sheet recovery pending |
| Google Apps Script CORS | Direct simple POST with redirect follow | Live verification pending; no working HTML Service fallback committed |
| Apps Script quotas and performance | Batch reads/writes | Real load test pending |
| Exact previous features | Partial parity | All remaining SQL migrations / legacy edge behaviors require exhaustive review; not certified complete |

Release gate: complete browser tests, live Apps Script transport, sheet round-trip/format/escaping, real concurrency, load testing, complete parity review, stronger auth/rate limit, recovery for partial multi-sheet writes, and user approval. Do not merge main yet.
