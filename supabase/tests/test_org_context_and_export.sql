-- =============================================================================
-- Tests for migration 20260906090000: the active-park context, the invitation
-- flow, and the Darwin Core export.
--
-- Run against a local Supabase:
--   psql "$DB_URL" -f supabase/tests/test_org_context_and_export.sql
--
-- Every block prints PASS or FAIL. In the NEGATIVES section an ERROR is a pass.
-- =============================================================================
\set ON_ERROR_STOP off
begin;

-- ---------------------------------------------------------------- fixtures --
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','ranger.multi@test.invalid'),
  ('22222222-2222-2222-2222-222222222222','admin.alpha@test.invalid'),
  ('33333333-3333-3333-3333-333333333333','outsider@test.invalid'),
  ('44444444-4444-4444-4444-444444444444','newcomer@test.invalid')
on conflict (id) do nothing;

insert into public.organizations
  (id, name, slug, country_code, dataset_name, rights_holder, default_license,
   contact_name, contact_email, boundary)
values
  ('aaaaaaaa-0000-0000-0000-000000000001','TEST NP Alpha','test-np-alpha','AT',
   'TEST NP Alpha vascular plant occurrences','Nationalpark Alpha',
   'http://creativecommons.org/licenses/by/4.0/legalcode','A. Admin','admin@alpha.invalid',
   ST_Multi(ST_SetSRID(ST_MakeEnvelope(12.5,47.0,13.0,47.3),4326))),
  ('bbbbbbbb-0000-0000-0000-000000000002','TEST NP Beta','test-np-beta','AT',
   null, null, null, null, null, null)     -- deliberately incomplete: tests readiness
on conflict (id) do nothing;

insert into public.memberships (user_id, org_id, role) values
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','member'),
  ('11111111-1111-1111-1111-111111111111','bbbbbbbb-0000-0000-0000-000000000002','member'),
  ('22222222-2222-2222-2222-222222222222','aaaaaaaa-0000-0000-0000-000000000001','admin'),
  ('33333333-3333-3333-3333-333333333333','bbbbbbbb-0000-0000-0000-000000000002','member')
on conflict do nothing;

insert into public.taxa (id, scientific_name, taxon_rank, kingdom, family, genus,
                         specific_epithet, scientific_name_authorship, vernacular_name_de, gbif_taxon_key)
values ('cccccccc-0000-0000-0000-000000000001','Leontopodium nivale','species','Plantae','Asteraceae',
        'Leontopodium','nivale','(Ten.) Huet ex Hand.-Mazz.','Edelweiss',3111243)
on conflict (id) do nothing;
insert into public.taxa (id, scientific_name, taxon_rank, kingdom, family, genus)
values ('cccccccc-0000-0000-0000-000000000002','Hieracium','genus','Plantae','Asteraceae','Hieracium')
on conflict (id) do nothing;


\echo ''
\echo '############ 1. ACTIVE PARK CONTEXT ############'

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

\echo '-- 1a. the multi-park ranger sees both parks in the switcher'
select case when count(*) = 2 then 'PASS' else 'FAIL' end as t1_switcher_lists_both_parks,
       count(*) from public.my_parks;

\echo '-- 1b. switching park is persisted server-side'
select public.set_active_org('bbbbbbbb-0000-0000-0000-000000000002');
select case when bool_or(is_active and name = 'TEST NP Beta') then 'PASS' else 'FAIL' end
         as t2_active_park_switched,
       string_agg(name || case when is_active then ' [ACTIVE]' else '' end, ', ' order by name)
from public.my_parks;

reset role; reset request.jwt.claim.sub;

\echo '-- 1c. an outsider sees only their own park'
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select case when count(*) = 1 then 'PASS' else 'FAIL' end as t3_outsider_sees_one_park,
       count(*) from public.my_parks;
reset role; reset request.jwt.claim.sub;


\echo ''
\echo '############ 2. INVITATION FLOW ############'

