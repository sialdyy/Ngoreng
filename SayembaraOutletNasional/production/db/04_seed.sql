-- ============================================================================
--  SAYEMBARA OUTLET NASIONAL — sample seed data
--  04_seed.sql   (run AFTER 01..03; safe to re-run — uses on conflict)
-- ----------------------------------------------------------------------------
--  NOTE ON AUTH: depo.auth_uid must point to a real Supabase Auth user id.
--  For local testing set dev secrets first:
--     alter database postgres set app.enc_key = 'dev-enc-key-change-me';
--     alter database postgres set app.pepper  = 'dev-pepper-change-me';
--     alter database postgres set app.wa_business = '628123456789';
--  Then create depo auth users in Supabase Auth and paste their UUIDs below.
-- ============================================================================

insert into area (area_code, area_name, region) values
  ('DKI',  'Area DKI',  'Jawa'),
  ('JABAR','Area Jabar','Jawa'),
  ('JATIM','Area Jatim','Jawa')
on conflict (area_code) do nothing;

-- Two demo depos. Replace auth_uid with real Supabase Auth user UUIDs.
insert into depo (depo_code, depo_name, area_id, auth_uid) values
  ('DPJKT1', 'Depo Jakarta 1', (select id from area where area_code='DKI'),
     '00000000-0000-0000-0000-000000000001'),
  ('DPBDG',  'Depo Bandung',   (select id from area where area_code='JABAR'),
     '00000000-0000-0000-0000-000000000002')
on conflict (depo_code) do nothing;

-- Salesmen (PIN set separately via auth_set_pin, or seeded here with bcrypt).
insert into salesman (sales_code, full_name, depo_id, ass_name, bm_name, rbm_name, pin_hash, pin_set_at)
values
  ('SLS-000101','Andi Salesman',(select id from depo where depo_code='DPJKT1'),
     'Budi ASS','Citra BM','Dedi RBM', crypt('1234', gen_salt('bf',10)), now()),
  ('SLS-000102','Gita Salesman',(select id from depo where depo_code='DPBDG'),
     'Eka ASS','Fajar BM','Dedi RBM', crypt('5678', gen_salt('bf',10)), now())
on conflict (sales_code) do nothing;

-- Outlets.
insert into outlet_master (outlet_id, outlet_name, kode_toko, depo_id, sales_id,
    ass_name, bm_name, rbm_name, existing_npwp_hash, eligible)
values
  ('OTL-1001','Toko Maju Jaya','KT-8801',
     (select id from depo where depo_code='DPJKT1'),
     (select id from salesman where sales_code='SLS-000101'),
     'Budi ASS','Citra BM','Dedi RBM', null, true),
  ('OTL-1002','Warung Berkah','KT-8802',
     (select id from depo where depo_code='DPJKT1'),
     (select id from salesman where sales_code='SLS-000101'),
     'Budi ASS','Citra BM','Dedi RBM',
     hmac_hash('091234567890123'), true),
  ('OTL-1003','Sumber Rejeki','KT-8803',
     (select id from depo where depo_code='DPBDG'),
     (select id from salesman where sales_code='SLS-000102'),
     'Eka ASS','Fajar BM','Dedi RBM', null, true),
  ('OTL-1004','Toko Sentosa','KT-8804',
     (select id from depo where depo_code='DPBDG'),
     (select id from salesman where sales_code='SLS-000102'),
     'Eka ASS','Fajar BM','Dedi RBM', null, false)
on conflict (outlet_id) do nothing;

-- ---------------------------------------------------------------------------
--  Bulk-load pattern for the real 500k master (use \copy, not INSERTs):
--
--    create temp table stg (outlet_id text, outlet_name text, kode_toko text,
--      depo_code text, sales_code text, ass text, bm text, rbm text,
--      existing_npwp text, eligible boolean);
--    \copy stg from 'outlets.csv' with (format csv, header true);
--
--    insert into outlet_master (outlet_id, outlet_name, kode_toko, depo_id,
--        sales_id, ass_name, bm_name, rbm_name, existing_npwp_hash, eligible)
--    select s.outlet_id, s.outlet_name, s.kode_toko,
--           d.id, sm.id, s.ass, s.bm, s.rbm,
--           case when s.existing_npwp is null or s.existing_npwp='' then null
--                else hmac_hash(normalize_npwp(s.existing_npwp)) end,
--           coalesce(s.eligible,true)
--    from stg s
--    join depo d on d.depo_code = s.depo_code
--    left join salesman sm on sm.sales_code = s.sales_code
--    on conflict (outlet_id) do update
--      set outlet_name=excluded.outlet_name, kode_toko=excluded.kode_toko,
--          depo_id=excluded.depo_id, sales_id=excluded.sales_id,
--          eligible=excluded.eligible, updated_at=now();
-- ---------------------------------------------------------------------------
