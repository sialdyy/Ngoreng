-- ============================================================================
--  SAYEMBARA OUTLET NASIONAL — PostgreSQL / Supabase schema
--  01_schema.sql  —  tables, types, indexes
-- ----------------------------------------------------------------------------
--  Target: PostgreSQL 15+ (Supabase). Designed for ~500k outlets, ~300 depo,
--  thousands of salesmen, high concurrent public submissions.
--
--  Security model (summary — see docs/ARCHITECTURE.md):
--    * DEPO is the hard authentication boundary (one Supabase Auth user each).
--    * SALESMAN is a sub-identity inside a depo, gated by a bcrypt PIN and a
--      short-lived salesman_session token.
--    * Personal data (phone, NPWP) is stored ENCRYPTED (pgp_sym), plus a
--      deterministic HMAC hash for duplicate detection without decrypting.
--    * Row Level Security scopes every internal read/write to the caller's depo.
--    * Public (anon) outlets never touch tables directly — only SECURITY
--      DEFINER RPCs (resolve_token, submit_registration).
-- ============================================================================

create extension if not exists pgcrypto;      -- gen_random_bytes, crypt, hmac, pgp_sym_*
create extension if not exists citext;         -- case-insensitive text
create extension if not exists pg_trgm;        -- trigram index for name search