\echo '-- 2a. an admin invites a newcomer to their own park'
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into public.invitations (org_id, email, role, invited_by)
values ('aaaaaaaa-0000-0000-0000-000000000001','newcomer@test.invalid','member',
        '22222222-2222-2222-2222-222222222222');
select case when count(*) = 1 then 'PASS' else 'FAIL' end as t4_admin_can_invite, count(*)
from public.invitations;
reset role; reset request.jwt.claim.sub;

\echo '-- 2b. the newcomer accepts on first sign-in and lands in that park'
set local role authenticated;
set local request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select case when public.accept_pending_invitations() = 1 then 'PASS' else 'FAIL' end
         as t5_invitation_accepted;
select case when count(*) = 1 and bool_or(is_active) then 'PASS' else 'FAIL' end
         as t6_newcomer_has_park_and_it_is_active,
       string_agg(name || ' / ' || role, ', ') from public.my_parks;
reset role; reset request.jwt.claim.sub;

\echo '-- 2c. accepting twice is a no-op, not a duplicate membership'
set local role authenticated;
set local request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select case when public.accept_pending_invitations() = 0 then 'PASS' else 'FAIL' end
         as t7_second_accept_is_noop;
reset role; reset request.jwt.claim.sub;


\echo ''
\echo '############ 3. NEGATIVES - an ERROR here is a PASS ############'

\echo '-- 3a. a non-admin cannot invite (expect: RLS violation)'
savepoint sp_3a;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into public.invitations (org_id, email, role, invited_by)
values ('aaaaaaaa-0000-0000-0000-000000000001','sneaky@test.invalid','admin',
        '11111111-1111-1111-1111-111111111111');
rollback to savepoint sp_3a;
reset role; reset request.jwt.claim.sub;

\echo '-- 3b. an admin of Alpha cannot invite into Beta (expect: RLS violation)'
savepoint sp_3b;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into public.invitations (org_id, email, role, invited_by)
values ('bbbbbbbb-0000-0000-0000-000000000002','sneaky@test.invalid','admin',
        '22222222-2222-2222-2222-222222222222');
rollback to savepoint sp_3b;
reset role; reset request.jwt.claim.sub;

\echo '-- 3c. nobody can set an active park they do not belong to (expect: not a member)'
savepoint sp_3c;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select public.set_active_org('aaaaaaaa-0000-0000-0000-000000000001');
rollback to savepoint sp_3c;
reset role; reset request.jwt.claim.sub;

\echo '-- 3d. an outsider cannot see an admin''s invitations'
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select case when count(*) = 0 then 'PASS' else 'FAIL' end as t8_non_admin_sees_no_invitations,
       count(*) from public.invitations;
reset role; reset request.jwt.claim.sub;


\echo ''
\echo '############ 4. DARWIN CORE EXPORT ############'

-- A survey event, an observation inside it, three identifications, one photo.
insert into public.survey_events (id, org_id, event_type, event_started_at, event_ended_at,
                                  sampling_protocol, event_duration_min, target_taxonomic_scope,
                                  is_absence_reported, site_count, created_by_user_id)
values ('99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'Survey','2026-07-14T09:00:00+02','2026-07-14T11:00:00+02',
        'timed meander, 2 h, vascular plants',120,'Tracheophyta',true,1,
        '11111111-1111-1111-1111-111111111111');

insert into public.observations
  (id, org_id, survey_event_id, event_date, geometry, coordinate_uncertainty_m,
   georeference_protocol, recorded_by_user_id, recorded_by, habitat, individual_count, country_code)
values
 ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  '99999999-0000-0000-0000-000000000001','2026-07-14T09:41:00+02',
  ST_SetSRID(ST_MakePoint(12.6963,47.1097),4326),4.2,'device GNSS, single fix',
  '11111111-1111-1111-1111-111111111111','R. Strammer','alpine grassland',3,'AT'),
 -- a sensitive record, to prove generalisation happens at the boundary
 ('eeeeeeee-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001',
  null,'2026-07-14T10:15:00+02',
  ST_SetSRID(ST_MakePoint(12.712345,47.118765),4326),3.1,'device GNSS, single fix',
  '11111111-1111-1111-1111-111111111111','R. Strammer','scree',1,'AT'),
 -- a withheld record, which must never appear in the export
 ('eeeeeeee-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001',
  null,'2026-07-14T10:30:00+02',
  ST_SetSRID(ST_MakePoint(12.72,47.12),4326),3.0,'device GNSS, single fix',
  '11111111-1111-1111-1111-111111111111','R. Strammer','scree',1,'AT');

