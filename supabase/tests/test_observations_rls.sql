-- =============================================================================
-- Isolation and integrity test for the observations schema.
--
-- ADR 003 says the two-user/two-org isolation "should later get automated
-- tests". This is that test, extended to the tables added in
-- 20260905120000_create_observations_and_identifications.sql.
--
-- It is also evidence for objective O7 (100 % of cross-organisation access
-- attempts rejected) and for the append-only property that proposition P1
-- depends on.
--
-- Run against a local Supabase:
--     supabase db reset
--     psql "$(supabase status -o env | grep DB_URL | cut -d= -f2- | tr -d '"')" \
--          -f supabase/tests/test_observations_rls.sql
--
-- Every block prints PASS or FAIL. Errors are expected in the negative blocks;
-- an error there IS the pass.
-- =============================================================================
\set ON_ERROR_STOP off
\timing off

begin;

-- ---------------------------------------------------------------- fixtures --
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','ranger.multi@test.invalid'),
  ('22222222-2222-2222-2222-222222222222','expert.tauern@test.invalid'),
  ('33333333-3333-3333-3333-333333333333','other.org@test.invalid')
on conflict (id) do nothing;

insert into public.organizations (id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','TEST NP Alpha'),
  ('bbbbbbbb-0000-0000-0000-000000000002','TEST NP Beta')
on conflict (id) do nothing;

-- The multi-park ranger: one identity, membership in BOTH orgs.
insert into public.memberships (user_id, org_id, role) values
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','member'),
  ('11111111-1111-1111-1111-111111111111','bbbbbbbb-0000-0000-0000-000000000002','member'),
  ('22222222-2222-2222-2222-222222222222','aaaaaaaa-0000-0000-0000-000000000001','admin'),
  ('33333333-3333-3333-3333-333333333333','bbbbbbbb-0000-0000-0000-000000000002','member')
on conflict do nothing;

insert into public.taxa (id, scientific_name, taxon_rank, genus, specific_epithet, gbif_taxon_key) values
  ('cccccccc-0000-0000-0000-000000000001','Leontopodium nivale','species','Leontopodium','nivale',3111243)
on conflict (id) do nothing;
insert into public.taxa (id, scientific_name, taxon_rank, genus) values
  ('cccccccc-0000-0000-0000-000000000002','Hieracium','genus','Hieracium')
on conflict (id) do nothing;

insert into public.model_versions (id, name, version, arm, class_count, quantization, temperature)
values ('dddddddd-0000-0000-0000-000000000001','thesis-offline','test-v0','arm2_finetuned',1089,'int8',1.4)
on conflict (id) do nothing;

-- One observation in each org, both recorded by the multi-park ranger.
insert into public.observations (id, org_id, event_date, geometry, coordinate_uncertainty_m,
                                 recorded_by_user_id, recorded_by)
values
 ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  '2026-07-14T09:41:00+02', ST_SetSRID(ST_MakePoint(12.6963,47.1097),4326), 4.2,
  '11111111-1111-1111-1111-111111111111','Test Ranger'),
 ('eeeeeeee-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002',
  '2026-07-15T10:00:00+02', ST_SetSRID(ST_MakePoint(14.6200,47.5600),4326), 6.8,
  '11111111-1111-1111-1111-111111111111','Test Ranger')
on conflict (id) do nothing;

-- The three views on observation 1: offline (genus, masked) -> online -> expert.
insert into public.identifications
  (id, observation_id, org_id, source, provider, model_version_id, taxon_id, taxon_rank_answered,
   confidence_raw, confidence_calibrated, checklist_masked, top_k, is_accepted, identified_by,
   verification_status, date_identified)
