# 12ONE Games v2 — deployment and verification

This branch must not modify the original `assassins.html` and `mafia.html` or reuse their Google Apps Script backends.

## Architecture

- Host: `host.html`. Email account, owner-only game dashboard, credits and invitations.
- Assassins player link: `assassins2.html?game=CODE`.
- Mafia player link: `mafia2.html?game=CODE`.
- Supabase auth storage is distinct for host, each Assassins code, and each Mafia code.
- Original game pages remain untouched.

## Original sheet settings

Assassins: `master_lock`, `game_status`, `signup_enabled`, `dashboard_enabled`, `eliminate_enabled`, `signup_off_message`, `dashboard_off_message`, `eliminate_off_message`, `master_lock_message`, `last_updated`, `hall_field_enabled`, `hall_options`, `phone_field_enabled`, `instructions_enabled`, `instruction_verification_enabled`, `instructions_text`.

Mafia: `setupEnabled`, `dashboardEnabled`, `gameActive`, `mafiaCooldownHours`, `detectiveCooldownHours`, `citizenCooldownHours`, `citizenVotesRequired`, `voteExpirationMinutes`, `minActiveForGameEnd`, `allowMafiaInCitizenVotes`, `allowDetectiveInCitizenVotes`, `announcementMessage`, `hallOptions`, `mafiaInstructions`, `detectiveInstructions`, `citizenInstructions`, `hallFieldEnabled`.

Both games use the authenticated host account for administrative privileges. The former sheet passwords (`admin_password`, `reset_password`, `adminPassword`) are *not* copied to new tables. All privileged RPCs check game owner identity.

## Database installation order

Migrations 001–007 must already be installed. For testing, clone the database schema to a disposable Supabase staging project first.

1. `12one-games/sql/008_assassins_v2_public.sql`
2. `12one-games/sql/009_assassins_host_parity.sql`
3. `12one-games/sql/010_mafia_game.sql`
4. `12one-games/sql/011_settings_parity.sql`
5. `12one-games/sql/012_mafia_settings_parity.sql`
6. `12one-games/sql/013_player_recovery.sql`

**Never run test fixtures on the real Supabase project.** They are for disposable PostgreSQL CI only.

## Automated checks

GitHub Actions: `.github/workflows/12one-games-check.yml`. This parses the JavaScript and SQL, checks browser references and original settings, and runs the migrations and smoke tests on a fresh PostgreSQL 16 service.

## Required staging browser validation

- Create two host accounts and give each a credit. Confirm one host cannot read, update, or start another host's games.
- Create two Assassins games and two Mafia games. Confirm every registration, player list, feed, role, target, and vote stays in its own game.
- Assassins: register at least three players with real names; verify phone/hall/instruction settings; test target assignment, codename verification, instant elimination, pause, disabled messages, master lock, host player status, shuffle, elimination feed, and resets.
- Mafia: register players; choose 4-digit PINs; assign Mafia/detective/citizen roles; verify role-specific dashboards, cooldowns, votes, retractions, vote expiry, result banners, elimination, endgame threshold, host settings, player management, and resets.
- Reopen each game in the same browser; ensure host sign-in and other game player sessions have not been overwritten.
- Test lost-browser-session recovery on each game, including replacement recovery tokens, rejected old tokens, and new browser login. A one-time recovery-code function is now implemented and tested, and the Assassins player UI issues and accepts these codes. The Mafia recovery UI now issues, redeems, and renews private one-time recovery codes. Both player interfaces require staging-browser verification. Recovery tokens must remain private; knowing a codename alone does not authorize account access. Both games support generating a replacement recovery code from an active player session; replacement invalidates earlier codes.
- Test mobile layout and error states, network failures, and disabling registration while other games are active.

## Release gate

Do not merge into `main` until the staging checks pass and account recovery is resolved. Merge requires host approval.