update public.observations set sensitivity='generalised' where id='eeeeeeee-0000-0000-0000-000000000002';
update public.observations set sensitivity='withheld'    where id='eeeeeeee-0000-0000-0000-000000000003';

insert into public.identifications
  (observation_id, org_id, source, provider, taxon_id, taxon_rank_answered,
   confidence_raw, confidence_calibrated, checklist_masked, is_accepted, identified_by,
   verification_status, date_identified)
values
 ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','offline_model',
  'thesis-offline','cccccccc-0000-0000-0000-000000000002','genus',0.61,0.48,true,false,
  'thesis-offline mnv3s-int8-v3','unverified','2026-07-14T09:41:10+02'),
 ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','online_service',
  'plantnet','cccccccc-0000-0000-0000-000000000001','species',0.88,null,false,false,
  'Pl@ntNet API','unverified','2026-07-14T18:02:00+02');

insert into public.identifications
  (observation_id, org_id, source, taxon_id, taxon_rank_answered, is_accepted,
   identified_by_user_id, identified_by, verification_status, date_identified)
values
 ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','human',
  'cccccccc-0000-0000-0000-000000000001','species',true,'22222222-2222-2222-2222-222222222222',
  'M. Mittlboeck','verified','2026-07-20T11:00:00+02'),
 ('eeeeeeee-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','human',
  'cccccccc-0000-0000-0000-000000000001','species',true,'22222222-2222-2222-2222-222222222222',
  'M. Mittlboeck','verified','2026-07-20T11:05:00+02'),
 ('eeeeeeee-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001','human',
  'cccccccc-0000-0000-0000-000000000001','species',true,'22222222-2222-2222-2222-222222222222',
  'M. Mittlboeck','verified','2026-07-20T11:10:00+02');

insert into public.observation_media (observation_id, org_id, storage_path, organ, is_primary, license)
values ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'obs/eeee0001/flower.jpg','flower',true,'http://creativecommons.org/licenses/by/4.0/legalcode');

\echo '-- 4a. the withheld record never leaves'
select case when count(*) = 2 then 'PASS' else 'FAIL' end as t9_withheld_excluded,
       count(*) as exported_rows from public.dwc_occurrence_export
 where org_id = 'aaaaaaaa-0000-0000-0000-000000000001';

\echo '-- 4b. the sensitive record is generalised at the boundary, not in storage'
select case when "decimalLatitude" = 47.12 and "decimalLongitude" = 12.71
                 and "coordinateUncertaintyInMeters" = 1000
                 and "dataGeneralizations" is not null
            then 'PASS' else 'FAIL' end as t10_generalised_at_export,
       "decimalLatitude", "decimalLongitude", "coordinateUncertaintyInMeters"
from public.dwc_occurrence_export where "occurrenceID" = 'eeeeeeee-0000-0000-0000-000000000002';

select case when ST_Y(geometry)::numeric = 47.118765 then 'PASS' else 'FAIL' end
         as t11_stored_coordinate_untouched,
       ST_Y(geometry) as stored_lat
from public.observations where id = 'eeeeeeee-0000-0000-0000-000000000002';

\echo '-- 4c. the accepted determination is the identification; the rest are previousIdentifications'
select case when "scientificName" = 'Leontopodium nivale'
                 and "identifiedBy" = 'M. Mittlboeck'
                 and "identificationVerificationStatus" = 'verified'
                 and "previousIdentifications" like '%Hieracium (offline_model%'
                 and "previousIdentifications" like '%Leontopodium nivale (online_service%'
            then 'PASS' else 'FAIL' end as t12_dwc_identification_projection
