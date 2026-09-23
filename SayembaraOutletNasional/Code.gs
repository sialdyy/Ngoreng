/**
 * ============================================================================
 *  SAYEMBARA OUTLET NASIONAL — Google Apps Script Web App
 * ============================================================================
 *  Backend controller. Google Sheets is used as a prototype database.
 *
 *  Sheets:
 *    OUTLET_MASTER      — master outlet data (source of truth, per-sales)
 *    TOKEN_MAP          — secure random tokens -> outlet_id mapping
 *    SUBMISSION_LOG     — raw outlet submissions
 *    VALIDATION_RESULT  — output of the validation pipeline
 *    AUDIT_LOG          — auditable trail of sensitive actions
 *
 *  Routing (doGet):
 *    ?page=sales        — internal Sales Portal (mobile-friendly)
 *    ?page=dashboard    — corporate dashboard + leaderboard
 *    ?page=admin        — admin utilities + MOCK WhatsApp webhook simulator
 *    ?t={token}         — public Outlet Registration (token resolves outlet)
 *    (default)          — landing router
 *
 *  SECURITY NOTES
 *    - Tokens are cryptographically random, expirable and auditable.
 *    - No phone / NPWP / outlet_id ever placed in a URL.
 *    - All HTML output is escaped server-side and client-side.
 *    - NPWP and phone are masked on dashboards.
 *    - Simple rate limiting + audit log on sensitive endpoints.
 * ============================================================================
 */

/* --------------------------------------------------------------------------
 *  CONFIG
 * ------------------------------------------------------------------------ */
var CONFIG = {
  APP_TITLE: 'Sayembara Outlet Nasional',
  TOKEN_TTL_HOURS: 72,              // registration link lifetime
  TOKEN_BYTES: 32,                  // 256-bit token entropy
  // Official company WhatsApp Business number (E.164 digits, no '+').
  WA_BUSINESS_NUMBER: '628000000000',
  RATE_LIMIT_MAX: 20,               // max actions per window per actor
  RATE_LIMIT_WINDOW_MS: 60 * 1000,  // 1 minute window
  // Risk scoring weights (rule-based anomaly detection)
  RISK: {
    PHONE_MULTI_OUTLET: 35,
    NPWP_MULTI_OUTLET: 35,
    VELOCITY: 20,
    SALES_DEPO_MISMATCH: 25,
    REPEATED_PATTERN: 15
  },
  VELOCITY_WINDOW_MS: 5 * 60 * 1000, // 5 min
  VELOCITY_THRESHOLD: 5              // >5 submissions from same sales in window
};

var SHEETS = {
  OUTLET_MASTER: 'OUTLET_MASTER',
  TOKEN_MAP: 'TOKEN_MAP',
  SUBMISSION_LOG: 'SUBMISSION_LOG',
  VALIDATION_RESULT: 'VALIDATION_RESULT',
  AUDIT_LOG: 'AUDIT_LOG'
};

var HEADERS = {
  OUTLET_MASTER: ['outlet_id', 'outlet_name', 'kode_toko', 'depo', 'area',
    'sales_id', 'salesman', 'ass', 'bm', 'rbm',
    'wa_status', 'npwp_status', 'existing_npwp', 'eligible'],
  TOKEN_MAP: ['token', 'outlet_id', 'sales_id', 'created_at', 'expired_at', 'status'],
  SUBMISSION_LOG: ['submission_id', 'token', 'outlet_id', 'sales_id',
    'phone_raw', 'phone_normalized', 'npwp_raw', 'npwp_normalized',
    'consent', 'submitted_at', 'phone_verified',
    'npwp_official_status', 'overall_status', 'risk_score', 'risk_reason'],
  VALIDATION_RESULT: ['submission_id', 'outlet_id', 'phone_valid', 'npwp_valid',
    'dup_phone', 'dup_npwp', 'outlet_match', 'risk_score', 'risk_reason',
    'overall_status', 'evaluated_at'],
  AUDIT_LOG: ['timestamp', 'actor', 'action', 'detail', 'ip_hint']
};

var STATUS = { VERIFIED: 'VERIFIED', REVIEW: 'REVIEW', REJECTED: 'REJECTED' };
var NPWP_OFFICIAL = {
  PENDING: 'PENDING_OFFICIAL_VALIDATION',
  VERIFIED: 'DJP_VERIFIED',
  INVALID: 'DJP_INVALID'
};

/* --------------------------------------------------------------------------
 *  ROUTING
 * ------------------------------------------------------------------------ */
function doGet(e) {
  e = e || {};
  var params = e.parameter || {};

  // Public registration path — token present.
  if (params.t) {
    return renderPage('Register', { token: params.t });
  }

  var page = (params.page || 'sales').toLowerCase();
  switch (page) {
    case 'dashboard': return renderPage('Dashboard', {});
    case 'admin':     return renderPage('Admin', {});
    case 'sales':
    default:          return renderPage('Sales', {});
  }
}

/**
 * POST endpoint. Used as a placeholder webhook receiver for the
 * WhatsApp Business Platform and as a generic JSON action channel.
 */
function doPost(e) {
  try {
    var body = (e && e.postData && e.postData.contents) ? e.postData.contents : '{}';
    var payload = JSON.parse(body);
    if (payload && payload.object === 'whatsapp_business_account') {
      return jsonOut(handleWhatsAppWebhook(payload, false));
    }
    return jsonOut({ ok: false, error: 'Unrecognized payload' });
  } catch (err) {
    return jsonOut({ ok: false, error: String(err) });
  }
}

