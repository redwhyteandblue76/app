/**
 * Contact form backend for app.12one.page
 * 1. Set Script Property CONTACT_EMAIL to your receiving address.
 * 2. Deploy as Web app: Execute as Me; access Anyone.
 * 3. Paste the resulting /exec URL into contact.html's ENDPOINT.
 * This endpoint is public. Honeypot and per-email throttling reduce, but cannot eliminate, spam.
 */
function doPost(e) {
  try {
    const p = (e && e.parameter) || {};
    const name = String(p.name || '').trim();
    const email = String(p.email || '').trim();
    const subject = String(p.subject || '').trim();
    const message = String(p.message || '').trim();
    const started = Number(p.formStarted || 0);
    if (p.website) return response_('Received');
    if (!name || name.length > 100 || !email || email.length > 254 ||
        !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ||
        !['General Inquiry','Game Feedback','Bug Report','Copyright / Permissions','Privacy / Data Removal','Other'].includes(subject) ||
        !message || message.length > 5000) return response_('Invalid submission');
    if (!started || Date.now() - started < 2500 || Date.now() - started > 86400000) return response_('Invalid submission');
    const recipient = PropertiesService.getScriptProperties().getProperty('CONTACT_EMAIL');
    if (!recipient) throw new Error('CONTACT_EMAIL is not configured');
    // This limits repeated messages from the same claimed email, not malicious spoofing.
    const key = 'contact_' + Utilities.base64EncodeWebSafe(
      Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,email.toLowerCase())).slice(0,40);
    const cache = CacheService.getScriptCache();
    if (cache.get(key)) return response_('Please wait before sending another message');
    cache.put(key,'1',60);
    MailApp.sendEmail({
      to: recipient,
      subject: '[12one Contact] ' + subject,
      body: 'Name: ' + name + '\nEmail: ' + email + '\nSubject: ' + subject + '\n\n' + message,
      replyTo: email,
      name: '12one Contact Form'
    });
    return response_('Message sent');
  } catch (err) {
    console.error(err);
    return response_('Unable to send message');
  }
}
function response_(text) {
  return HtmlService.createHtmlOutput('<!doctype html><html><body><p>' +
    String(text).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]}) +
    '</p></body></html>');
}
