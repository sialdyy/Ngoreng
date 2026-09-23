# Sayembara Outlet Nasional — Production Architecture (PostgreSQL / Supabase)

Dokumen ini menjelaskan skema database, model keamanan Row Level Security (RLS),
dan desain autentikasi **Depo (password) + Salesman (PIN)** untuk skala nasional
(~500.000 outlet, ~300 depo, ribuan salesman, submission publik konkuren).

Prototype Apps Script tetap dipakai untuk **pilot**; versi ini untuk **produksi**.

---

## 1. Kenapa pindah dari Google Sheets

| Kendala Sheets/Apps Script | Postgres/Supabase |
|---|---|
| 10 juta sel/spreadsheet (500k×14 kolom ≈ 7 jt, jebol) | 500k baris = trivial; indeks B-tree/GIN |
| Baca seluruh sheet ke memori tiap query | Query terindeks, milidetik |
| Eksekusi 6 menit & ~30 simultan | Ribuan koneksi via pooler |
| Race condition saat submit paralel | Transaksi ACID |
| Enkripsi/akses granular tidak ada | RLS + column grants + pgcrypto |

Data HP + NPWP = **data pribadi** menurut **UU PDP 27/2022** → wajib enkripsi,
kontrol akses, audit, retensi. Postgres memenuhi ini; Sheets tidak.

---

## 2. Komponen

```
┌──────────────┐   HTTPS/JWT   ┌──────────────────────────────────────┐
│  Web Sales   │──────────────▶│  Supabase                            │
│  (Depo+PIN)  │               │  ├─ Auth  (depo login → JWT)         │
├──────────────┤   RPC (anon)  │  ├─ PostgREST / RPC (fungsi 03_*.sql)│
│ Web Register │──────────────▶│  ├─ Postgres (RLS, pgcrypto)         │
│  (Outlet)    │               │  ├─ Edge Functions (WA webhook, DJP) │
├──────────────┤               │  ├─ Vault (enc_key, pepper)          │
│  Dashboard   │◀──────────────│  └─ Cron (expire token, DJP batch)   │
└──────────────┘               └──────────────────────────────────────┘
```

Frontend boleh tetap konsep Apps Script/HTML, atau app web (Next.js/Flutter).
Yang penting: semua akses lewat **RPC**, bukan query tabel langsung.

---

## 3. Model autentikasi (jawaban atas kebutuhanmu)

**Depo = batas keamanan keras. Salesman = sub-identitas ber-PIN.**

1. **Depo login** (username/password) → 1 akun Supabase Auth per depo (300 akun).
   JWT membawa `auth.uid()`. Fungsi `current_depo_id()` memetakan uid → depo.
2. **Pilih profil Salesman** (ala Netflix) → `auth_list_salesmen()` menampilkan
   nama salesman di depo itu (tanpa PIN/secret).
3. **Masukkan PIN** → `auth_open_session(salesman_id, pin)`:
   - PIN diverifikasi dengan **bcrypt** (`crypt()` pgcrypto). Tidak pernah plain.
   - 5× salah → lockout 15 menit (`locked_until`).
   - Sukses → dibuat baris `salesman_session` + dikembalikan **session_token**
     acak (256-bit) yang hanya ditampilkan sekali; DB simpan **hash**-nya saja.
4. Semua aksi sales (search, generate QR) mengirim `session_token`. Fungsi
   `_session_salesman()` memvalidasi: sesi aktif, belum kedaluwarsa (12 jam),
   **dan depo-nya == depo JWT** (mencegah token dipakai lintas depo).

### Kenapa desainnya begini
- Perangkat sering **dipakai bersama di depo**. Depo yang login sekali; PIN
  memisahkan salesman. Ini pola yang realistis di lapangan.
- **Boundary keras tetap depo** (RLS), jadi meski PIN bocor, kerusakan
  terbatas di dalam satu depo — tidak pernah lintas depo/nasional.
- Kalau perusahaan punya Google Workspace/SSO per salesman, bisa dinaikkan jadi
  1 auth user per salesman; RLS tinggal diubah ke `sales_id`. Depo+PIN dipilih
  karena paling praktis untuk ribuan salesman tanpa email kantor.

---

## 4. Row Level Security (ringkas)

- `current_depo_id()` (SECURITY DEFINER, STABLE) → depo dari `auth.uid()`.
- Setiap tabel `enable row level security`; tabel PII pakai `force`.
- Policy inti: `depo_id = current_depo_id()` untuk SELECT/UPDATE.
- `anon` **tidak punya policy tabel** → hanya bisa memanggil RPC publik
  (`pub_resolve_token`, `pub_submit_registration`) yang SECURITY DEFINER.
- **Column grants**: kolom `phone_enc/npwp_enc/*_hash` di `submission` dan
  `pin_hash` di `salesman` **tidak** di-grant ke `authenticated`. Jadi meski JWT
  depo bocor, ciphertext PII tidak bisa ditarik massal. Depo hanya lihat nilai
  **masked** (`phone_last3`, `npwp_last3`).

Detail: `db/02_rls.sql`.

---

## 5. Perlindungan data pribadi (PII)

