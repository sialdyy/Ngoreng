# Quickstart GRATIS — 0 sampai Mengumpulkan Data

Panduan klik-per-klik memakai **Supabase Free + Vercel Free**. Biaya Rp0.
Bagian sulit (skema, keamanan, validasi) sudah jadi — di sini kamu tinggal
menyalin-tempel. Perkiraan waktu: **± 1 jam**.

> Ringkasan alur untuk user lapangan (tanpa install apa pun):
> - **Salesman**: buka link → login depo → tap nama → PIN → cari toko → Generate QR → kirim.
> - **Outlet**: klik link → nama toko muncul otomatis → isi WA + NPWP + setuju → kirim → Verify WhatsApp.
> - **Manajemen**: buka link dashboard.

---

## Bagian A — Database (Supabase, gratis) · ~20 menit

1. Buka **supabase.com** → **Start your project** (login Google/GitHub) → **New project**.
   - Region: **Southeast Asia (Singapore)**. Simpan **Database password**.
2. Tunggu project selesai dibuat.
3. Menu kiri → **SQL Editor** → **New query**. Jalankan berurutan (copy isi file, klik **Run**):
   1. `db/01_schema.sql`
   2. `db/02_rls.sql`
   3. `db/03_functions.sql`
   4. `db/04_seed.sql` (data contoh — boleh dilewati saat produksi)
4. Set 3 rahasia (SQL Editor → Run). **Ganti nilainya dengan milikmu:**
   ```sql
   alter database postgres set app.enc_key   = 'GANTI-kunci-acak-panjang';
   alter database postgres set app.pepper    = 'GANTI-pepper-acak-panjang';
   alter database postgres set app.wa_business = '628XXXXXXXXXX';
   ```
   > Untuk produksi, pindahkan `enc_key`/`pepper` ke **Supabase Vault** (lihat ARCHITECTURE.md).
5. Ambil kunci publik: menu **Project Settings → API**. Catat:
   - **Project URL** (mis. `https://abcd.supabase.co`)
   - **anon public** key (boleh dipakai di frontend — aman).
   - **service_role** key → **JANGAN** taruh di frontend. Simpan rahasia.

## Bagian B — Akun Depo + PIN Salesman · ~15 menit

1. Menu **Authentication → Users → Add user**. Buat 1 akun per depo, mis.
   email `DPJKT1@sayembara.internal`, beri password. Salin **User UID**-nya.
2. Hubungkan akun ke depo (SQL Editor):
   ```sql
   update depo set auth_uid = '<User-UID-tadi>' where depo_code = 'DPJKT1';
   ```
3. Set PIN salesman (contoh PIN 1234):
   ```sql
   update salesman set pin_hash = crypt('1234', gen_salt('bf',10)), pin_set_at = now()
   where sales_code = 'SLS-000101';
   ```
   > Untuk 300 depo sekaligus, minta skrip generator massal (bisa dibuatkan).

## Bagian C — Hosting Halaman (Vercel, gratis) · ~15 menit

1. Di folder `production/web`: `cp config.example.js config.js`, lalu isi:
   ```js
   SUPABASE_URL: 'https://abcd.supabase.co',
   SUPABASE_ANON_KEY: 'anon-public-key-...',
   DEPO_EMAIL_DOMAIN: 'sayembara.internal',
   WA_BUSINESS: '628XXXXXXXXXX',
   PUBLIC_BASE_URL: ''   // isi setelah tahu URL Vercel
   ```
2. Deploy (pilih satu, keduanya gratis):
   - **Vercel**: vercel.com → **Add New → Project** → import repo (atau drag folder
     `web/`), **Root Directory = production/web** → **Deploy**.
   - **Netlify**: app.netlify.com → drag-and-drop folder `web/`.
3. Setelah dapat URL (mis. `https://sayembara.vercel.app`), isi `PUBLIC_BASE_URL`
   di `config.js` dengan URL itu, lalu deploy ulang (biar link registrasi benar).

## Bagian D — Import Master 500k · saat produksi

Jangan pakai INSERT satu-satu. Siapkan `outlets.csv` (kolom: outlet_id,
outlet_name, kode_toko, depo_code, sales_code, ass, bm, rbm, existing_npwp,
eligible), lalu ikuti pola `\copy` di `db/04_seed.sql` (staging → upsert).
Untuk Free tier, mulai dari beberapa depo dulu (batas 500 MB).

## Bagian E — Uji Coba (5 menit)

1. Buka `https://<url>/index.html` → login depo → pilih salesman → PIN.
2. Cari outlet → **Generate QR** → **Copy Link**.
3. Buka link itu di HP lain → isi WA + NPWP + centang → **Kirim**.
4. **Verify via WhatsApp** (prototipe: pakai `admin.html` → Mock verify dengan
   nomor terdaftar).
5. Buka `dashboard.html` → cek KPI + leaderboard.

---

## Biaya & kapan naik tier

| | Free (mulai) | Pro (~$25/bln) — nanti |
|---|---|---|
| Database | 500 MB, auto-pause 1 mgg idle | 8 GB+, tanpa pause, backup harian |
| Hosting | Vercel/Netlify gratis | tetap gratis |
| Cocok untuk | pilot / beberapa depo | rollout nasional penuh |

Mulai gratis, naik ke Pro **hanya saat** butuh kapasitas nasional.

## Catatan keamanan singkat

- Hanya **anon key** di frontend (aman; RLS + RPC yang menjaga data).
- **service_role** & **enc_key** tak pernah di frontend/laptop terbuka — pakai Vault.
- PII terenkripsi, dimasking di dashboard, akses penuh hanya via RPC teraudit.
- Detail kepatuhan: lihat `ARCHITECTURE.md` (bagian PII & keamanan).
