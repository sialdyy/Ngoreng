# Diagram Alur — Sayembara Outlet Nasional

Diagram Mermaid (otomatis ter-render di GitHub). Mencakup: ERD database,
alur autentikasi Depo + Salesman-PIN, alur registrasi outlet (token → submit →
validasi → WhatsApp), dan lapisan keamanan (RLS).

---

## 1. ERD — Entity Relationship Diagram

```mermaid
erDiagram
    AREA ||--o{ DEPO : "punya"
    DEPO ||--o{ SALESMAN : "menaungi"
    DEPO ||--o{ OUTLET_MASTER : "memiliki"
    SALESMAN ||--o{ OUTLET_MASTER : "bertanggung jawab"
    OUTLET_MASTER ||--o{ TOKEN_MAP : "di-generate"
    SALESMAN ||--o{ TOKEN_MAP : "membuat"
    TOKEN_MAP ||--o| SUBMISSION : "menghasilkan"
    OUTLET_MASTER ||--o{ SUBMISSION : "menerima"
    SUBMISSION ||--|| VALIDATION_RESULT : "dievaluasi"
    SALESMAN ||--o{ SALESMAN_SESSION : "membuka sesi"
    DEPO ||--o{ AUDIT_LOG : "tercatat"

    AREA {
        bigint id PK
        text area_code
        text area_name
        text region
    }
    DEPO {
        bigint id PK
        text depo_code
        text depo_name
        bigint area_id FK
        uuid auth_uid "= Supabase Auth user"
        boolean is_active
    }
    SALESMAN {
        bigint id PK
        text sales_code
        text full_name
        bigint depo_id FK
        text pin_hash "bcrypt, tak pernah plain"
        int failed_pin
        timestamptz locked_until
    }
    OUTLET_MASTER {
        bigint id PK
        text outlet_id "business key"
        text outlet_name
        text kode_toko
        bigint depo_id FK
        bigint sales_id FK
        bytea existing_npwp_hash "HMAC"
        boolean eligible
    }
    TOKEN_MAP {
        bigint id PK
        bytea token_hash "hash saja, bukan token asli"
        bigint outlet_ref FK
        bigint depo_id FK
        bigint sales_id FK
        timestamptz expires_at
        token_status status "ACTIVE/USED/EXPIRED/REVOKED"
    }
    SUBMISSION {
        bigint id PK
        text submission_code
        bigint token_ref FK
        bigint outlet_ref FK
        bigint depo_id FK
        bytea phone_enc "pgp_sym encrypted"
        bytea npwp_enc "pgp_sym encrypted"
        bytea phone_hash "HMAC untuk dedup"
        bytea npwp_hash "HMAC untuk dedup"
        text phone_last3 "untuk masking"
        boolean phone_verified
        npwp_official_status npwp_official
        submission_status overall_status
        int risk_score
    }
    VALIDATION_RESULT {
        bigint id PK
        bigint submission_ref FK
        boolean phone_valid
        boolean npwp_valid
        boolean dup_phone
        boolean dup_npwp
        boolean outlet_match
        int risk_score
        submission_status overall_status
    }
    SALESMAN_SESSION {
        bigint id PK
        bytea session_hash "hash token sesi"
        bigint salesman_id FK
        bigint depo_id FK
        uuid auth_uid
        timestamptz expires_at
        boolean revoked
    }
    AUDIT_LOG {
        bigint id PK
        timestamptz ts
        text actor
        bigint depo_id
        text action
        jsonb detail
    }
```

---

## 2. Alur Autentikasi — Depo + Salesman-PIN

```mermaid
sequenceDiagram
    autonumber
    actor U as Depo (perangkat bersama)
    participant FE as Web Sales Portal
    participant AUTH as Supabase Auth
    participant DB as Postgres (RPC + RLS)

    U->>FE: Login depo (username + password)
    FE->>AUTH: signIn
    AUTH-->>FE: JWT (auth.uid)
    Note over FE,DB: Semua RPC berikutnya membawa JWT depo

    FE->>DB: auth_list_salesmen()
    DB-->>FE: daftar salesman depo ini (tanpa PIN)
    U->>FE: pilih profil (ala Netflix) + input PIN

    FE->>DB: auth_open_session(salesman_id, pin)
    Note over DB: verifikasi PIN (bcrypt)<br/>5x gagal -> lockout 15 mnt
    alt PIN benar
        DB->>DB: buat salesman_session (simpan hash)
        DB-->>FE: session_token (256-bit, sekali tampil) + expiry 12 jam
    else PIN salah
        DB->>DB: failed_pin++, audit PIN_FAIL
        DB-->>FE: error PIN_INVALID
    end

    Note over FE,DB: Aksi sales mengirim session_token.<br/>Validasi sesi + cocokkan depo JWT tiap request
```

