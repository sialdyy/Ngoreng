-- ============================================================================
--  SAYEMBARA OUTLET NASIONAL — Row Level Security
--  02_rls.sql
-- ----------------------------------------------------------------------------
--  Principle: the DEPO auth user is the hard boundary. Every internal table is
--  readable/writable ONLY for rows belonging to the caller's depo. The public
--  (anon) role has NO direct table access — it uses SECURITY DEFINER RPCs only.
--
--  Roles (Supabase defaults):
--    anon           — unauthenticated (public outlet registration)
--    authenticated  — logged-in depo user (JWT with auth.uid())
--    service_role   — backend/admin (bypasses RLS; used by Edge Functions/cron)
-- ============================================================================

-- Map the current JWT user to its depo id. STABLE + SECURITY DEFINER so the
-- policies can consult the depo table regardless of the caller's own grants.
create or replace function current_depo_id()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select d.id
  from depo d
  where d.auth_uid = auth.uid()
    and d.is_active
  limit 1
$$;

-- Enable RLS everywhere.
alter table area              enable row level security;
alter table depo              enable row level security;
alter table salesman          enable row level security;
alter table outlet_master     enable row level security;
alter table token_map         enable row level security;
alter table submission        enable row level security;
alter table validation_result enable row level security;
alter table salesman_session  enable row level security;
alter table rate_limit        enable row level security;
alter table audit_log         enable row level security;

-- Force RLS even for the table owner, so nothing leaks by accident.
alter table submission        force row level security;
alter table outlet_master     force row level security;
alter table token_map         force row level security;

-- ----------------------------------------------------------------------------
--  AREA — read-only reference, visible to any authenticated depo.
-- ----------------------------------------------------------------------------
drop policy if exists area_read on area;
create policy area_read on area
  for select to authenticated
  using (true);

-- ----------------------------------------------------------------------------
--  DEPO — a depo can read only its own row.
-- ----------------------------------------------------------------------------
drop policy if exists depo_self on depo;
create policy depo_self on depo
  for select to authenticated
  using (id = current_depo_id());

-- ----------------------------------------------------------------------------
--  SALESMAN — a depo sees only its own salesmen (never pin_hash: see column
--  privileges / the RPC that returns a safe projection).
-- ----------------------------------------------------------------------------
drop policy if exists salesman_by_depo on salesman;
create policy salesman_by_depo on salesman
  for select to authenticated
  using (depo_id = current_depo_id());

-- ----------------------------------------------------------------------------
--  OUTLET MASTER — depo can read only its own outlets.
--  (Per-salesman filtering is applied on top by the app / RPC; the hard
--   guarantee here is: never another depo's outlets.)
-- ----------------------------------------------------------------------------
drop policy if exists outlet_by_depo on outlet_master;
create policy outlet_by_depo on outlet_master
  for select to authenticated
  using (depo_id = current_depo_id());

-- Depo may update only display/status fields on its own outlets (via RPC
-- normally). No insert/delete from the client — master is loaded by ETL/admin.
drop policy if exists outlet_update_by_depo on outlet_master;
create policy outlet_update_by_depo on outlet_master
  for update to authenticated
  using (depo_id = current_depo_id())
  with check (depo_id = current_depo_id());

-- ----------------------------------------------------------------------------
--  TOKEN MAP — depo can read its own tokens (for status), never other depos'.
--  Creation happens via SECURITY DEFINER RPC generate_token().
-- ----------------------------------------------------------------------------
drop policy if exists token_by_depo on token_map;
create policy token_by_depo on token_map
  for select to authenticated
  using (depo_id = current_depo_id());

-- ----------------------------------------------------------------------------
--  SUBMISSION — depo reads its own submissions only. Note: phone_enc/npwp_enc
--  are still encrypted; decryption is a separate, audited RPC restricted to
--  service_role / a 'compliance' role (see ARCHITECTURE.md). Column-level
--  privileges below prevent authenticated depo from selecting the ciphertext.
-- ----------------------------------------------------------------------------
drop policy if exists submission_by_depo on submission;
create policy submission_by_depo on submission
  for select to authenticated
  using (depo_id = current_depo_id());

-- ----------------------------------------------------------------------------
--  VALIDATION RESULT — follows the submission's depo.
-- ----------------------------------------------------------------------------
drop policy if exists vr_by_depo on validation_result;
create policy vr_by_depo on validation_result
  for select to authenticated
  using (exists (
    select 1 from submission s
    where s.id = validation_result.submission_ref
      and s.depo_id = current_depo_id()
  ));

-- ----------------------------------------------------------------------------
--  SALESMAN SESSION — a depo can see/revoke only its own sessions.
-- ----------------------------------------------------------------------------
drop policy if exists sess_by_depo on salesman_session;
create policy sess_by_depo on salesman_session
  for select to authenticated
  using (depo_id = current_depo_id());
drop policy if exists sess_revoke_by_depo on salesman_session;
create policy sess_revoke_by_depo on salesman_session
  for update to authenticated
  using (depo_id = current_depo_id())
  with check (depo_id = current_depo_id());

-- ----------------------------------------------------------------------------
--  AUDIT LOG — depo can read its own audit entries (read-only).
-- ----------------------------------------------------------------------------
drop policy if exists audit_by_depo on audit_log;
create policy audit_by_depo on audit_log
  for select to authenticated
  using (depo_id = current_depo_id());

-- rate_limit: no client policy -> only SECURITY DEFINER RPCs touch it.

-- ============================================================================
--  COLUMN-LEVEL PRIVILEGES  (defense in depth for personal data)
--  Even though RLS scopes rows, we further deny the encrypted/hash columns to
--  the 'authenticated' (depo) role so a compromised depo JWT cannot exfiltrate
--  ciphertext in bulk. Depo UIs get masked values via RPCs instead.
-- ============================================================================
revoke all on submission from authenticated;
grant select
  (id, submission_code, outlet_ref, depo_id, sales_id,
   phone_last3, npwp_last3, consent, submitted_at,
   phone_verified, phone_verified_at, npwp_official,
   overall_status, risk_score, risk_reason, created_at)
  on submission to authenticated;
-- phone_enc, npwp_enc, phone_hash, npwp_hash are intentionally NOT granted.

-- salesman: hide pin_hash from the depo role.
revoke all on salesman from authenticated;
grant select
  (id, sales_code, full_name, depo_id, ass_name, bm_name, rbm_name,
   is_active, created_at, pin_set_at, locked_until)
  on salesman to authenticated;

-- Reference/other tables: normal select is fine (RLS still applies).
grant select on area, depo, outlet_master, token_map,
  validation_result, salesman_session, audit_log to authenticated;
grant update (wa_status, npwp_status) on outlet_master to authenticated;
