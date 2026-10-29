# Contact form setup (Google Apps Script)

The website's `contact.html` is ready, but email delivery is **disabled until setup is complete**.

1. Open https://script.google.com and create a new standalone project.
2. Paste the contents of `contact-apps-script.gs` into `Code.gs` and save.
3. In **Project Settings → Script properties**, add `CONTACT_EMAIL` with the email address that should receive submissions. Do **not** put your private email in this public GitHub repository.
4. Select **Deploy → New deployment → Web app**. Choose **Execute as: Me** and **Who has access: Anyone**. Authorize the email-sending permissions.
5. Copy the deployed Web app URL ending in `/exec`.
6. Edit `contact.html`: replace `const ENDPOINT='';` with the deployed URL, then commit the change.
7. Send a test message and check the inbox and spam folder. Test from a different browser/device as well.

The form uses an HTML POST to a hidden iframe because Apps Script web apps are not generally suitable for cross-origin `fetch` from GitHub Pages. **Limitation:** the iframe load only confirms a response was received, not successful email delivery; the user-facing message intentionally says “submitted,” not “delivered.” For verified delivery status, use a dedicated form service or a backend with appropriate CORS handling.

Spam protection is basic (honeypot, minimum time, input limits, and per-address cooldown). A public endpoint can still be abused. Monitor quotas and disable the deployment if needed. Do not share the script deployment URL as a secret; it is public by design.

For people submitting privacy removal requests, verify the request before disclosing or deleting participant records.