---

## 3. Alur Registrasi Outlet — Token → Submit → Validasi → WhatsApp

```mermaid
sequenceDiagram
    autonumber
    actor S as Salesman
    participant FE as Sales Portal
    actor O as Outlet
    participant RE as Register Page
    participant DB as Postgres (RPC)
    participant WA as WhatsApp Business (Edge Fn)

    S->>FE: pilih outlet (miliknya)
    FE->>DB: sales_generate_token(session, outlet_id)
    Note over DB: cek outlet milik salesman ini<br/>token 256-bit, simpan HASH
    DB-->>FE: raw_token + expiry
    FE-->>S: QR / link = ...?t={raw_token}
    Note right of FE: URL tak berisi PII / outlet_id

    S->>O: kirim QR / link
    O->>RE: buka link
    RE->>DB: pub_resolve_token(t)
    DB-->>RE: outlet_name, outlet_id, depo (read-only)
    O->>RE: isi WhatsApp + NPWP + consent
    RE->>DB: pub_submit_registration(t, phone, npwp, consent)

    Note over DB: enkripsi PII (pgp_sym) + HMAC hash<br/>token -> USED (sekali pakai)
    DB->>DB: run_validation_pipeline()
    DB-->>RE: submission_code + status (REVIEW)
    RE-->>O: tombol "Verify via WhatsApp"

    O->>WA: kirim "VERIFY {code} {token}"
    WA->>DB: wa_apply_verification(code, token, sender)
    Note over DB: phone_verified = true HANYA jika<br/>sender == nomor terdaftar
    DB->>DB: pipeline re-run -> bisa jadi VERIFIED
    DB-->>WA: status akhir
```

---

## 4. Pipeline Validasi — Penentuan Status

```mermaid
flowchart TD
    A[Submission masuk] --> B{Format phone & NPWP valid?}
    B -- tidak --> R[REJECTED]
    B -- ya --> C[Hitung sinyal anomali]

    C --> C1[Duplikat nomor lintas outlet]
    C --> C2[Duplikat NPWP lintas outlet]
    C --> C3[Velocity abnormal 5 mnt]
    C --> C4[NPWP tak cocok master]
    C --> C5[Pola data berulang]

    C1 & C2 & C3 & C4 & C5 --> D[risk_score 0-100 + risk_reason]

    D --> E{risk_score >= 60?}
    E -- ya --> R
    E -- tidak --> F{Bersih & phone_verified?}
    F -- "ya (no dup, match, risk<30, WA verified)" --> V[VERIFIED]
    F -- tidak --> W[REVIEW]

    style R fill:#fbe9e9,stroke:#b23b3b
    style V fill:#e6f4ec,stroke:#1f8a5b
    style W fill:#f6efd6,stroke:#b8860b
```

---

## 5. Lapisan Keamanan (RLS + Enkripsi)

```mermaid
flowchart LR
    subgraph Public
      ANON[Outlet / anon]
    end
    subgraph Internal
      DEPO[Depo JWT / authenticated]
      SVC[service_role / compliance]
    end

    ANON -->|hanya RPC publik| RPC1[pub_resolve_token<br/>pub_submit_registration]
    DEPO -->|RPC + tabel ter-RLS| RLS{{RLS: depo_id = current_depo_id}}
    SVC -->|bypass RLS, teraudit| PII[admin_reveal_pii<br/>wa_apply_verification]

    RPC1 --> DBW[(Postgres)]
    RLS --> DBW
    PII --> DBW

    DBW --- ENC[/PII terenkripsi pgp_sym<br/>token & PIN & sesi -> hash saja/]
    DBW --- COL[/Column grant: ciphertext & pin_hash<br/>disembunyikan dari depo/]
    DBW --- AUD[/audit_log: setiap aksi sensitif/]

    style RLS fill:#e8eef7,stroke:#14315e
    style ENC fill:#f6efd6,stroke:#c9a227
```

---

Sumber skema & fungsi: `db/01_schema.sql`, `db/02_rls.sql`, `db/03_functions.sql`.
Penjelasan lengkap: `docs/ARCHITECTURE.md`.
