-- ============================================================================
--  SAYEMBARA OUTLET NASIONAL — RPC functions (business logic)
--  03_functions.sql
-- ----------------------------------------------------------------------------
--  All client interaction goes through these functions (Supabase RPC / PostgREST
--  or Edge Functions). SECURITY DEFINER functions run with elevated rights but
--  each one re-checks the caller's depo / salesman session explicitly.
--
--  Naming:  auth_*      login / PIN / session
--           sales_*     internal sales portal
--           pub_*       public outlet registration (anon)
--           wa_*        whatsapp verification
--           dash_*      dashboard aggregation
--           admin_*     service_role / compliance only
-- ============================================================================

-- ----------------------------------------------------------------------------
--  Helpers
-- ----------------------------------------------------------------------------

-- Deterministic HMAC of a normalized personal value (for dedup).
create or replace function hmac_hash(p_value text)
returns bytea language sql stable as $$
  select hmac(coalesce(p_value,''), coalesce(app_pepper(),'dev-pepper'), 'sha256')
$$;

-- Symmetric encrypt/decrypt of personal data.
create or replace function pii_enc(p_value text)
returns bytea language sql stable as $$
  select pgp_sym_encrypt(coalesce(p_value,''), coalesce(app_enc_key(),'dev-key'))
$$;
create or replace function pii_dec(p_cipher bytea)
returns text language sql stable as $$
  select pgp_sym_decrypt(p_cipher, coalesce(app_enc_key(),'dev-key'))
$$;

-- Normalization (mirror of the Apps Script pipeline).
create or replace function normalize_phone(p text)
returns text language plpgsql immutable as $$
declare d text;
begin
  d := regexp_replace(coalesce(p,''), '[^0-9+]', '', 'g');
  d := regexp_replace(d, '^\+', '');
  if left(d,1) = '0' then d := '62' || substr(d,2); end if;
  if left(d,2) <> '62' and left(d,1) = '8' then d := '62' || d; end if;
  return d;
end $$;

create or replace function validate_phone(p text)
returns boolean language sql immutable as $$
  select coalesce(p,'') ~ '^628[0-9]{7,11}$'
$$;

create or replace function normalize_npwp(p text)
returns text language sql immutable as $$
  select regexp_replace(coalesce(p,''), '[^0-9]', '', 'g')
$$;

create or replace function validate_npwp(p text)
returns boolean language sql immutable as $$
  select length(coalesce(p,'')) in (15, 16)
$$;

create or replace function mask_phone(last3 text)
returns text language sql immutable as $$
  select case when last3 is null or last3='' then '' else '62••••' || last3 end
$$;
create or replace function mask_npwp(last3 text)
returns text language sql immutable as $$
  select case when last3 is null or last3='' then '' else '••••••••••' || last3 end
$$;

-- Simple fixed-window rate limiter. Raises on exceed.
create or replace function rl_check(p_actor text, p_bucket text,
                                    p_max int, p_window interval)
returns void language plpgsql security definer set search_path = public as $$
declare v_start timestamptz := date_trunc('minute', now());
        v_count int;
begin
  insert into rate_limit(actor, bucket, window_start, counter)
    values (p_actor, p_bucket, v_start, 1)
  on conflict (actor, bucket, window_start)
    do update set counter = rate_limit.counter + 1
  returning counter into v_count;
  if v_count > p_max then
    raise exception 'RATE_LIMIT' using errcode = 'P0001';
  end if;
end $$;