function renderPage(file, props) {
  var t = HtmlService.createTemplateFromFile(file);
  t.props = props || {};
  t.appTitle = CONFIG.APP_TITLE;
  return t.evaluate()
    .setTitle(CONFIG.APP_TITLE)
    .addMetaTag('viewport', 'width=device-width, initial-scale=1')
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}

/** Server-side include for Styles.html / Scripts.html partials. */
function include(filename) {
  return HtmlService.createHtmlOutputFromFile(filename).getContent();
}

function getWebAppUrl() {
  return ScriptApp.getService().getUrl();
}

function jsonOut(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

/* --------------------------------------------------------------------------
 *  SHEET HELPERS
 * ------------------------------------------------------------------------ */
function getSS() {
  // Bound to the container spreadsheet when deployed as a bound script.
  // Falls back to a property-stored spreadsheet id for standalone scripts.
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  if (ss) return ss;
  var id = PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID');
  if (id) return SpreadsheetApp.openById(id);
  throw new Error('No spreadsheet bound. Run setup() or set SPREADSHEET_ID.');
}

function getSheet(name) {
  var ss = getSS();
  var sh = ss.getSheetByName(name);
  if (!sh) {
    sh = ss.insertSheet(name);
    sh.appendRow(HEADERS[name]);
    sh.setFrozenRows(1);
  }
  return sh;
}

/** Read a whole sheet into an array of plain objects keyed by header. */
function readSheet(name) {
  var sh = getSheet(name);
  var values = sh.getDataRange().getValues();
  if (values.length < 2) return [];
  var head = values[0];
  var out = [];
  for (var r = 1; r < values.length; r++) {
    var row = values[r];
    var obj = { _row: r + 1 };
    for (var c = 0; c < head.length; c++) obj[head[c]] = row[c];
    out.push(obj);
  }
  return out;
}

function appendRow(name, obj) {
  var sh = getSheet(name);
  var head = HEADERS[name];
  var row = head.map(function (h) {
    return (obj[h] === undefined || obj[h] === null) ? '' : obj[h];
  });
  sh.appendRow(row);
}

function updateRow(name, rowIndex, obj) {
  var sh = getSheet(name);
  var head = HEADERS[name];
  var existing = sh.getRange(rowIndex, 1, 1, head.length).getValues()[0];
  var row = head.map(function (h, i) {
    return (obj[h] === undefined) ? existing[i] : obj[h];
  });
  sh.getRange(rowIndex, 1, 1, head.length).setValues([row]);
}

/* --------------------------------------------------------------------------
 *  IDENTITY / SESSION
 * ------------------------------------------------------------------------ */
/**
 * Current logged-in user (internal). In production, map the Google account
 * to a sales_id via a directory. Here we derive a deterministic sales_id
 * and allow ScriptProperties override for demo purposes.
 */
function getCurrentSales() {
  var email = '';
  try { email = Session.getActiveUser().getEmail() || ''; } catch (e) {}
  var override = PropertiesService.getScriptProperties().getProperty('DEMO_SALES_ID');
  var salesId = override || emailToSalesId(email);
  return { email: email, sales_id: salesId };
}

function emailToSalesId(email) {
  if (!email) return 'SLS-DEMO';
  // Deterministic short id from email — demo mapping only.
  var digest = Utilities.computeDigest(
    Utilities.DigestAlgorithm.SHA_256, email, Utilities.Charset.UTF_8);
  var hex = digest.slice(0, 3).map(function (b) {
    return ('0' + (b & 0xff).toString(16)).slice(-2);
  }).join('');
  return 'SLS-' + hex.toUpperCase();
}

/* --------------------------------------------------------------------------
 *  RATE LIMITING + AUDIT
 * ------------------------------------------------------------------------ */
function rateLimit(actor, bucket) {
  var cache = CacheService.getScriptCache();
  var key = 'rl_' + bucket + '_' + actor;
  var raw = cache.get(key);
  var count = raw ? parseInt(raw, 10) : 0;
  if (count >= CONFIG.RATE_LIMIT_MAX) {
    audit(actor, 'RATE_LIMITED', bucket);
    throw new Error('Rate limit exceeded. Please slow down and retry shortly.');
  }
  cache.put(key, String(count + 1), Math.ceil(CONFIG.RATE_LIMIT_WINDOW_MS / 1000));
}

function audit(actor, action, detail, ipHint) {
  try {
    appendRow(SHEETS.AUDIT_LOG, {
      timestamp: new Date().toISOString(),
      actor: actor || 'anon',
      action: action,
      detail: typeof detail === 'string' ? detail : JSON.stringify(detail || ''),
      ip_hint: ipHint || ''
    });
  } catch (e) { /* never let audit break the flow */ }
}

/* --------------------------------------------------------------------------
 *  SALES PORTAL — API
 * ------------------------------------------------------------------------ */
/**
 * Search outlets belonging to the logged-in sales only.
 * @param {string} query  outlet_id or name fragment (case-insensitive)
 */
function api_searchOutlets(query) {
  var sales = getCurrentSales();
  rateLimit(sales.sales_id, 'search');
  var q = String(query || '').trim().toLowerCase();
  var rows = readSheet(SHEETS.OUTLET_MASTER).filter(function (o) {
    return String(o.sales_id) === sales.sales_id;
  });
  var matched = rows.filter(function (o) {
    if (!q) return true;
    return String(o.outlet_id).toLowerCase().indexOf(q) !== -1 ||
      String(o.outlet_name).toLowerCase().indexOf(q) !== -1 ||
      String(o.kode_toko).toLowerCase().indexOf(q) !== -1;
  }).slice(0, 50);

  return matched.map(function (o) {
    return {
      outlet_id: String(o.outlet_id),
      outlet_name: String(o.outlet_name),
      kode_toko: String(o.kode_toko),
      depo: String(o.depo),
      area: String(o.area),
      wa_status: String(o.wa_status || 'PENDING'),
      npwp_status: String(o.npwp_status || 'PENDING'),
      eligible: String(o.eligible).toUpperCase() === 'TRUE' || o.eligible === true
    };
  });
}

/**
 * Generate a cryptographically secure token and store it in TOKEN_MAP.
 * Returns the token and the full registration URL (never any sensitive data).
 */
function api_generateToken(outletId) {
  var sales = getCurrentSales();
  rateLimit(sales.sales_id, 'generate');

  var outlet = findOutlet(outletId);
  if (!outlet) throw new Error('Outlet not found.');
  if (String(outlet.sales_id) !== sales.sales_id) {
    audit(sales.sales_id, 'TOKEN_DENIED', outletId);
    throw new Error('You may only generate links for your own outlets.');
  }

  var token = generateSecureToken();
  var now = new Date();
  var exp = new Date(now.getTime() + CONFIG.TOKEN_TTL_HOURS * 3600 * 1000);

  appendRow(SHEETS.TOKEN_MAP, {
    token: token,
    outlet_id: String(outlet.outlet_id),
    sales_id: sales.sales_id,
    created_at: now.toISOString(),
    expired_at: exp.toISOString(),
    status: 'ACTIVE'
  });

  audit(sales.sales_id, 'TOKEN_GENERATED', { outlet_id: String(outlet.outlet_id) });

  var url = getWebAppUrl() + '?t=' + encodeURIComponent(token);
  return {
    token: token,
    url: url,
    expired_at: exp.toISOString(),
    // QR via a public quickchart-style endpoint; only the safe URL is encoded.
    qr: 'https://api.qrserver.com/v1/create-qr-code/?size=280x280&data=' +
      encodeURIComponent(url)
  };
}

/**
 * Cryptographically secure random token.
 * Uses Apps Script's getUuid seeds + SHA-256 over a high-entropy buffer.
 * (Apps Script has no direct CSPRNG API; we combine multiple entropy
 *  sources and hash them to a 256-bit hex token.)
 */
function generateSecureToken() {
  var entropy = [
    Utilities.getUuid(),
    Utilities.getUuid(),
    new Date().getTime(),
    Math.random(),
    Session.getTemporaryActiveUserKey ? Session.getTemporaryActiveUserKey() : ''
  ].join('|');
  var digest = Utilities.computeDigest(
    Utilities.DigestAlgorithm.SHA_256, entropy, Utilities.Charset.UTF_8);
  return digest.map(function (b) {
    return ('0' + (b & 0xff).toString(16)).slice(-2);
  }).join('');
}

function findOutlet(outletId) {
  var rows = readSheet(SHEETS.OUTLET_MASTER);
  for (var i = 0; i < rows.length; i++) {
    if (String(rows[i].outlet_id) === String(outletId)) return rows[i];
  }
  return null;
}

/* --------------------------------------------------------------------------
 *  OUTLET REGISTRATION — API
 * ------------------------------------------------------------------------ */
/**
 * Resolve a token to the read-only outlet context. Never returns sensitive
 * fields. Validates token existence, status and expiry.
 */
function api_resolveToken(token) {
  var tok = findToken(token);
  if (!tok) return { ok: false, error: 'INVALID', message: 'Link tidak dikenali.' };
  if (String(tok.status).toUpperCase() !== 'ACTIVE') {
    return { ok: false, error: 'INACTIVE', message: 'Link sudah tidak aktif.' };
  }
  if (new Date(tok.expired_at).getTime() < new Date().getTime()) {
    return { ok: false, error: 'EXPIRED', message: 'Link sudah kedaluwarsa.' };
  }
  var outlet = findOutlet(tok.outlet_id);
  if (!outlet) return { ok: false, error: 'NO_OUTLET', message: 'Outlet tidak ditemukan.' };

  return {
    ok: true,
    outlet_name: String(outlet.outlet_name),
    outlet_id: String(outlet.outlet_id),
    depo: String(outlet.depo)
  };
}

function findToken(token) {
  if (!token) return null;
  var rows = readSheet(SHEETS.TOKEN_MAP);
  for (var i = 0; i < rows.length; i++) {
    if (String(rows[i].token) === String(token)) return rows[i];
  }
  return null;
}

/**
 * Submit outlet registration. Only phone, NPWP and consent come from the
 * outlet; outlet_id is derived server-side from the token.
 */
function api_submitRegistration(payload) {
  payload = payload || {};
  var token = String(payload.token || '');
  var tok = findToken(token);
  if (!tok) throw new Error('Link tidak valid.');
  if (String(tok.status).toUpperCase() !== 'ACTIVE') throw new Error('Link tidak aktif.');
  if (new Date(tok.expired_at).getTime() < new Date().getTime()) throw new Error('Link kedaluwarsa.');

  rateLimit(String(tok.outlet_id), 'submit');

  if (!payload.consent) throw new Error('Persetujuan diperlukan untuk melanjutkan.');

  var outlet = findOutlet(tok.outlet_id);
  if (!outlet) throw new Error('Outlet tidak ditemukan.');

  var phoneRaw = String(payload.phone || '');
  var npwpRaw = String(payload.npwp || '');
  var phoneNorm = normalizePhone(phoneRaw);
  var npwpNorm = normalizeNpwp(npwpRaw);

  if (!validatePhoneFormat(phoneNorm)) throw new Error('Nomor WhatsApp tidak valid.');
  if (!validateNpwpFormat(npwpNorm)) throw new Error('Format NPWP tidak valid.');

  var submissionId = 'SUB-' + Utilities.getUuid().slice(0, 8).toUpperCase();
  var now = new Date();

  // Persist submission first (source record).
  appendRow(SHEETS.SUBMISSION_LOG, {
    submission_id: submissionId,
    token: token,
    outlet_id: String(outlet.outlet_id),
    sales_id: String(tok.sales_id),
    phone_raw: phoneRaw,
    phone_normalized: phoneNorm,
    npwp_raw: npwpRaw,
    npwp_normalized: npwpNorm,
    consent: true,
    submitted_at: now.toISOString(),
    phone_verified: false,
    npwp_official_status: NPWP_OFFICIAL.PENDING,
    overall_status: STATUS.REVIEW,
    risk_score: 0,
    risk_reason: ''
  });

  // Consume the token (single-use).
  updateRow(SHEETS.TOKEN_MAP, tok._row, { status: 'USED' });

  audit(String(tok.sales_id), 'SUBMISSION_CREATED',
    { submission_id: submissionId, outlet_id: String(outlet.outlet_id) });

  // Run the validation pipeline.
  var result = runValidationPipeline(submissionId);

  return {
    ok: true,
    submission_id: submissionId,
    token: token,
    overall_status: result.overall_status,
    wa_business: CONFIG.WA_BUSINESS_NUMBER,
    // Prefilled verify message: VERIFY {submission_id} {token}
    wa_link: 'https://wa.me/' + CONFIG.WA_BUSINESS_NUMBER + '?text=' +
      encodeURIComponent('VERIFY ' + submissionId + ' ' + token)
  };
}

/* ==========================================================================
 *  VALIDATION PIPELINE — discrete, testable functions
 * ======================================================================== */

/** Normalize an Indonesian phone number to E.164-ish digits (62XXXXXXXXX). */
function normalizePhone(raw) {
  var d = String(raw || '').replace(/[^\d+]/g, '');
  d = d.replace(/^\+/, '');
  if (d.indexOf('0') === 0) d = '62' + d.slice(1);
  if (d.indexOf('62') !== 0 && d.indexOf('8') === 0) d = '62' + d;
  return d;
}

/** Validate Indonesian mobile format: 62 + 8 + 8..11 digits. */
function validatePhoneFormat(normalized) {
  return /^628\d{7,11}$/.test(String(normalized || ''));
}

/** Normalize NPWP to 15 or 16 digits (strip punctuation). */
function normalizeNpwp(raw) {
  return String(raw || '').replace(/\D/g, '');
}

/** NPWP is 15 (legacy) or 16 (NIK-based) digits. */
function validateNpwpFormat(normalized) {
  var n = String(normalized || '');
  return n.length === 15 || n.length === 16;
}

/** Count how many OTHER outlets share this normalized phone. */
function checkDuplicatePhone(phoneNorm, currentSubmissionId) {
  var subs = readSheet(SHEETS.SUBMISSION_LOG);
  var outlets = {};
  subs.forEach(function (s) {
    if (String(s.submission_id) === String(currentSubmissionId)) return;
    if (String(s.phone_normalized) === String(phoneNorm)) {
      outlets[String(s.outlet_id)] = true;
    }
  });
  var count = Object.keys(outlets).length;
  return { duplicate: count > 0, distinct_outlets: count };
}

/** Count how many OTHER outlets share this normalized NPWP. */
function checkDuplicateNpwp(npwpNorm, currentSubmissionId) {
  var subs = readSheet(SHEETS.SUBMISSION_LOG);
  var master = readSheet(SHEETS.OUTLET_MASTER);
  var outlets = {};
  subs.forEach(function (s) {
    if (String(s.submission_id) === String(currentSubmissionId)) return;
    if (String(s.npwp_normalized) === String(npwpNorm)) {
      outlets[String(s.outlet_id)] = true;
    }
  });
  master.forEach(function (o) {
    if (o.existing_npwp && normalizeNpwp(o.existing_npwp) === npwpNorm) {
      // shared existing NPWP across master rows is also a signal, but
      // matching THIS outlet's own existing NPWP is expected (see match)
    }
  });
  var count = Object.keys(outlets).length;
  return { duplicate: count > 0, distinct_outlets: count };
}

/**
 * Match submission NPWP against the outlet's existing NPWP in OUTLET_MASTER.
 * Returns match=true when master has no existing NPWP (nothing to conflict)
 * or when it equals the submitted one.
 */
function matchOutletMaster(outletId, npwpNorm) {
  var outlet = findOutlet(outletId);
  if (!outlet) return { match: false, reason: 'OUTLET_NOT_FOUND' };
  var existing = normalizeNpwp(outlet.existing_npwp);
  if (!existing) return { match: true, reason: 'NO_EXISTING_NPWP' };
  if (existing === npwpNorm) return { match: true, reason: 'NPWP_MATCH' };
  return { match: false, reason: 'NPWP_MISMATCH' };
}

/** Abnormal submission velocity for the sales in a short window. */
function checkVelocity(salesId) {
  var subs = readSheet(SHEETS.SUBMISSION_LOG);
  var cutoff = new Date().getTime() - CONFIG.VELOCITY_WINDOW_MS;
  var count = subs.filter(function (s) {
    return String(s.sales_id) === String(salesId) &&
      new Date(s.submitted_at).getTime() >= cutoff;
  }).length;
  return { abnormal: count > CONFIG.VELOCITY_THRESHOLD, count: count };
}

/** Detect obviously repeated / low-entropy data patterns. */
function checkRepeatedPattern(phoneNorm, npwpNorm) {
  var reasons = [];
  var localPhone = phoneNorm.replace(/^62/, '');
  if (/^(\d)\1+$/.test(localPhone)) reasons.push('phone_all_same_digit');
  if (/0123456|1234567|9876543/.test(localPhone)) reasons.push('phone_sequential');
  if (/^(\d)\1+$/.test(npwpNorm)) reasons.push('npwp_all_same_digit');
  return { repeated: reasons.length > 0, reasons: reasons };
}

/**
 * Rule-based risk score (0-100). AI/heuristics used ONLY for anomaly
 * detection & prioritization — never to guess if WA is active or NPWP official.
 */
function calculateRiskScore(ctx) {
  var score = 0;
  var reasons = [];
  var R = CONFIG.RISK;

  if (ctx.dupPhone && ctx.dupPhone.duplicate) {
    score += R.PHONE_MULTI_OUTLET;
    reasons.push('Nomor dipakai ' + (ctx.dupPhone.distinct_outlets + 1) + ' outlet');
  }
  if (ctx.dupNpwp && ctx.dupNpwp.duplicate) {
    score += R.NPWP_MULTI_OUTLET;
    reasons.push('NPWP muncul di ' + (ctx.dupNpwp.distinct_outlets + 1) + ' outlet');
  }
  if (ctx.velocity && ctx.velocity.abnormal) {
    score += R.VELOCITY;
    reasons.push('Velocity submission abnormal (' + ctx.velocity.count + ')');
  }
  if (ctx.match && !ctx.match.match && ctx.match.reason === 'NPWP_MISMATCH') {
    score += R.SALES_DEPO_MISMATCH;
    reasons.push('NPWP tidak cocok dengan master outlet');
  }
  if (ctx.pattern && ctx.pattern.repeated) {
    score += R.REPEATED_PATTERN;
    reasons.push('Pola data berulang: ' + ctx.pattern.reasons.join(', '));
  }

  score = Math.max(0, Math.min(100, score));
  return { risk_score: score, risk_reason: reasons.join(' | ') };
}

/**
 * Resolve the final status. Only VERIFIED / REVIEW / REJECTED are possible.
 * VERIFIED requires: valid formats, no duplicates, outlet match, phone
 * verified via WhatsApp, and low risk.
 */
function resolveOverallStatus(ctx) {
  if (!ctx.phoneValid || !ctx.npwpValid) return STATUS.REJECTED;
  if (ctx.risk_score >= 60) return STATUS.REJECTED;

  var clean = !ctx.dupPhone.duplicate && !ctx.dupNpwp.duplicate &&
    ctx.match.match && ctx.risk_score < 30;

  if (clean && ctx.phoneVerified) return STATUS.VERIFIED;
  return STATUS.REVIEW;
}

/**
 * Run the full pipeline for a submission and persist VALIDATION_RESULT +
 * update SUBMISSION_LOG. Returns the resolved result.
 */
function runValidationPipeline(submissionId) {
  var sub = findSubmission(submissionId);
  if (!sub) throw new Error('Submission not found: ' + submissionId);

  var phoneNorm = String(sub.phone_normalized);
  var npwpNorm = String(sub.npwp_normalized);

  var phoneValid = validatePhoneFormat(phoneNorm);
  var npwpValid = validateNpwpFormat(npwpNorm);
  var dupPhone = checkDuplicatePhone(phoneNorm, submissionId);
  var dupNpwp = checkDuplicateNpwp(npwpNorm, submissionId);
  var match = matchOutletMaster(sub.outlet_id, npwpNorm);
  var velocity = checkVelocity(sub.sales_id);
  var pattern = checkRepeatedPattern(phoneNorm, npwpNorm);

  var risk = calculateRiskScore({
    dupPhone: dupPhone, dupNpwp: dupNpwp, velocity: velocity,
    match: match, pattern: pattern
  });

  // Official NPWP validation is a placeholder — status stays PENDING.
  var official = validateNpwpOfficial(npwpNorm);

  var phoneVerified = String(sub.phone_verified).toUpperCase() === 'TRUE' ||
    sub.phone_verified === true;

  var overall = resolveOverallStatus({
    phoneValid: phoneValid, npwpValid: npwpValid,
    dupPhone: dupPhone, dupNpwp: dupNpwp, match: match,
    risk_score: risk.risk_score, phoneVerified: phoneVerified
  });

  // Persist validation result (upsert by submission_id).
  var existing = findValidation(submissionId);
  var vr = {
    submission_id: submissionId,
    outlet_id: String(sub.outlet_id),
    phone_valid: phoneValid,
    npwp_valid: npwpValid,
    dup_phone: dupPhone.duplicate,
    dup_npwp: dupNpwp.duplicate,
    outlet_match: match.match,
    risk_score: risk.risk_score,
    risk_reason: risk.risk_reason,
    overall_status: overall,
    evaluated_at: new Date().toISOString()
  };
  if (existing) updateRow(SHEETS.VALIDATION_RESULT, existing._row, vr);
  else appendRow(SHEETS.VALIDATION_RESULT, vr);

  // Reflect back into submission log.
  updateRow(SHEETS.SUBMISSION_LOG, sub._row, {
    overall_status: overall,
    risk_score: risk.risk_score,
    risk_reason: risk.risk_reason,
    npwp_official_status: official.status
  });

  return { submission_id: submissionId, overall_status: overall,
    risk_score: risk.risk_score, npwp_official_status: official.status };
}

function findSubmission(submissionId) {
  var rows = readSheet(SHEETS.SUBMISSION_LOG);
  for (var i = 0; i < rows.length; i++) {
    if (String(rows[i].submission_id) === String(submissionId)) return rows[i];
  }
  return null;
}

function findValidation(submissionId) {
  var rows = readSheet(SHEETS.VALIDATION_RESULT);
  for (var i = 0; i < rows.length; i++) {
    if (String(rows[i].submission_id) === String(submissionId)) return rows[i];
  }
  return null;
}

/* --------------------------------------------------------------------------
 *  NPWP OFFICIAL VALIDATION — PLACEHOLDER (no DJP scraping)
 * ------------------------------------------------------------------------ */
/**
 * Placeholder for the official DJP Portal / Web Service integration.
 * We DO NOT scrape the DJP website. Until a sanctioned API is wired up,
 * this must return PENDING_OFFICIAL_VALIDATION — never DJP_VERIFIED.
 */
function validateNpwpOfficial(npwpNorm) {
  // TODO: integrate official DJP web service here (API key, endpoint, auth).
  // Example (disabled): return callDjpWebService(npwpNorm);
  return { status: NPWP_OFFICIAL.PENDING, official: false };
}

/* --------------------------------------------------------------------------
 *  WHATSAPP VERIFICATION
 * ------------------------------------------------------------------------ */
/**
 * Webhook receiver for the WhatsApp Business Platform.
 * phone_verified may become true ONLY when the sender's number equals the
 * registered number for the referenced submission.
 * @param {Object} payload  webhook envelope
 * @param {boolean} isMock   true when triggered by the Admin MOCK simulator
 */
function handleWhatsAppWebhook(payload, isMock) {
  var msg = extractWhatsAppMessage(payload);
  if (!msg) return { ok: false, error: 'No message in payload' };

  // Expected text: VERIFY {submission_id} {token}
  var parts = String(msg.text || '').trim().split(/\s+/);
  if (parts.length < 3 || parts[0].toUpperCase() !== 'VERIFY') {
    return { ok: false, error: 'Unrecognized command' };
  }
  var submissionId = parts[1];
  var token = parts[2];

  var sub = findSubmission(submissionId);
  if (!sub) return { ok: false, error: 'Submission not found' };
  if (String(sub.token) !== String(token)) {
    audit('whatsapp', 'WA_TOKEN_MISMATCH', { submission_id: submissionId, mock: !!isMock });
    return { ok: false, error: 'Token mismatch' };
  }

  var senderNorm = normalizePhone(msg.from);
  var registeredNorm = String(sub.phone_normalized);
  var senderMatches = senderNorm === registeredNorm;

  if (!senderMatches) {
    audit('whatsapp', 'WA_SENDER_MISMATCH',
      { submission_id: submissionId, mock: !!isMock });
    return { ok: false, error: 'Sender does not match registered number',
      phone_verified: false };
  }

  // Mark verified and re-run pipeline so status can escalate to VERIFIED.
  updateRow(SHEETS.SUBMISSION_LOG, sub._row, { phone_verified: true });
  audit('whatsapp', isMock ? 'WA_VERIFIED_MOCK' : 'WA_VERIFIED',
    { submission_id: submissionId });
  var result = runValidationPipeline(submissionId);

  return { ok: true, phone_verified: true, mock: !!isMock,
    submission_id: submissionId, overall_status: result.overall_status };
}

/** Extract {from, text} from a WhatsApp Business webhook envelope. */
function extractWhatsAppMessage(payload) {
  try {
    var entry = payload.entry[0];
    var change = entry.changes[0];
    var value = change.value;
    var message = value.messages[0];
    return {
      from: message.from,
      text: (message.text && message.text.body) || message.button && message.button.text || ''
    };
  } catch (e) {
    // Support a simplified flat shape too.
    if (payload && payload.from && payload.text) {
      return { from: payload.from, text: payload.text };
    }
    return null;
  }
}

/* --------------------------------------------------------------------------
 *  ADMIN — MOCK WhatsApp simulator (clearly labelled, NOT production)
 * ------------------------------------------------------------------------ */
/**
 * MOCK ONLY. Simulates a WhatsApp inbound so the prototype can demonstrate
 * phone verification without the real WhatsApp Business API. This must never
 * be treated as production validation.
 */
function admin_mockWhatsAppInbound(fromNumber, submissionId, token) {
  rateLimit('admin', 'mockwa');
  var payload = {
    object: 'whatsapp_business_account',
    entry: [{
      changes: [{
        value: { messages: [{ from: String(fromNumber),
          text: { body: 'VERIFY ' + submissionId + ' ' + token } }] }
      }]
    }]
  };
  var res = handleWhatsAppWebhook(payload, true /* isMock */);
  res.notice = 'MOCK simulation — not production WhatsApp validation.';
  return res;
}

/** Admin: list recent submissions (masked) for the simulator UI. */
function admin_listSubmissions() {
  rateLimit('admin', 'list');
  var subs = readSheet(SHEETS.SUBMISSION_LOG).slice(-25).reverse();
  return subs.map(function (s) {
    return {
      submission_id: String(s.submission_id),
      token: String(s.token),
      outlet_id: String(s.outlet_id),
      phone_masked: maskPhone(s.phone_normalized),
      phone_full_for_mock: String(s.phone_normalized), // needed to simulate exact sender
      npwp_masked: maskNpwp(s.npwp_normalized),
      phone_verified: String(s.phone_verified).toUpperCase() === 'TRUE' || s.phone_verified === true,
      npwp_official_status: String(s.npwp_official_status || NPWP_OFFICIAL.PENDING),
      overall_status: String(s.overall_status),
      risk_score: Number(s.risk_score || 0),
      risk_reason: String(s.risk_reason || '')
    };
  });
}

/* --------------------------------------------------------------------------
 *  DASHBOARD — aggregation + leaderboard
 * ------------------------------------------------------------------------ */
function api_getDashboard() {
  var master = readSheet(SHEETS.OUTLET_MASTER);
  var subs = readSheet(SHEETS.SUBMISSION_LOG);

  var eligibleOutlets = master.filter(function (o) {
    return String(o.eligible).toUpperCase() === 'TRUE' || o.eligible === true;
  });
  var eligibleIds = {};
  eligibleOutlets.forEach(function (o) { eligibleIds[String(o.outlet_id)] = true; });

  // Latest submission per outlet.
  var latestByOutlet = {};
  subs.forEach(function (s) {
    var oid = String(s.outlet_id);
    var t = new Date(s.submitted_at).getTime();
    if (!latestByOutlet[oid] || t > latestByOutlet[oid]._t) {
      var rec = objAssign({}, s); rec._t = t; latestByOutlet[oid] = rec;
    }
  });
  var latest = Object.keys(latestByOutlet).map(function (k) { return latestByOutlet[k]; });

  var submitted = latest.length;
  var waVerified = latest.filter(function (s) {
    return String(s.phone_verified).toUpperCase() === 'TRUE' || s.phone_verified === true;
  }).length;
  var npwpComplete = latest.filter(function (s) {
    return validateNpwpFormat(normalizeNpwp(s.npwp_normalized));
  }).length;
  var fullyVerified = latest.filter(function (s) {
    return String(s.overall_status) === STATUS.VERIFIED;
  }).length;
  var review = latest.filter(function (s) {
    return String(s.overall_status) === STATUS.REVIEW;
  }).length;
  var rejected = latest.filter(function (s) {
    return String(s.overall_status) === STATUS.REJECTED;
  }).length;

  var eligibleCount = eligibleOutlets.length;
  var completionPct = eligibleCount ? Math.round((fullyVerified / eligibleCount) * 100) : 0;

  return {
    kpis: {
      eligible: eligibleCount,
      submitted: submitted,
      wa_verified: waVerified,
      npwp_complete: npwpComplete,
      fully_verified: fullyVerified,
      review: review,
      rejected: rejected,
      completion_pct: completionPct
    },
    leaderboards: buildLeaderboards(master, latestByOutlet),
    recent: latest.slice(-12).reverse().map(function (s) {
      return {
        submission_id: String(s.submission_id),
        outlet_id: String(s.outlet_id),
        phone_masked: maskPhone(s.phone_normalized),
        npwp_masked: maskNpwp(s.npwp_normalized),
        overall_status: String(s.overall_status),
        risk_score: Number(s.risk_score || 0),
        risk_reason: String(s.risk_reason || '')
      };
    })
  };
}

/**
 * Build leaderboards by each hierarchy dimension. Ranking metric is
 * verified_outlets / eligible_outlets — NOT raw submission count.
 */
function buildLeaderboards(master, latestByOutlet) {
  var dims = ['salesman', 'ass', 'bm', 'rbm', 'depo', 'area'];
  var boards = {};

  dims.forEach(function (dim) {
    var groups = {};
    master.forEach(function (o) {
      var key = String(o[dim] || '—');
      var eligible = String(o.eligible).toUpperCase() === 'TRUE' || o.eligible === true;
      if (!groups[key]) groups[key] = { name: key, eligible: 0, verified: 0 };
      if (eligible) groups[key].eligible += 1;
      var sub = latestByOutlet[String(o.outlet_id)];
      if (eligible && sub && String(sub.overall_status) === STATUS.VERIFIED) {
        groups[key].verified += 1;
      }
    });
    boards[dim] = Object.keys(groups).map(function (k) {
      var g = groups[k];
      g.rate = g.eligible ? Math.round((g.verified / g.eligible) * 100) : 0;
      return g;
    }).sort(function (a, b) {
      if (b.rate !== a.rate) return b.rate - a.rate;
      return b.verified - a.verified;
    });
  });

  return boards;
}

/* --------------------------------------------------------------------------
 *  MASKING HELPERS
 * ------------------------------------------------------------------------ */
function maskPhone(phone) {
  var p = String(phone || '');
  if (p.length < 6) return p ? '••••' : '';
  return p.slice(0, 4) + '••••' + p.slice(-3);
}

function maskNpwp(npwp) {
  var n = String(npwp || '');
  if (n.length < 6) return n ? '••••' : '';
  return n.slice(0, 3) + '•••••••' + n.slice(-3);
}

function objAssign(t, s) { for (var k in s) if (s.hasOwnProperty(k)) t[k] = s[k]; return t; }

/* ==========================================================================
 *  SETUP + SAMPLE DUMMY DATA
 * ======================================================================== */
/**
 * One-time setup: creates all sheets with headers and seeds dummy data.
 * Run this from the Apps Script editor after binding the script to a Sheet
 * (or after setting SPREADSHEET_ID in Script Properties).
 */
function setup() {
  Object.keys(SHEETS).forEach(function (k) {
    var sh = getSheet(SHEETS[k]);
    // Ensure header row.
    var first = sh.getRange(1, 1, 1, HEADERS[SHEETS[k]].length).getValues()[0];
    if (String(first[0]) !== HEADERS[SHEETS[k]][0]) {
      sh.clear();
      sh.appendRow(HEADERS[SHEETS[k]]);
      sh.setFrozenRows(1);
    }
  });
  seedSampleData();
  Logger.log('Setup complete. Web app URL: ' + getWebAppUrl());
}

function seedSampleData() {
  var master = getSheet(SHEETS.OUTLET_MASTER);
  if (master.getLastRow() > 1) return; // already seeded

  var sales = getCurrentSales();
  var demoSalesId = sales.sales_id; // so the logged-in demo user owns outlets

  var rows = [
    // outlet_id, name, kode_toko, depo, area, sales_id, salesman, ass, bm, rbm, wa_status, npwp_status, existing_npwp, eligible
    ['OTL-1001', 'Toko Maju Jaya', 'KT-8801', 'Depo Jakarta 1', 'Area DKI', demoSalesId, 'Andi Salesman', 'Budi ASS', 'Citra BM', 'Dedi RBM', 'PENDING', 'PENDING', '', true],
    ['OTL-1002', 'Warung Berkah', 'KT-8802', 'Depo Jakarta 1', 'Area DKI', demoSalesId, 'Andi Salesman', 'Budi ASS', 'Citra BM', 'Dedi RBM', 'PENDING', 'COMPLETE', '091234567890123', true],
    ['OTL-1003', 'Sumber Rejeki', 'KT-8803', 'Depo Bandung', 'Area Jabar', demoSalesId, 'Andi Salesman', 'Eka ASS', 'Fajar BM', 'Dedi RBM', 'VERIFIED', 'PENDING', '', true],
    ['OTL-1004', 'Toko Sentosa', 'KT-8804', 'Depo Bandung', 'Area Jabar', 'SLS-OTHER1', 'Gita Salesman', 'Eka ASS', 'Fajar BM', 'Dedi RBM', 'PENDING', 'PENDING', '', true],
    ['OTL-1005', 'Kios Makmur', 'KT-8805', 'Depo Surabaya', 'Area Jatim', 'SLS-OTHER1', 'Gita Salesman', 'Hadi ASS', 'Ina BM', 'Joko RBM', 'PENDING', 'PENDING', '', true],
    ['OTL-1006', 'Toko Bahagia', 'KT-8806', 'Depo Surabaya', 'Area Jatim', demoSalesId, 'Andi Salesman', 'Hadi ASS', 'Ina BM', 'Joko RBM', 'PENDING', 'PENDING', '', true],
    ['OTL-1007', 'Warung Sederhana', 'KT-8807', 'Depo Jakarta 2', 'Area DKI', demoSalesId, 'Andi Salesman', 'Budi ASS', 'Citra BM', 'Dedi RBM', 'PENDING', 'PENDING', '', false]
  ];
  rows.forEach(function (r) {
    master.appendRow(r);
  });
  audit('system', 'SEED_SAMPLE_DATA', { outlets: rows.length });
}

/**
 * Optional: set which sales_id the demo session should represent, so you can
 * showcase the "only my outlets" behaviour without multiple Google accounts.
 */
function setDemoSalesId(salesId) {
  PropertiesService.getScriptProperties().setProperty('DEMO_SALES_ID', salesId || '');
}

/* ==========================================================================
 *  LIGHTWEIGHT SELF-TESTS (run manually from the editor)
 * ======================================================================== */
function runSelfTests() {
  var results = [];
  function assert(name, cond) { results.push((cond ? 'PASS ' : 'FAIL ') + name); }

  assert('normalizePhone 08 -> 62', normalizePhone('081234567890') === '6281234567890');
  assert('normalizePhone +62', normalizePhone('+62 812-3456-7890') === '6281234567890');
  assert('validatePhone ok', validatePhoneFormat('6281234567890') === true);
  assert('validatePhone bad', validatePhoneFormat('12345') === false);
  assert('normalizeNpwp strip', normalizeNpwp('09.123.456.7-890.123') === '091234567890123');
  assert('validateNpwp 15', validateNpwpFormat('091234567890123') === true);
  assert('validateNpwp 16', validateNpwpFormat('0912345678901234') === true);
  assert('validateNpwp bad', validateNpwpFormat('123') === false);

  var risk = calculateRiskScore({
    dupPhone: { duplicate: true, distinct_outlets: 2 },
    dupNpwp: { duplicate: false },
    velocity: { abnormal: false },
    match: { match: true },
    pattern: { repeated: false }
  });
  assert('risk score >0 on dup phone', risk.risk_score >= 35);

  var st = resolveOverallStatus({
    phoneValid: false, npwpValid: true, dupPhone: { duplicate: false },
    dupNpwp: { duplicate: false }, match: { match: true }, risk_score: 0,
    phoneVerified: true
  });
  assert('invalid phone -> REJECTED', st === STATUS.REJECTED);

  assert('official npwp stays PENDING',
    validateNpwpOfficial('091234567890123').status === NPWP_OFFICIAL.PENDING);

  Logger.log(results.join('\n'));
  return results;
}