| Data | Penyimpanan | Untuk apa |
|---|---|---|
| Phone / NPWP asli | `pgp_sym_encrypt` (kunci di Vault) → `phone_enc/npwp_enc` | disimpan aman |
| Deteksi duplikat | **HMAC-SHA256 + pepper** → `phone_hash/npwp_hash` | cek "1 nomor banyak outlet" tanpa dekripsi |
| Tampilan | `phone_last3/npwp_last3` | masking di UI |
| Token registrasi | hanya **hash** di `token_map.token_hash` | dump DB tak bisa rekonstruksi link |
| Reveal PII | `admin_reveal_pii()` **service_role only**, menulis `audit_log` | akses per-kasus, teraudit |

Kunci enkripsi & pepper: **Supabase Vault** (produksi) atau
`ALTER DATABASE ... SET app.enc_key/app.pepper` (dev). **Rotasi kunci**: simpan
`key_id`, re-encrypt bertahap (lihat runbook di bagian 9).

---

## 6. Alur data

```
Depo login → pilih Salesman → PIN → session_token
   → sales_search_outlets(session, q)     -- hanya toko salesman itu
   → sales_generate_token(session, outlet)-- token 256-bit, simpan hash
       → QR/URL = <app>?t={raw_token}      -- tak ada PII di URL
Outlet buka link
   → pub_resolve_token(t)                  -- outlet read-only
   → pub_submit_registration(t, phone, npwp, consent)
       → enkripsi + hash + run_validation_pipeline()
       → status VERIFIED/REVIEW/REJECTED, risk_score, risk_reason
   → tombol Verify via WhatsApp (VERIFY {code} {token})
WhatsApp webhook (Edge Function, service_role)
   → wa_apply_verification(code, token, sender)
       → phone_verified=true HANYA jika sender==nomor terdaftar
       → pipeline re-run → bisa naik ke VERIFIED
Dashboard
   → dash_kpis(), dash_leaderboard(dim)    -- ranking verified/eligible
```

---

## 7. Validasi & anomaly

Fungsi pipeline (`run_validation_pipeline`) rule-based, mirror dari prototype:
format phone/NPWP, duplikat via hash, match NPWP master, velocity/5 menit, pola
berulang → `risk_score` 0–100 + `risk_reason`. Status hanya
**VERIFIED / REVIEW / REJECTED**.

- **NPWP resmi**: `validate_npwp_official()` = placeholder, status tetap
  `PENDING_OFFICIAL_VALIDATION`. **Tidak ada scraping DJP.** Integrasi resmi
  lewat Edge Function (batch/cron) saat API tersedia.
- **AI**: hanya untuk anomaly detection & prioritas antrian review — **bukan**
  menebak keaktifan WA atau keabsahan NPWP.

---

## 8. Skalabilitas & performa (500k)

- Indeks: `idx_outlet_depo`, `idx_outlet_sales`, GIN trigram untuk search nama,
  `idx_sub_phone_hash/npwp_hash` untuk duplikat, `idx_sub_outlet_time` untuk
  "latest per outlet".
- Dashboard berat → jadikan **materialized view** + refresh via Cron (mis. tiap
  5 menit), atau tabel agregat per depo. `v_latest_submission` bisa dinaikkan ke
  materialized bila perlu.
- **Connection pooling**: pakai Supabase pooler (PgBouncer, transaction mode).
- Load master 500k: **`\copy` staging → upsert** (lihat `04_seed.sql`), bukan
  ribuan INSERT.
- Partisi opsional: `submission` per bulan bila volume tinggi.

---

## 9. Deploy & runbook

1. Buat project Supabase. Aktifkan `pgcrypto`, `pg_trgm`, `citext` (di-`create
   extension` oleh `01_schema.sql`).
2. Set secrets di **Vault** (atau dev GUC):
   `app.enc_key`, `app.pepper`, `app.wa_business`.
3. Jalankan berurutan: `01_schema.sql` → `02_rls.sql` → `03_functions.sql` →
   `04_seed.sql`.
4. Buat **auth user per depo** (Supabase Auth → Users), lalu isi
   `depo.auth_uid`. Salesman PIN via `auth_set_pin()` (atau seed bcrypt).
5. Edge Functions: `whatsapp-webhook` (verifikasi signature Meta → panggil
   `wa_apply_verification`) dan `djp-batch` (isi `validate_npwp_official`).
6. Cron: expire token (`update token_map set status='EXPIRED' where
   expires_at < now() and status='ACTIVE'`), refresh materialized view,
   retensi audit.
7. Frontend arahkan semua panggilan ke RPC di atas. Public app cukup pakai
   `anon` key; portal depo pakai session Supabase Auth.

### Kontrol keamanan tambahan
- **Rate limiting**: `rl_check()` per actor/bucket (submit 5/5mnt/token,
  generate 60/mnt/salesman, PIN 30/mnt/depo).
- **Audit**: setiap aksi sensitif → `audit_log` (termasuk reveal PII, PIN gagal,
  sender mismatch).
- **Retensi**: definisikan kebijakan hapus/anonymize PII setelah program selesai.
- **Backup**: PITR Supabase; uji restore.

---

## 10. Peta file

| File | Isi |
|---|---|
| `db/01_schema.sql` | Tabel, enum, indeks, secrets accessor |
| `db/02_rls.sql` | RLS policies + column grants |
| `db/03_functions.sql` | Auth PIN/session, sales, public, pipeline, WA, dashboard, admin |
| `db/04_seed.sql` | Sample data + pola bulk-load 500k |
| `docs/ARCHITECTURE.md` | Dokumen ini |

Roadmap: pilih SSO per-salesman bila tersedia; tambah role `compliance`;
materialized dashboard; partisi submission; integrasi DJP resmi.