values
 ('ffffffff-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'offline_model','thesis-offline','dddddddd-0000-0000-0000-000000000001',
  'cccccccc-0000-0000-0000-000000000002','genus',0.61,0.48,true,
  '[{"name":"Hieracium","score":0.61}]'::jsonb,true,'thesis-offline test-v0','unverified','2026-07-14T09:41:10+02'),
 ('ffffffff-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'online_service','plantnet',null,'cccccccc-0000-0000-0000-000000000001','species',
  0.88,null,false,'[{"name":"Leontopodium nivale","score":0.88}]'::jsonb,false,'Pl@ntNet API','unverified','2026-07-14T18:02:00+02')
on conflict (id) do nothing;

insert into public.identifications
  (id, observation_id, org_id, source, taxon_id, taxon_rank_answered, is_accepted,
   identified_by_user_id, identified_by, verification_status, date_identified)
values ('ffffffff-0000-0000-0000-000000000003','eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'human','cccccccc-0000-0000-0000-000000000001','species',false,
        '22222222-2222-2222-2222-222222222222','Test Expert','verified','2026-07-20T11:00:00+02')
on conflict (id) do nothing;


\echo ''
\echo '################ 1. ISOLATION ################'

set local role authenticated;

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select case when count(*) = 2 then 'PASS' else 'FAIL' end as t1_multipark_ranger_sees_both_orgs,
       count(*) as observations_visible from public.observations;

set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select case when count(*) = 1 then 'PASS' else 'FAIL' end as t2_alpha_expert_sees_only_alpha,
       count(*) from public.observations;

set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select case when count(*) = 1 then 'PASS' else 'FAIL' end as t3_beta_user_sees_only_beta,
       count(*) from public.observations;
select case when count(*) = 0 then 'PASS' else 'FAIL' end as t4_beta_user_sees_no_alpha_identifications,
       count(*) from public.identifications;
select case when count(*) = 0 then 'PASS' else 'FAIL' end as t5_beta_user_sees_no_alpha_media,
       count(*) from public.observation_media;

reset role; reset request.jwt.claim.sub;


\echo ''
\echo '################ 2. NEGATIVES - an ERROR here is a PASS ################'

\echo '-- 2a. cross-org insert must be rejected server-side (expect: RLS violation)'
savepoint sp_2a;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
insert into public.observations (org_id, event_date, geometry, recorded_by)
values ('aaaaaaaa-0000-0000-0000-000000000001','2026-07-16T10:00:00+02',
        ST_SetSRID(ST_MakePoint(12.7,47.1),4326),'intruder');
rollback to savepoint sp_2a;
reset role; reset request.jwt.claim.sub;

\echo '-- 2b. identifications are append-only: no UPDATE grant (expect: permission denied)'
savepoint sp_2b;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
update public.identifications set taxon_id = 'cccccccc-0000-0000-0000-000000000002'
 where id = 'ffffffff-0000-0000-0000-000000000002';
rollback to savepoint sp_2b;
reset role; reset request.jwt.claim.sub;

\echo '-- 2c. accept_identification refuses a non-member (expect: not a member)'
savepoint sp_2c;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select public.accept_identification('ffffffff-0000-0000-0000-000000000001');
rollback to savepoint sp_2c;
reset role; reset request.jwt.claim.sub;

\echo '-- 2d. at most one accepted identification per observation (expect: unique violation)'
savepoint sp_2d;
update public.identifications set is_accepted = true where id = 'ffffffff-0000-0000-0000-000000000002';
rollback to savepoint sp_2d;

\echo '-- 2e. only the offline model may claim checklist_masked (expect: check violation)'
savepoint sp_2e;
insert into public.identifications (observation_id, org_id, source, provider, taxon_id, confidence_raw, checklist_masked)
values ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'online_service','plantnet','cccccccc-0000-0000-0000-000000000001',0.9,true);
rollback to savepoint sp_2e;

\echo '-- 2f. a machine identification must carry a score (expect: check violation)'
savepoint sp_2f;
insert into public.identifications (observation_id, org_id, source, provider, taxon_id)
values ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'offline_model','thesis-offline','cccccccc-0000-0000-0000-000000000001');
rollback to savepoint sp_2f;

