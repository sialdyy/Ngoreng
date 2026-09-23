# Frontend Produksi — static + supabase-js

Halaman statis (tanpa build step) yang memanggil RPC Supabase yang sudah teruji.
Desain navy/gold sama dengan prototype. Cukup host di Vercel/Netlify/GitHub Pages.

## File

| File | Peran |
|------|-------|
| `index.html` | Login depo → picker salesman (ala Netflix) → PIN |
| `sales.html` | Cari outlet sendiri, Generate QR, Copy link |
| `register.html` | Registrasi outlet publik (token → form) |
| `dashboard.html` | KPI + leaderboard (verified/eligible) |
| `admin.html` | Log submission + MOCK WhatsApp verify (depo-scoped) |
| `app.js` | Init Supabase, wrapper RPC, util aman (escape, toast) |
| `styles.css` | Tema korporat |
| `config.example.js` | Template konfigurasi → salin ke `config.js` |

## Setup

1. **Backend Supabase harus sudah jalan** (lihat `../db` + `../docs/ARCHITECTURE.md`):
   jalankan `01→04.sql`, set secret Vault (`app.enc_key`, `app.pepper`,
   `app.wa_business`).
2. Salin config: `cp config.example.js config.js`, isi `SUPABASE_URL` dan
   `SUPABASE_ANON_KEY` (Project Settings → API). **Jangan** taruh service_role key.
3. Buat akun depo di **Supabase Auth → Users** (Add user), mis. email
   `DPJKT1@sayembara.internal`. Lalu hubungkan ke tabel depo:
   ```sql
   update depo set auth_uid = '<uuid user tadi>' where depo_code = 'DPJKT1';
   ```
   Set `DEPO_EMAIL_DOMAIN` di `config.js` agar sales cukup ketik kode depo.
4. Set PIN salesman (oleh admin, atau lewat UI khusus):
   ```sql
   -- via RPC saat login sebagai depo tsb, atau langsung:
   update salesman set pin_hash = crypt('1234', gen_salt('bf',10)), pin_set_at = now()
   where sales_code = 'SLS-000101';
   ```
5. **Hosting** (pilih satu):
   - **Vercel**: `vercel --prod` di folder ini (atau import repo, root = folder ini).
   - **Netlify**: drag-and-drop folder, atau connect repo.
   - **GitHub Pages / Cloudflare Pages**: arahkan ke folder ini.
   Set `PUBLIC_BASE_URL` di `config.js` ke URL hosting agar link registrasi benar
   (mis. `https://sayembara.vercel.app`).

## Alur uji cepat

1. Buka `index.html` → login depo → pilih salesman → PIN → masuk `sales.html`.
2. Cari outlet → Generate QR → Copy link.
3. Buka link (`register.html?t=...`) di HP lain → isi WA + NPWP + consent → submit.
4. Tap **Verify via WhatsApp** (prefilled `VERIFY {code} {token}`).
   - Prototype: pakai `admin.html` → Mock verify dengan nomor terdaftar.
5. Lihat `dashboard.html` untuk KPI + leaderboard.

## Catatan keamanan

- Hanya **anon key** yang ada di frontend (aman untuk publik; RLS + RPC yang menjaga data).
- `service_role` key **tidak pernah** di frontend — hanya untuk Edge Functions
  (webhook WhatsApp, batch DJP, reveal PII).
- Session salesman disimpan di `sessionStorage` (per-tab), berumur 12 jam di server.
- Semua output di-escape; token tak pernah muncul selain di URL registrasi.

## Berikutnya

- Edge Function `whatsapp-webhook` → verifikasi signature Meta → `wa_apply_verification`.
- Edge Function `djp-batch` → isi `validate_npwp_official`.
- Materialized view dashboard + Cron (expire token, refresh) untuk skala nasional.