-- ----------------------------------------------------------------------------
--  Enums
-- ----------------------------------------------------------------------------
do $$ begin
  create type submission_status as enum ('VERIFIED', 'REVIEW', 'REJECTED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type npwp_official_status as enum
    ('PENDING_OFFICIAL_VALIDATION', 'DJP_VERIFIED', 'DJP_INVALID');
exception when duplicate_object then null; end $$;

do $$ begin
  create type token_status as enum ('ACTIVE', 'USED', 'EXPIRED', 'REVOKED');
exception when duplicate_object then null; end $$;

-- ----------------------------------------------------------------------------
--  Reference / org hierarchy
-- ----------------------------------------------------------------------------
create table if not exists area (
  id          bigint generated always as identity primary key,
  area_code   text not null unique,
  area_name   text not null,
  region      text
);

-- One DEPO == one authenticated principal. Linked to a Supabase Auth user.
create table if not exists depo (
  id          bigint generated always as identity primary key,
  depo_code   text not null unique,
  depo_name   text not null,
  area_id     bigint references area(id),
  -- Link to auth.users. Depo logs in with this account (email/username+pass).
  auth_uid    uuid unique,                 -- = auth.users.id (Supabase)
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists idx_depo_auth_uid on depo(auth_uid);

-- SALESMAN — sub-identity within a depo, protected by a PIN.
create table if not exists salesman (
  id            bigint generated always as identity primary key,
  sales_code    text not null unique,       -- e.g. SLS-000123
  full_name     text not null,
  depo_id       bigint not null references depo(id) on delete cascade,
  -- Hierarchy attributes (denormalized for leaderboard speed).
  ass_name      text,
  bm_name       text,
  rbm_name      text,
  pin_hash      text,                        -- bcrypt via crypt(); never plain
  pin_set_at    timestamptz,
  failed_pin    int not null default 0,
  locked_until  timestamptz,                 -- lockout after repeated bad PINs
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);
create index if not exists idx_salesman_depo on salesman(depo_id);

-- ----------------------------------------------------------------------------
--  OUTLET MASTER (~500k rows)
-- ----------------------------------------------------------------------------
create table if not exists outlet_master (
  id             bigint generated always as identity primary key,
  outlet_id      text not null unique,       -- business key, e.g. OTL-1001
  outlet_name    text not null,
  kode_toko      text not null,
  depo_id        bigint not null references depo(id),
  sales_id       bigint references salesman(id),
  ass_name       text,
  bm_name        text,
  rbm_name       text,
  -- Existing NPWP already known in master (for match). Stored as HMAC hash
  -- for matching; keep the plaintext ONLY if business truly needs it, else null.
  existing_npwp_hash bytea,
  wa_status      text default 'PENDING',
  npwp_status    text default 'PENDING',
  eligible       boolean not null default true,
  updated_at     timestamptz not null default now()
);
-- Hot lookups.
create index if not exists idx_outlet_depo    on outlet_master(depo_id);
create index if not exists idx_outlet_sales   on outlet_master(sales_id);
create index if not exists idx_outlet_eligible on outlet_master(eligible);
-- Fast case-insensitive search by name / code within a depo.
create index if not exists idx_outlet_name_trgm
  on outlet_master using gin (lower(outlet_name) gin_trgm_ops);
create index if not exists idx_outlet_kode    on outlet_master(lower(kode_toko));

-- ----------------------------------------------------------------------------
--  TOKEN MAP  (registration links)
-- ----------------------------------------------------------------------------
create table if not exists token_map (
  id           bigint generated always as identity primary key,
  -- We store only the HASH of the token; the raw token lives in the URL/QR.
  -- Even a DB dump cannot reconstruct working links.
  token_hash   bytea not null unique,
  outlet_ref   bigint not null references outlet_master(id) on delete cascade,
  depo_id      bigint not null references depo(id),
  sales_id     bigint references salesman(id),
  created_by   bigint references salesman(id),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  status       token_status not null default 'ACTIVE'
);
create index if not exists idx_token_outlet on token_map(outlet_ref);
create index if not exists idx_token_depo   on token_map(depo_id);
create index if not exists idx_token_status on token_map(status);

-- ----------------------------------------------------------------------------
--  SUBMISSION  (public outlet input) — personal data encrypted
-- ----------------------------------------------------------------------------
create table if not exists submission (
  id                    bigint generated always as identity primary key,
  submission_code       text not null unique,       -- SUB-XXXXXXXX (public id)
  token_ref             bigint references token_map(id),
  outlet_ref            bigint not null references outlet_master(id),
  depo_id               bigint not null references depo(id),
  sales_id              bigint references salesman(id),

  -- Encrypted personal data (pgp_sym_encrypt with key from Vault/GUC).
  phone_enc             bytea,
  npwp_enc              bytea,
  -- Deterministic HMAC (pepper) for duplicate detection WITHOUT decrypting.
  phone_hash            bytea,
  npwp_hash             bytea,
  -- Last 3 digits kept in clear ONLY for masked display; never the full value.
  phone_last3           text,
  npwp_last3            text,

  consent               boolean not null default false,
  consent_at            timestamptz,
  submitted_at          timestamptz not null default now(),

  phone_verified        boolean not null default false,
  phone_verified_at     timestamptz,
  npwp_official          npwp_official_status not null default 'PENDING_OFFICIAL_VALIDATION',

  overall_status        submission_status not null default 'REVIEW',
  risk_score            int not null default 0,
  risk_reason           text default '',

  ip_hint               text,
  created_at            timestamptz not null default now()
);
create index if not exists idx_sub_outlet on submission(outlet_ref);
create index if not exists idx_sub_depo   on submission(depo_id);
create index if not exists idx_sub_sales  on submission(sales_id);
create index if not exists idx_sub_status on submission(overall_status);
create index if not exists idx_sub_phone_hash on submission(phone_hash);
create index if not exists idx_sub_npwp_hash  on submission(npwp_hash);
-- Only the latest submission per outlet counts on the dashboard.
create index if not exists idx_sub_outlet_time on submission(outlet_ref, submitted_at desc);

-- ----------------------------------------------------------------------------
--  VALIDATION RESULT (pipeline output, 1:1 with latest evaluation)
-- ----------------------------------------------------------------------------
create table if not exists validation_result (
  id              bigint generated always as identity primary key,
  submission_ref  bigint not null references submission(id) on delete cascade,
  outlet_ref      bigint not null references outlet_master(id),
  phone_valid     boolean,
  npwp_valid      boolean,
  dup_phone       boolean,
  dup_npwp        boolean,
  outlet_match    boolean,
  risk_score      int,
  risk_reason     text,
  overall_status  submission_status,
  evaluated_at    timestamptz not null default now(),
  unique (submission_ref)
);

-- ----------------------------------------------------------------------------
--  SALESMAN SESSION  (Netflix-profile + PIN -> short-lived token)
-- ----------------------------------------------------------------------------
create table if not exists salesman_session (
  id             bigint generated always as identity primary key,
  session_hash   bytea not null unique,      -- hash of the session token
  salesman_id    bigint not null references salesman(id) on delete cascade,
  depo_id        bigint not null references depo(id),
  auth_uid       uuid not null,              -- depo auth user that opened it
  created_at     timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  expires_at     timestamptz not null,
  revoked        boolean not null default false
);
create index if not exists idx_sess_salesman on salesman_session(salesman_id);
create index if not exists idx_sess_depo on salesman_session(depo_id);

-- ----------------------------------------------------------------------------
--  RATE LIMIT  (per actor/bucket sliding counter)
-- ----------------------------------------------------------------------------
create table if not exists rate_limit (
  id          bigint generated always as identity primary key,
  actor       text not null,
  bucket      text not null,
  window_start timestamptz not null default now(),
  counter     int not null default 0,
  unique (actor, bucket, window_start)
);
create index if not exists idx_rl_actor on rate_limit(actor, bucket);

-- ----------------------------------------------------------------------------
--  AUDIT LOG
-- ----------------------------------------------------------------------------
create table if not exists audit_log (
  id          bigint generated always as identity primary key,
  ts          timestamptz not null default now(),
  actor       text,               -- depo auth_uid / salesman code / 'anon' / 'system'
  depo_id     bigint,
  action      text not null,
  detail      jsonb default '{}'::jsonb,
  ip_hint     text
);
create index if not exists idx_audit_depo on audit_log(depo_id);
create index if not exists idx_audit_action on audit_log(action);
create index if not exists idx_audit_ts on audit_log(ts desc);

-- ----------------------------------------------------------------------------
--  Secrets accessor
--  Store the encryption key + HMAC pepper in Supabase Vault, or (for
--  self-hosted) as database settings. These helpers read them.
--  Set via:  ALTER DATABASE postgres SET app.enc_key = '...';
--            ALTER DATABASE postgres SET app.pepper  = '...';
--  Prefer Supabase Vault in production (see docs/ARCHITECTURE.md).
-- ----------------------------------------------------------------------------
create or replace function app_enc_key() returns text
  language sql stable as $$ select current_setting('app.enc_key', true) $$;

create or replace function app_pepper() returns text
  language sql stable as $$ select current_setting('app.pepper', true) $$;