\echo '-- 2g. a human identification must name a human (expect: check violation)'
savepoint sp_2g;
insert into public.identifications (observation_id, org_id, source, taxon_id, identified_by)
values ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'human','cccccccc-0000-0000-0000-000000000001','anonymous');
rollback to savepoint sp_2g;

\echo '-- 2h. an absence needs a survey event (expect: check violation)'
savepoint sp_2h;
insert into public.observations (org_id, event_date, geometry, recorded_by, occurrence_status)
values ('aaaaaaaa-0000-0000-0000-000000000001','2026-07-16T10:00:00+02',
        ST_SetSRID(ST_MakePoint(12.7,47.1),4326),'Test Ranger','absent');
rollback to savepoint sp_2h;

\echo '-- 2i. geometry must be point or polygon, not a line (expect: check violation)'
savepoint sp_2i;
insert into public.observations (org_id, event_date, geometry, recorded_by)
values ('aaaaaaaa-0000-0000-0000-000000000001','2026-07-16T10:00:00+02',
        ST_SetSRID(ST_MakeLine(ST_MakePoint(12.7,47.1),ST_MakePoint(12.8,47.2)),4326),'Test Ranger');
rollback to savepoint sp_2i;

\echo '-- 2j. a species-rank taxon must have a specific epithet (expect: check violation)'
savepoint sp_2j;
insert into public.taxa (scientific_name, taxon_rank, genus) values ('Bogus species','species','Bogus');
rollback to savepoint sp_2j;

\echo '-- 2k. a child row may not disagree with its parent about org_id (expect: FK violation)'
savepoint sp_2k;
insert into public.identifications (observation_id, org_id, source, provider, taxon_id, confidence_raw)
values ('eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000002',
        'offline_model','thesis-offline','cccccccc-0000-0000-0000-000000000001',0.7);
rollback to savepoint sp_2k;


\echo ''
\echo '################ 3. THE MEASUREMENT SURVIVES ################'

\echo '-- 3a. accepting the expert determination supersedes, it does not overwrite'
-- accept_identification checks membership against auth.uid(), so the caller
-- must have an identity. Acting as the Alpha expert.
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.accept_identification('ffffffff-0000-0000-0000-000000000003');
reset request.jwt.claim.sub;
select case when count(*) = 3 then 'PASS' else 'FAIL' end as t6_all_three_identifications_still_present,
       count(*) from public.identifications where observation_id='eeeeeeee-0000-0000-0000-000000000001';
select case when count(*) = 1 then 'PASS' else 'FAIL' end as t7_exactly_one_accepted,
       count(*) from public.identifications
 where observation_id='eeeeeeee-0000-0000-0000-000000000001' and is_accepted;

\echo '-- 3b. P1 is computable from production rows: offline vs online vs expert truth'
select case when offline_answer is not null and online_answer is not null and expert_truth is not null
            then 'PASS' else 'FAIL' end as t8_p1_computable, *
from (
  select max(case when i.source='offline_model'  then t.scientific_name end) as offline_answer,
         max(case when i.source='offline_model'  then i.taxon_rank_answered end) as offline_rank,
         max(case when i.source='online_service' then t.scientific_name end) as online_answer,
         max(case when i.source='human'          then t.scientific_name end) as expert_truth,
         bool_or(i.source='offline_model' and i.checklist_masked)            as p2_mask_recorded
  from public.identifications i
  left join public.taxa t on t.id = i.taxon_id
  where i.observation_id = 'eeeeeeee-0000-0000-0000-000000000001'
) q;

\echo '-- 3c. the read-back view resolves to the accepted determination'
select case when identification_source = 'human' and verification_status = 'verified'
            then 'PASS' else 'FAIL' end as t9_view_shows_accepted,
       scientific_name, identification_source, taxon_rank_answered
from public.observations_current where id='eeeeeeee-0000-0000-0000-000000000001';

rollback;
\echo ''
\echo 'Rolled back - the database is unchanged.'