from public.dwc_occurrence_export where "occurrenceID" = 'eeeeeeee-0000-0000-0000-000000000001';

\echo '-- 4d. GBIF required and strongly-recommended terms are all populated'
select case when "occurrenceID" is not null and "basisOfRecord" = 'HumanObservation'
                 and "scientificName" is not null and "taxonRank" is not null
                 and "kingdom" = 'Plantae' and "eventDate" is not null
                 and "decimalLatitude" is not null and "decimalLongitude" is not null
                 and "geodeticDatum" = 'WGS84' and "coordinateUncertaintyInMeters" is not null
                 and "countryCode" = 'AT' and "license" is not null
                 and "occurrenceStatus" = 'present'
            then 'PASS' else 'FAIL' end as t13_gbif_terms_complete
from public.dwc_occurrence_export where "occurrenceID" = 'eeeeeeee-0000-0000-0000-000000000001';

\echo '-- 4e. the readiness view names what a partner would reject'
select case when count(*) filter (where cardinality(blockers) > 0) = 0 then 'PASS' else 'FAIL' end
         as t14_alpha_is_export_ready,
       count(*) filter (where cardinality(blockers) > 0) as blocked_rows
from public.dwc_export_readiness where org_id = 'aaaaaaaa-0000-0000-0000-000000000001';

\echo '-- 4f. an incompletely configured park is correctly reported as NOT ready'
insert into public.observations (id, org_id, event_date, geometry, recorded_by)
values ('eeeeeeee-0000-0000-0000-000000000009','bbbbbbbb-0000-0000-0000-000000000002',
        '2026-07-16T10:00:00+02', ST_SetSRID(ST_MakePoint(14.62,47.56),4326),'B. Ranger');
select case when cardinality(blockers) >= 4 then 'PASS' else 'FAIL' end as t15_beta_not_ready,
       blockers
from public.dwc_export_readiness where observation_id = 'eeeeeeee-0000-0000-0000-000000000009';

\echo ''
\echo '-- one exported row, in full, for eyeballing:'
\x on
select * from public.dwc_occurrence_export where "occurrenceID" = 'eeeeeeee-0000-0000-0000-000000000001';
\x off

\echo ''
\echo '############ 5. THE SOFT BOUNDARY CHECK ############'
select case when public.observation_is_within_org_boundary(
                    'aaaaaaaa-0000-0000-0000-000000000001',
                    ST_SetSRID(ST_MakePoint(12.6963,47.1097),4326)) then 'PASS' else 'FAIL' end
         as t16_inside_boundary_is_true;
select case when not public.observation_is_within_org_boundary(
                    'aaaaaaaa-0000-0000-0000-000000000001',
                    ST_SetSRID(ST_MakePoint(9.0,47.0),4326)) then 'PASS' else 'FAIL' end
         as t17_outside_boundary_is_false;
select case when public.observation_is_within_org_boundary(
                    'bbbbbbbb-0000-0000-0000-000000000002',
                    ST_SetSRID(ST_MakePoint(9.0,47.0),4326)) then 'PASS' else 'FAIL' end
         as t18_no_boundary_configured_never_warns;

\echo ''
\echo '############ 6. GRANTS - every relation the app reads must be readable ############'
-- The class of bug this catches: RLS decides which rows, the GRANT decides
-- whether the role may read the relation at all. A view created without a
-- grant fails with "permission denied" for every user, and no amount of
-- correct policy writing fixes it. observations_current shipped without one.
select case when count(*) = 0 then 'PASS' else 'FAIL' end as t19_all_app_relations_granted,
       coalesce(string_agg(rel, ', '), 'none missing') as missing_grant
from (
  select r.rel
  from (values ('observations'),('identifications'),('observation_media'),
               ('survey_events'),('taxa'),('checklist_entries'),('model_versions'),
               ('user_settings'),('invitations'),('observations_current'),
               ('my_parks'),('dwc_occurrence_export'),('dwc_export_readiness')) as r(rel)
  where not has_table_privilege('authenticated', ('public.' || r.rel)::regclass, 'SELECT')
) q;

