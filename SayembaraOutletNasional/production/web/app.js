/* ============================================================================
 *  Shared client — Supabase init + RPC helpers + safe DOM utilities.
 *  Loaded by every page after supabase-js and config.js.
 * ========================================================================== */
(function () {
  var cfg = window.APP_CONFIG || {};
  if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.indexOf('YOUR-') === 0) {
    console.warn('config.js belum diisi. Salin config.example.js -> config.js.');
  }
  // supabase-js v2 exposes a global `supabase` with createClient.
  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true }
  });
  window.SB = sb;
  window.CFG = cfg;

  // ---- session token for the active salesman (kept per-tab) ----
  window.SalesSession = {
    key: 'son_sales_session',
    get: function () { try { return sessionStorage.getItem(this.key); } catch (e) { return null; } },
    set: function (t) { try { sessionStorage.setItem(this.key, t); } catch (e) {} },
    clear: function () { try { sessionStorage.removeItem(this.key); } catch (e) {} }
  };

  // ---- RPC wrapper with friendly errors ----
  window.rpc = function (fn, args) {
    return sb.rpc(fn, args || {}).then(function (res) {
      if (res.error) throw new Error(mapError(res.error.message));
      return res.data;
    });
  };

  function mapError(msg) {
    var m = {
      'PIN_INVALID': 'PIN salah.',
      'PIN_LOCKED': 'Terlalu banyak percobaan. Coba lagi dalam 15 menit.',
      'PIN_NOT_SET': 'PIN belum diatur untuk salesman ini.',
      'SESSION_INVALID': 'Sesi berakhir. Silakan pilih profil & PIN lagi.',
      'OUTLET_NOT_OWNED': 'Outlet ini bukan milik Anda.',
      'TOKEN_INVALID': 'Link tidak valid / kedaluwarsa.',
      'CONSENT_REQUIRED': 'Persetujuan diperlukan.',
      'PHONE_INVALID': 'Nomor WhatsApp tidak valid.',
      'NPWP_INVALID': 'Format NPWP tidak valid.',
      'RATE_LIMIT': 'Terlalu cepat. Mohon tunggu sebentar.',
      'NOT_AUTHENTICATED': 'Silakan login depo dulu.'
    };
    for (var k in m) if (msg && msg.indexOf(k) !== -1) return m[k];
    return msg || 'Terjadi kesalahan.';
  }

  // ---- DOM utils ----
  window.esc = function (s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  };
  window.$ = function (s, r) { return (r || document).querySelector(s); };
  window.$all = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };

  window.toast = function (msg) {
    var t = document.getElementById('toast');
    if (!t) { alert(msg); return; }
    t.textContent = msg; t.classList.add('show');
    clearTimeout(t._t); t._t = setTimeout(function () { t.classList.remove('show'); }, 2600);
  };
  window.statusBadge = function (s) {
    var map = { VERIFIED: 'ok', REVIEW: 'warn', REJECTED: 'bad' };
    return '<span class="badge ' + (map[s] || 'neutral') + '">' + esc(s) + '</span>';
  };
  window.setLoading = function (btn, on, label) {
    if (!btn) return;
    if (on) { btn._l = btn.innerHTML; btn.disabled = true;
      btn.innerHTML = '<span class="spinner"></span> ' + (label || 'Memproses...'); }
    else { btn.disabled = false; if (btn._l) btn.innerHTML = btn._l; }
  };
  window.copyText = function (text) {
    if (navigator.clipboard) navigator.clipboard.writeText(text).then(function () { toast('Disalin'); });
    else { var ta = document.createElement('textarea'); ta.value = text; document.body.appendChild(ta);
      ta.select(); try { document.execCommand('copy'); toast('Disalin'); } catch (e) {} document.body.removeChild(ta); }
  };

  // Require a depo login; redirect to index if missing. Returns a Promise<session>.
  window.requireDepo = function () {
    return sb.auth.getSession().then(function (r) {
      if (!r.data.session) { location.href = 'index.html'; throw new Error('no depo'); }
      return r.data.session;
    });
  };

  window.publicBase = function () {
    if (CFG.PUBLIC_BASE_URL) return CFG.PUBLIC_BASE_URL.replace(/\/$/, '');
    return location.origin + location.pathname.replace(/\/[^\/]*$/, '');
  };
})();