create or replace function audit(p_actor text, p_depo bigint, p_action text,
                                 p_detail jsonb default '{}', p_ip text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log(actor, depo_id, action, detail, ip_hint)
  values (p_actor, p_depo, p_action, coalesce(p_detail,'{}'::jsonb), p_ip);
end $$;

-- ============================================================================
--  AUTH — salesman PIN + session
--  Depo already authenticated via Supabase Auth (JWT). These add the salesman
--  sub-identity on top.
-- ============================================================================

-- List salesman profiles for the logged-in depo (Netflix-style picker).
-- No PIN, no secrets returned.
create or replace function auth_list_salesmen()
returns table (salesman_id bigint, sales_code text, full_name text,
               has_pin boolean, locked boolean)
language sql stable security definer set search_path = public as $$
  select s.id, s.sales_code, s.full_name,
         (s.pin_hash is not null),
         (s.locked_until is not null and s.locked_until > now())
  from salesman s
  where s.depo_id = current_depo_id()
    and s.is_active
  order by s.full_name
$$;

-- Set / reset a salesman PIN (only within the caller's depo).
create or replace function auth_set_pin(p_salesman_id bigint, p_pin text)
returns void language plpgsql security definer set search_path = public as $$
declare v_depo bigint := current_depo_id();
begin
  if v_depo is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'PIN_FORMAT'; end if;
  update salesman
     set pin_hash = crypt(p_pin, gen_salt('bf', 10)),
         pin_set_at = now(), failed_pin = 0, locked_until = null
   where id = p_salesman_id and depo_id = v_depo;
  if not found then raise exception 'SALESMAN_NOT_IN_DEPO'; end if;
  perform audit(v_depo::text, v_depo, 'PIN_SET', jsonb_build_object('salesman_id', p_salesman_id));
end $$;

-- Verify PIN, open a salesman session, return the RAW session token (shown once).
create or replace function auth_open_session(p_salesman_id bigint, p_pin text,
                                             p_ip text default null)
returns table (session_token text, salesman_id bigint, full_name text, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare v_depo bigint := current_depo_id();
        v_sal  salesman%rowtype;
        v_raw  text;
        v_exp  timestamptz := now() + interval '12 hours';
begin
  if v_depo is null then raise exception 'NOT_AUTHENTICATED'; end if;
  perform rl_check('depo:'||v_depo::text, 'pin', 30, interval '1 minute');

  select * into v_sal from salesman
    where id = p_salesman_id and depo_id = v_depo and is_active;
  if not found then raise exception 'SALESMAN_NOT_IN_DEPO'; end if;

  if v_sal.locked_until is not null and v_sal.locked_until > now() then
    raise exception 'PIN_LOCKED';
  end if;
  if v_sal.pin_hash is null then raise exception 'PIN_NOT_SET'; end if;

  if crypt(p_pin, v_sal.pin_hash) <> v_sal.pin_hash then
    update salesman
       set failed_pin = failed_pin + 1,
           locked_until = case when failed_pin + 1 >= 5
                               then now() + interval '15 minutes' else null end
     where id = p_salesman_id;
    perform audit(v_sal.sales_code, v_depo, 'PIN_FAIL',
                  jsonb_build_object('salesman_id', p_salesman_id), p_ip);
    raise exception 'PIN_INVALID';
  end if;

  update salesman set failed_pin = 0, locked_until = null where id = p_salesman_id;

  v_raw := encode(gen_random_bytes(32), 'hex');
  insert into salesman_session(session_hash, salesman_id, depo_id, auth_uid, expires_at)
    values (digest(v_raw, 'sha256'), p_salesman_id, v_depo, auth.uid(), v_exp);

  perform audit(v_sal.sales_code, v_depo, 'SESSION_OPEN',
                jsonb_build_object('salesman_id', p_salesman_id), p_ip);

  return query select v_raw, v_sal.id, v_sal.full_name, v_exp;
end $$;

-- Internal: resolve a session token to a validated salesman (or raise).
create or replace function _session_salesman(p_session_token text)
returns salesman_session
language plpgsql volatile security definer set search_path = public as $$
declare v_row salesman_session%rowtype;
begin
  select * into v_row from salesman_session
    where session_hash = digest(coalesce(p_session_token,''), 'sha256')
      and not revoked
      and expires_at > now()
      and depo_id = current_depo_id();   -- must match the logged-in depo JWT
  if not found then raise exception 'SESSION_INVALID'; end if;
  update salesman_session set last_seen_at = now() where id = v_row.id;
  return v_row;
end $$;

-- ============================================================================
--  SALES PORTAL
-- ============================================================================

-- Search outlets for the ACTIVE salesman only (defense in depth: depo via RLS
-- context + salesman via session).
create or replace function sales_search_outlets(p_session_token text, p_query text)
returns table (outlet_id text, outlet_name text, kode_toko text, depo text,
               wa_status text, npwp_status text, eligible boolean)
language plpgsql volatile security definer set search_path = public as $$
declare v_sess salesman_session;
        v_q text := lower(trim(coalesce(p_query,'')));
begin
  v_sess := _session_salesman(p_session_token);
  perform rl_check('sales:'||v_sess.salesman_id::text, 'search', 120, interval '1 minute');
  return query
    select o.outlet_id, o.outlet_name, o.kode_toko, d.depo_name,
           o.wa_status, o.npwp_status, o.eligible
    from outlet_master o join depo d on d.id = o.depo_id
    where o.depo_id = v_sess.depo_id
      and o.sales_id = v_sess.salesman_id
      and (v_q = '' or lower(o.outlet_name) like '%'||v_q||'%'
                    or lower(o.kode_toko)  like '%'||v_q||'%'
                    or lower(o.outlet_id)  like '%'||v_q||'%')
    order by o.outlet_name
    limit 50;
end $$;

-- Generate a registration token. Returns the RAW token (goes into the URL/QR).
create or replace function sales_generate_token(p_session_token text, p_outlet_id text,
                                                p_ttl_hours int default 72)
returns table (token text, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare v_sess salesman_session;
        v_outlet outlet_master%rowtype;
        v_raw text;
        v_exp timestamptz;
begin
  v_sess := _session_salesman(p_session_token);
  perform rl_check('sales:'||v_sess.salesman_id::text, 'generate', 60, interval '1 minute');

  select * into v_outlet from outlet_master
    where outlet_id = p_outlet_id
      and depo_id = v_sess.depo_id
      and sales_id = v_sess.salesman_id;
  if not found then raise exception 'OUTLET_NOT_OWNED'; end if;

  v_raw := encode(gen_random_bytes(32), 'hex');   -- 256-bit
  v_exp := now() + make_interval(hours => greatest(1, least(p_ttl_hours, 168)));

  insert into token_map(token_hash, outlet_ref, depo_id, sales_id, created_by, expires_at, status)
    values (digest(v_raw,'sha256'), v_outlet.id, v_sess.depo_id,
            v_sess.salesman_id, v_sess.salesman_id, v_exp, 'ACTIVE');

  perform audit((select sales_code from salesman where id=v_sess.salesman_id),
                v_sess.depo_id, 'TOKEN_GENERATED',
                jsonb_build_object('outlet_id', p_outlet_id));

  return query select v_raw, v_exp;
end $$;

-- ============================================================================
--  PUBLIC OUTLET REGISTRATION (anon)
-- ============================================================================

-- Resolve a raw token to read-only outlet context. No sensitive data returned.
create or replace function pub_resolve_token(p_token text)
returns table (ok boolean, outlet_id text, outlet_name text, depo text, message text)
language plpgsql volatile security definer set search_path = public as $$
declare v_tok token_map%rowtype;
        v_outlet outlet_master%rowtype;
begin
  select * into v_tok from token_map where token_hash = digest(coalesce(p_token,''),'sha256');
  if not found then
    return query select false, null::text, null::text, null::text, 'Link tidak dikenali.'; return;
  end if;
  if v_tok.status <> 'ACTIVE' then
    return query select false, null::text, null::text, null::text, 'Link sudah tidak aktif.'; return;
  end if;
  if v_tok.expires_at < now() then
    update token_map set status='EXPIRED' where id=v_tok.id;
    return query select false, null::text, null::text, null::text, 'Link sudah kedaluwarsa.'; return;
  end if;
  select * into v_outlet from outlet_master where id = v_tok.outlet_ref;
  select true, v_outlet.outlet_id, v_outlet.outlet_name,
         (select depo_name from depo where id = v_outlet.depo_id), null::text
    into ok, outlet_id, outlet_name, depo, message;
  return next;
end $$;

-- Submit registration. outlet is derived from the token; outlet never types code.
create or replace function pub_submit_registration(p_token text, p_phone text,
                                                   p_npwp text, p_consent boolean,
                                                   p_ip text default null)
returns table (ok boolean, submission_code text, overall_status submission_status,
               wa_link text)
language plpgsql security definer set search_path = public as $$
declare v_tok token_map%rowtype;
        v_outlet outlet_master%rowtype;
        v_phone text; v_npwp text;
        v_code text; v_sub_id bigint;
        v_wa_business text := coalesce(current_setting('app.wa_business', true), '628000000000');
begin
  select * into v_tok from token_map where token_hash = digest(coalesce(p_token,''),'sha256');
  if not found or v_tok.status <> 'ACTIVE' or v_tok.expires_at < now() then
    raise exception 'TOKEN_INVALID';
  end if;
  perform rl_check('token:'||v_tok.id::text, 'submit', 5, interval '5 minutes');

  if not coalesce(p_consent,false) then raise exception 'CONSENT_REQUIRED'; end if;

  v_phone := normalize_phone(p_phone);
  v_npwp  := normalize_npwp(p_npwp);
  if not validate_phone(v_phone) then raise exception 'PHONE_INVALID'; end if;
  if not validate_npwp(v_npwp)  then raise exception 'NPWP_INVALID';  end if;

  select * into v_outlet from outlet_master where id = v_tok.outlet_ref;
  v_code := 'SUB-' || upper(substr(encode(gen_random_bytes(6),'hex'),1,8));

  insert into submission(submission_code, token_ref, outlet_ref, depo_id, sales_id,
      phone_enc, npwp_enc, phone_hash, npwp_hash, phone_last3, npwp_last3,
      consent, consent_at, ip_hint)
    values (v_code, v_tok.id, v_outlet.id, v_tok.depo_id, v_tok.sales_id,
      pii_enc(v_phone), pii_enc(v_npwp), hmac_hash(v_phone), hmac_hash(v_npwp),
      right(v_phone,3), right(v_npwp,3), true, now(), p_ip)
    returning id into v_sub_id;

  update token_map set status='USED' where id = v_tok.id;
  perform audit('anon', v_tok.depo_id, 'SUBMISSION_CREATED',
                jsonb_build_object('submission_code', v_code, 'outlet_id', v_outlet.outlet_id), p_ip);

  perform run_validation_pipeline(v_sub_id);

  select s.overall_status into overall_status from submission s where s.id = v_sub_id;
  ok := true; submission_code := v_code;
  wa_link := 'https://wa.me/'||v_wa_business||'?text='||
             replace('VERIFY '||v_code||' '||p_token, ' ', '%20');
  return next;
end $$;

-- ============================================================================
--  VALIDATION PIPELINE
-- ============================================================================
create or replace function run_validation_pipeline(p_sub_id bigint)
returns submission_status
language plpgsql security definer set search_path = public as $$
declare s submission%rowtype;
        v_phone text; v_npwp text;
        v_phone_valid boolean; v_npwp_valid boolean;
        v_dup_phone int; v_dup_npwp int;
        v_match boolean; v_velocity int;
        v_pattern_hits int := 0;
        v_score int := 0; v_reasons text[] := '{}';
        v_status submission_status;
        v_existing bytea;
begin
  select * into s from submission where id = p_sub_id;
  v_phone := pii_dec(s.phone_enc); v_npwp := pii_dec(s.npwp_enc);
  v_phone_valid := validate_phone(v_phone);
  v_npwp_valid  := validate_npwp(v_npwp);

  -- duplicate detection via HMAC hashes (no decryption of other rows)
  select count(distinct outlet_ref) into v_dup_phone from submission
    where phone_hash = s.phone_hash and id <> s.id;
  select count(distinct outlet_ref) into v_dup_npwp from submission
    where npwp_hash = s.npwp_hash and id <> s.id;

  -- match against outlet_master existing NPWP hash
  select existing_npwp_hash into v_existing from outlet_master where id = s.outlet_ref;
  v_match := (v_existing is null) or (v_existing = s.npwp_hash);

  -- velocity: submissions by same salesman in 5 min
  select count(*) into v_velocity from submission
    where sales_id = s.sales_id and submitted_at >= now() - interval '5 minutes';

  -- repeated patterns
  if v_phone ~ '^62(\d)\1+$' then v_pattern_hits := v_pattern_hits + 1; end if;
  if v_npwp ~ '^(\d)\1+$'    then v_pattern_hits := v_pattern_hits + 1; end if;

  -- risk scoring (rule-based)
  if v_dup_phone > 0 then v_score := v_score + 35;
     v_reasons := v_reasons || ('Nomor dipakai '||(v_dup_phone+1)||' outlet'); end if;
  if v_dup_npwp > 0 then v_score := v_score + 35;
     v_reasons := v_reasons || ('NPWP di '||(v_dup_npwp+1)||' outlet'); end if;
  if v_velocity > 5 then v_score := v_score + 20;
     v_reasons := v_reasons || ('Velocity abnormal ('||v_velocity||')'); end if;
  if not v_match then v_score := v_score + 25;
     v_reasons := v_reasons || 'NPWP tidak cocok master'; end if;
  if v_pattern_hits > 0 then v_score := v_score + 15;
     v_reasons := v_reasons || 'Pola data berulang'; end if;
  v_score := greatest(0, least(100, v_score));

  -- resolve overall status
  if not v_phone_valid or not v_npwp_valid or v_score >= 60 then
    v_status := 'REJECTED';
  elsif v_dup_phone = 0 and v_dup_npwp = 0 and v_match and v_score < 30
        and s.phone_verified then
    v_status := 'VERIFIED';
  else
    v_status := 'REVIEW';
  end if;

  insert into validation_result(submission_ref, outlet_ref, phone_valid, npwp_valid,
      dup_phone, dup_npwp, outlet_match, risk_score, risk_reason, overall_status)
    values (s.id, s.outlet_ref, v_phone_valid, v_npwp_valid,
      v_dup_phone>0, v_dup_npwp>0, v_match, v_score,
      array_to_string(v_reasons,' | '), v_status)
  on conflict (submission_ref) do update
    set phone_valid=excluded.phone_valid, npwp_valid=excluded.npwp_valid,
        dup_phone=excluded.dup_phone, dup_npwp=excluded.dup_npwp,
        outlet_match=excluded.outlet_match, risk_score=excluded.risk_score,
        risk_reason=excluded.risk_reason, overall_status=excluded.overall_status,
        evaluated_at=now();

  update submission
    set overall_status = v_status, risk_score = v_score,
        risk_reason = array_to_string(v_reasons,' | ')
    where id = s.id;

  return v_status;
end $$;

-- Official DJP validation — PLACEHOLDER. No scraping. Stays PENDING until a
-- sanctioned API is wired via an Edge Function that calls this to persist.
create or replace function validate_npwp_official(p_sub_id bigint)
returns npwp_official_status
language plpgsql security definer set search_path = public as $$
begin
  -- integrate official DJP web service here; until then remain PENDING.
  return 'PENDING_OFFICIAL_VALIDATION';
end $$;

-- ============================================================================
--  WHATSAPP VERIFICATION
--  phone_verified becomes true ONLY when sender == registered number.
--  Called by the WhatsApp webhook Edge Function (service_role).
-- ============================================================================
create or replace function wa_apply_verification(p_submission_code text,
                                                 p_token text, p_sender text,
                                                 p_is_mock boolean default false)
returns table (ok boolean, phone_verified boolean, overall_status submission_status, message text)
language plpgsql security definer set search_path = public as $$
declare s submission%rowtype; v_sender_hash bytea;
begin
  select * into s from submission where submission_code = p_submission_code;
  if not found then return query select false,false,null::submission_status,'Submission not found'; return; end if;

  -- token must match the one bound to this submission
  if not exists (select 1 from token_map t where t.id = s.token_ref
                 and t.token_hash = digest(coalesce(p_token,''),'sha256')) then
    perform audit('whatsapp', s.depo_id, 'WA_TOKEN_MISMATCH',
                  jsonb_build_object('submission', p_submission_code, 'mock', p_is_mock));
    return query select false,false,null::submission_status,'Token mismatch'; return;
  end if;

  v_sender_hash := hmac_hash(normalize_phone(p_sender));
  if v_sender_hash <> s.phone_hash then
    perform audit('whatsapp', s.depo_id, 'WA_SENDER_MISMATCH',
                  jsonb_build_object('submission', p_submission_code, 'mock', p_is_mock));
    return query select false,false,null::submission_status,'Sender does not match registered number'; return;
  end if;

  update submission set phone_verified = true, phone_verified_at = now() where id = s.id;
  perform audit('whatsapp', s.depo_id,
                case when p_is_mock then 'WA_VERIFIED_MOCK' else 'WA_VERIFIED' end,
                jsonb_build_object('submission', p_submission_code));
  perform run_validation_pipeline(s.id);

  return query
    select true, true, sub.overall_status, 'verified'::text
    from submission sub where sub.id = s.id;
end $$;

-- ============================================================================
--  ADMIN MOCK (prototype only) — depo-scoped WhatsApp simulator
--  Clearly a MOCK: lets a logged-in depo simulate an inbound WA for one of its
--  own submissions WITHOUT the raw token or service_role. Never treat as
--  production verification. Real verification path = wa_apply_verification via
--  the WhatsApp webhook Edge Function (service_role).
-- ============================================================================
create or replace function admin_mock_wa_verify(p_submission_code text, p_sender text)
returns table (ok boolean, phone_verified boolean, overall_status submission_status, message text)
language plpgsql volatile security definer set search_path = public as $$
declare s submission%rowtype;
begin
  select * into s from submission
    where submission_code = p_submission_code and depo_id = current_depo_id();
  if not found then
    return query select false, false, null::submission_status, 'Submission not in your depo';
    return;
  end if;

  if hmac_hash(normalize_phone(p_sender)) <> s.phone_hash then
    perform audit('mock', s.depo_id, 'WA_SENDER_MISMATCH_MOCK',
                  jsonb_build_object('submission', p_submission_code));
    return query select false, false, null::submission_status,
                        'MOCK: sender does not match registered number';
    return;
  end if;

  update submission set phone_verified = true, phone_verified_at = now() where id = s.id;
  perform audit('mock', s.depo_id, 'WA_VERIFIED_MOCK',
                jsonb_build_object('submission', p_submission_code));
  perform run_validation_pipeline(s.id);

  return query
    select true, true, sub.overall_status, 'MOCK: verified (not production)'::text
    from submission sub where sub.id = s.id;
end $$;

-- List recent submissions (masked) for the depo's admin/mock UI.
create or replace function admin_list_submissions()
returns table (submission_code text, outlet_id text, phone_masked text,
               npwp_masked text, phone_verified boolean,
               npwp_official npwp_official_status, overall_status submission_status,
               risk_score int, risk_reason text)
language sql stable security definer set search_path = public as $$
  select s.submission_code, o.outlet_id,
         mask_phone(s.phone_last3), mask_npwp(s.npwp_last3),
         s.phone_verified, s.npwp_official, s.overall_status,
         s.risk_score, s.risk_reason
  from submission s join outlet_master o on o.id = s.outlet_ref
  where s.depo_id = current_depo_id()
  order by s.submitted_at desc
  limit 25
$$;

-- ============================================================================
--  DASHBOARD
-- ============================================================================
-- Latest submission per outlet (materialized-friendly view).
create or replace view v_latest_submission as
  select distinct on (outlet_ref) *
  from submission
  order by outlet_ref, submitted_at desc;

-- KPI + leaderboards scoped to the caller's depo via RLS on the base tables.
-- For nation-wide/HQ dashboards use the service_role variant with no filter.
create or replace function dash_kpis()
returns jsonb
language sql stable security definer set search_path = public as $$
  with eligible as (
    select id from outlet_master
    where eligible and depo_id = current_depo_id()
  ),
  latest as (
    select ls.* from v_latest_submission ls
    where ls.depo_id = current_depo_id()
  )
  select jsonb_build_object(
    'eligible',      (select count(*) from eligible),
    'submitted',     (select count(*) from latest),
    'wa_verified',   (select count(*) from latest where phone_verified),
    'npwp_complete', (select count(*) from latest where npwp_last3 <> ''),
    'fully_verified',(select count(*) from latest where overall_status='VERIFIED'),
    'review',        (select count(*) from latest where overall_status='REVIEW'),
    'rejected',      (select count(*) from latest where overall_status='REJECTED'),
    'completion_pct',
       case when (select count(*) from eligible) = 0 then 0
            else round(100.0 * (select count(*) from latest where overall_status='VERIFIED')
                       / (select count(*) from eligible)) end
  )
$$;

-- Leaderboard by a chosen dimension (verified/eligible ratio, NOT raw count).
-- p_dim in ('salesman','ass','bm','rbm','depo','area')
create or replace function dash_leaderboard(p_dim text)
returns table (name text, verified bigint, eligible bigint, rate int)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
  with o as (
    select om.*, s.full_name as salesman_name, d.depo_name, a.area_name
    from outlet_master om
    join depo d on d.id = om.depo_id
    left join salesman s on s.id = om.sales_id
    left join area a on a.id = d.area_id
    where om.depo_id = current_depo_id()
  ),
  latest as (select * from v_latest_submission where depo_id = current_depo_id()),
  grouped as (
    select
      case p_dim
        when 'salesman' then coalesce(o.salesman_name,'—')
        when 'ass' then coalesce(o.ass_name,'—')
        when 'bm'  then coalesce(o.bm_name,'—')
        when 'rbm' then coalesce(o.rbm_name,'—')
        when 'depo' then coalesce(o.depo_name,'—')
        when 'area' then coalesce(o.area_name,'—')
        else '—' end as grp,
      o.eligible as is_elig,
      (exists (select 1 from latest l where l.outlet_ref = o.id
               and l.overall_status='VERIFIED')) as is_verified
    from o
  )
  select grp,
         count(*) filter (where is_verified and is_elig)::bigint,
         count(*) filter (where is_elig)::bigint,
         case when count(*) filter (where is_elig) = 0 then 0
              else round(100.0 * count(*) filter (where is_verified and is_elig)
                         / count(*) filter (where is_elig))::int end
  from grouped
  group by grp
  order by 4 desc, 2 desc;
end $$;

-- ============================================================================
--  ADMIN / COMPLIANCE  (service_role only — never granted to anon/authenticated)
-- ============================================================================
-- Decrypt a single submission's PII, writing an audit entry. Restricted role.
create or replace function admin_reveal_pii(p_submission_code text, p_reason text)
returns table (phone text, npwp text)
language plpgsql security definer set search_path = public as $$
declare s submission%rowtype;
begin
  select * into s from submission where submission_code = p_submission_code;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform audit(coalesce(auth.uid()::text,'service'), s.depo_id, 'PII_REVEAL',
                jsonb_build_object('submission', p_submission_code, 'reason', p_reason));
  return query select pii_dec(s.phone_enc), pii_dec(s.npwp_enc);
end $$;

-- ============================================================================
--  GRANTS  (which role may call which RPC)
-- ============================================================================
-- Public registration:
grant execute on function pub_resolve_token(text) to anon, authenticated;
grant execute on function pub_submit_registration(text,text,text,boolean,text) to anon, authenticated;

-- Depo (authenticated) sales portal + auth:
grant execute on function auth_list_salesmen() to authenticated;
grant execute on function auth_set_pin(bigint,text) to authenticated;
grant execute on function auth_open_session(bigint,text,text) to authenticated;
grant execute on function sales_search_outlets(text,text) to authenticated;
grant execute on function sales_generate_token(text,text,int) to authenticated;
grant execute on function dash_kpis() to authenticated;
grant execute on function dash_leaderboard(text) to authenticated;
grant execute on function admin_mock_wa_verify(text,text) to authenticated;
grant execute on function admin_list_submissions() to authenticated;

-- WhatsApp + compliance are service_role only (default: not granted to others).
revoke all on function wa_apply_verification(text,text,text,boolean) from anon, authenticated;
revoke all on function admin_reveal_pii(text,text) from anon, authenticated;
revoke all on function run_validation_pipeline(bigint) from anon, authenticated;