\echo ''
\echo '############ 7. EXPORT POLICY - unverified determinations stay home ############'
-- Observation 1 is expert-verified; add one whose only determination is the
-- on-device model's, and check it does not reach the export.
insert into public.observations (id, org_id, event_date, geometry,
                                 coordinate_uncertainty_m, recorded_by, country_code)
values ('eeeeeeee-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001',
        '2026-07-17T09:00:00+02', ST_SetSRID(ST_MakePoint(12.70,47.11),4326), 5.0,
        'R. Strammer','AT');
insert into public.identifications (observation_id, org_id, source, provider, taxon_id,
                                    taxon_rank_answered, confidence_raw, checklist_masked,
                                    is_accepted, identified_by, verification_status)
values ('eeeeeeee-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001',
        'offline_model','thesis-offline','cccccccc-0000-0000-0000-000000000002','genus',
        0.55,true,true,'thesis-offline','unverified');

select case when count(*) = 0 then 'PASS' else 'FAIL' end as t20_unverified_not_exported,
       count(*) from public.dwc_occurrence_export
 where "occurrenceID" = 'eeeeeeee-0000-0000-0000-00000000000a';

select case when 'determination not confirmed by a person' = any(blockers)
            then 'PASS' else 'FAIL' end as t21_readiness_explains_why,
       blockers
from public.dwc_export_readiness
where observation_id = 'eeeeeeee-0000-0000-0000-00000000000a';

\echo '-- a park may opt in to publishing unverified determinations'
update public.organizations set export_unverified = true
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select case when count(*) = 1 then 'PASS' else 'FAIL' end as t22_optin_lets_it_through,
       count(*) from public.dwc_occurrence_export
 where "occurrenceID" = 'eeeeeeee-0000-0000-0000-00000000000a';

\echo ''
\echo '############ 8. THE EXPORT CONTRACT - everything in the view is publishable ############'
-- Beta has a verified record but no datasetName, rightsHolder or licence.
-- It must export NOTHING, rather than rows a partner would have to query.
insert into public.identifications (observation_id, org_id, source, taxon_id,
                                    taxon_rank_answered, is_accepted,
                                    identified_by_user_id, identified_by, verification_status)
values ('eeeeeeee-0000-0000-0000-000000000009','bbbbbbbb-0000-0000-0000-000000000002',
        'human','cccccccc-0000-0000-0000-000000000001','species',true,
        '33333333-3333-3333-3333-333333333333','B. Ranger','verified');

select case when count(*) = 0 then 'PASS' else 'FAIL' end as t23_incomplete_park_exports_nothing,
       count(*) from public.dwc_occurrence_export
 where org_id = 'bbbbbbbb-0000-0000-0000-000000000002';

\echo '-- once the park is configured, the same record becomes publishable'
update public.organizations
   set dataset_name = 'TEST NP Beta occurrences',
       rights_holder = 'Nationalpark Beta',
       default_license = 'http://creativecommons.org/licenses/by/4.0/legalcode'
 where id = 'bbbbbbbb-0000-0000-0000-000000000002';

select case when count(*) = 1 then 'PASS' else 'FAIL' end as t24_configured_park_exports,
       count(*) from public.dwc_occurrence_export
 where org_id = 'bbbbbbbb-0000-0000-0000-000000000002';

\echo '-- and nothing in the view is missing a GBIF-required or -recommended term'
select case when count(*) = 0 then 'PASS' else 'FAIL' end as t25_no_incomplete_row_in_export,
       count(*) as incomplete_rows
from public.dwc_occurrence_export
where "occurrenceID" is null or "basisOfRecord" is null or "scientificName" is null
   or "eventDate" is null or "decimalLatitude" is null or "decimalLongitude" is null
   or "geodeticDatum" is null or "countryCode" is null or "license" is null
   or "rightsHolder" is null or "datasetName" is null or "occurrenceStatus" is null;

rollback;
\echo ''
\echo 'Rolled back - the database is unchanged.'
