# 12one Games — Google Sheets Edition (separate from Supabase)

This branch adds **four new GitHub Pages entrypoints** without changing existing Supabase pages:

- `assassins3.html` — Assassins player entrypoint.
- `mafia3.html` — Mafia player entrypoint.
- `host3.html` — host entrypoint.
- `admin3.html` — administrator entrypoint.

All four use `12one-games/sheets-launcher.js`. These pages launch the **actual interactive Google Apps Script HTML Service pages**; they are **not** standalone Apps Script clients. This is required because Apps Script's `google.script.run` API is only available inside pages served by Apps Script, not from GitHub Pages.

## Setup

1. Follow the installation README included in `12one-games-sheets-edition.zip` (provided separately), creating a **private** Google Sheets workbook.
2. Copy `Code.gs`, `Admin.html`, `Host.html`, `Player.html`, `Client.html`, and `Styles.html` into the spreadsheet-bound Apps Script project.
3. Deploy its web app with access appropriate for your players. Copy the `https://script.google.com/macros/s/.../exec` URL.
4. Edit `12one-games/sheets-launcher.js` in this branch to set `APPS_SCRIPT_WEB_APP_URL` to that URL. You can also temporarily enter the URL in any launcher's **Backend setup** section, which saves it only for that browser.
5. Merge this branch when ready to expose the four new URLs. Existing Supabase host/player URLs are unaffected.

**Security:** never include admin passwords, host keys, or player PINs in the GitHub repository. The private Google workbook and Apps Script enforce access rules.

**Scope:** This edition is still a prototype and does **not** yet provide complete feature parity with Supabase games. Test with disposable games. Do not announce the new edition as ready for player traffic until backend functions and deployment have been tested.

**Known Apps Script template correction:** in `Player.html`, the game-code template variable must match `Code.gs`. If Code.gs sets `t.initialCode`, use `<?= initialCode ?>` in Player.html (rather than `<?= code ?>`). The bundled initial prototype may need this correction before deployment.
