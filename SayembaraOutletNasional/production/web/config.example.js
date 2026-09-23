/* ============================================================================
 *  Sayembara Outlet Nasional — frontend config
 *  Copy this file to `config.js` and fill in your Supabase project values.
 *  (config.js is git-ignored; only the anon key belongs here — never the
 *   service_role key, which stays server-side.)
 * ========================================================================== */
window.APP_CONFIG = {
  SUPABASE_URL: 'https://YOUR-PROJECT-REF.supabase.co',
  SUPABASE_ANON_KEY: 'YOUR-PUBLIC-ANON-KEY',
  // Depo accounts are Supabase Auth users. If you register them with an email
  // like `DPJKT1@sayembara.internal`, the login page can append this domain so
  // sales just type the depo code. Set '' to require full email.
  DEPO_EMAIL_DOMAIN: 'sayembara.internal',
  // Official company WhatsApp Business number (digits, no '+').
  WA_BUSINESS: '628123456789',
  // Base URL where this site is hosted (used to build registration links).
  // Leave '' to auto-derive from window.location.
  PUBLIC_BASE_URL: ''
};
