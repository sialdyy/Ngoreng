# Sayembara Outlet Nasional — Apps Script Web App

Prototype web app dengan dua user journey:

- **Sales Portal** (internal, mobile-friendly) — sales memilih outlet miliknya,
  meng-generate QR/link unik berbasis **secure random token**.
- **Outlet Registration** (public) — outlet scan QR, mengisi **Nomor WhatsApp**
  + **NPWP** + consent. `outlet_id` terhubung otomatis dari token — outlet
  tidak pernah mengetik kode toko.

Google Sheets dipakai sebagai prototype database.

## Files

| File | Peran |
|------|-------|
| `Code.gs` | Backend: routing, token, validation pipeline, webhook, dashboard, masking, rate limit, audit, setup + dummy data |
| `Sales.html` | Sales Portal (search, detail, Generate QR, Copy Link) |
| `Register.html` | Outlet Registration (read-only outlet + form + Verify via WhatsApp) |
| `Dashboard.html` | KPI + leaderboard (verified/eligible) |
| `Admin.html` | Admin + **MOCK** WhatsApp webhook simulator |
| `Styles.html` | Tema korporat navy/white/gold (responsive) |
| `Scripts.html` | Helper client (escape, google.script.run, toast) |
| `appsscript.json` | Manifest (web app, timezone Asia/Jakarta) |

## Sheets & schema

Dibuat otomatis oleh `setup()`:

- `OUTLET_MASTER` — `outlet_id, outlet_name, kode_toko, depo, area, sales_id, salesman, ass, bm, rbm, wa_status, npwp_status, existing_npwp, eligible`
- `TOKEN_MAP` — `token, outlet_id, sales_id, created_at, expired_at, status`
- `SUBMISSION_LOG` — `submission_id, token, outlet_id, sales_id, phone_raw, phone_normalized, npwp_raw, npwp_normalized, consent, submitted_at, phone_verified, npwp_official_status, overall_status, risk_score, risk_reason`
- `VALIDATION_RESULT` — `submission_id, outlet_id, phone_valid, npwp_valid, dup_phone, dup_npwp, outlet_match, risk_score, risk_reason, overall_status, evaluated_at`
- `AUDIT_LOG` — `timestamp, actor, action, detail, ip_hint`

## Validation pipeline (fungsi terpisah)

`normalizePhone` · `validatePhoneFormat` · `normalizeNpwp` · `validateNpwpFormat`
· `checkDuplicatePhone` · `checkDuplicateNpwp` · `matchOutletMaster`
· `calculateRiskScore` · `resolveOverallStatus`

Status akhir hanya: **`VERIFIED`**, **`REVIEW`**, **`REJECTED`**.

- **WhatsApp**: tombol *Verify via WhatsApp* membuka nomor Business resmi dengan
  pesan `VERIFY {submission_id} {token}`. `phone_verified` hanya `true` jika
  nomor pengirim == nomor terdaftar. Webhook produksi = `handleWhatsAppWebhook()`,
  simulator = MOCK di Admin (jelas dilabeli, bukan validasi produksi).
- **NPWP**: tidak ada scraping DJP. Hanya format + duplicate + match ke master.
  `validateNpwpOfficial()` adalah placeholder → status
  `PENDING_OFFICIAL_VALIDATION` (bukan `DJP_VERIFIED`) sampai API resmi aktif.
- **Anomaly detection (rule-based)**: nomor dipakai banyak outlet, NPWP di banyak
  outlet, velocity abnormal, mismatch NPWP master, pola data berulang. Output
  `risk_score` (0–100) + `risk_reason`. AI hanya untuk anomaly/prioritization —
  bukan menebak keaktifan WA atau keabsahan NPWP.

## Security

Token acak (256-bit) & expirable & single-use & teraudit · tidak ada data
sensitif di URL (`?t={token}` saja) · NPWP & phone dimasking di dashboard ·
output HTML di-escape (server + client) · rate limiting sederhana (CacheService)
· audit log.

## Deployment (Apps Script Web App)

1. Buat Google Spreadsheet baru (kosong).
2. **Extensions → Apps Script**.
3. Tambahkan semua file: `Code.gs`, dan file HTML `Sales`, `Register`,
   `Dashboard`, `Admin`, `Styles`, `Scripts` (**File → New → HTML file**, nama
   tanpa `.html`). Ganti isi manifest via **Project Settings → Show
   `appsscript.json`** dengan file `appsscript.json` di repo ini.
4. Jalankan fungsi **`setup`** sekali (pilih `setup` di dropdown → Run), setujui
   izin. Ini membuat semua sheet + dummy data.
5. **Deploy → New deployment → Web app**.
   - *Execute as*: **User deploying**.
   - *Who has access*: **Anyone** (agar outlet publik bisa membuka link token).
6. Salin **Web app URL**. Buka:
   - Sales Portal: `<URL>?page=sales`
   - Dashboard: `<URL>?page=dashboard`
   - Admin (MOCK): `<URL>?page=admin`
   - Registrasi: dibuka otomatis via QR/link `<URL>?t={token}`.

### Tips demo

- Semua dummy outlet dengan `sales_id` = sales login menjadi milik Anda. Untuk
  menyimulasikan sales lain tanpa akun Google berbeda, jalankan
  `setDemoSalesId('SLS-OTHER1')` di editor.
- Verifikasi self-test: jalankan `runSelfTests()` → cek **Executions/Logs**.
- Config penting di `CONFIG` (Code.gs): `WA_BUSINESS_NUMBER`, `TOKEN_TTL_HOURS`,
  `RATE_LIMIT_*`, bobot `RISK`.
