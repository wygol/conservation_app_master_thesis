-- ============================================================================
-- seed.sql — LOCAL DEV ONLY. Runs automatically after migrations on every
-- `supabase db reset` (config.toml [db.seed]). Rebuilds a complete test world
-- so the RLS isolation test is ready seconds after a reset.
--
-- Test credentials (local only, never production):
--   usera@test.at / password123  → admin of "Org Alpha"
--   userb@test.at / password123  → admin of "Org Beta"
--
-- NOTE: inserting directly into auth.users is acceptable ONLY for local
-- seeding (runs as superuser, bypasses GoTrue). In production, users are
-- created exclusively through GoTrue sign-up/invites.
-- ============================================================================

-- ---- 1. Test users (confirmed, password = password123) ---------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000',
   'a0000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
   'usera@test.at', extensions.crypt('password123', extensions.gen_salt('bf')),
   now(), '{"provider":"email","providers":["email"]}', '{}',
   '', '', '', '', now(), now()),
  ('00000000-0000-0000-0000-000000000000',
   'b0000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
   'userb@test.at', extensions.crypt('password123', extensions.gen_salt('bf')),
   now(), '{"provider":"email","providers":["email"]}', '{}',
   '', '', '', '', now(), now());

-- GoTrue expects a matching identity row per email user.
insert into auth.identities (
  id, user_id, identity_data, provider, provider_id,
  last_sign_in_at, created_at, updated_at
) values
  (gen_random_uuid(), 'a0000000-0000-4000-8000-000000000001',
   '{"sub":"a0000000-0000-4000-8000-000000000001","email":"usera@test.at","email_verified":true}',
   'email', 'a0000000-0000-4000-8000-000000000001', now(), now(), now()),
  (gen_random_uuid(), 'b0000000-0000-4000-8000-000000000002',
   '{"sub":"b0000000-0000-4000-8000-000000000002","email":"userb@test.at","email_verified":true}',
   'email', 'b0000000-0000-4000-8000-000000000002', now(), now(), now());

-- ---- 2. Two organizations (fixed IDs so tests/docs can reference them) -----
insert into public.organizations (id, name) values
  ('11111111-1111-4111-8111-111111111111', 'Org Alpha'),
  ('22222222-2222-4222-8222-222222222222', 'Org Beta');

-- ---- 3. Memberships: A → Alpha, B → Beta ------------------------------------
insert into public.memberships (user_id, org_id, role) values
  ('a0000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'admin'),
  ('b0000000-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222', 'admin');

-- ---- 4. Sample notes so isolation is visible immediately -------------------
insert into public.notes (text, org_id) values
  ('Alpha note 1 — only Org Alpha members should ever see this', '11111111-1111-4111-8111-111111111111'),
  ('Alpha note 2 — seeded for the RLS isolation test',            '11111111-1111-4111-8111-111111111111'),
  ('Beta note 1 — only Org Beta members should ever see this',    '22222222-2222-4222-8222-222222222222');

-- ============================================================================
-- Added 2026-09-06 with the observations schema (migrations …120000, …090000).
--
-- The point of this section is that after `supabase db reset` the multi-park
-- case is immediately testable on a phone: sign in as ranger@test.at and the
-- Settings screen offers a real choice between two parks, with real records in
-- each. That case is the one most likely to be got wrong, so it is the one the
-- dev world puts in front of you by default.
--
--   ranger@test.at / password123  → member of BOTH Org Alpha and Org Beta
-- ============================================================================

-- ---- 5. A third user: the multi-park ranger --------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000',
   'c0000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
   'ranger@test.at', extensions.crypt('password123', extensions.gen_salt('bf')),
   now(), '{"provider":"email","providers":["email"]}',
   -- password_set so the AuthGate does not route this seeded account to the
   -- invitation set-password screen.
   '{"password_set": true}',
   '', '', '', '', now(), now());

insert into auth.identities (
  id, user_id, identity_data, provider, provider_id,
  last_sign_in_at, created_at, updated_at
) values
  (gen_random_uuid(), 'c0000000-0000-4000-8000-000000000003',
   '{"sub":"c0000000-0000-4000-8000-000000000003","email":"ranger@test.at","email_verified":true}',
   'email', 'c0000000-0000-4000-8000-000000000003', now(), now(), now());

insert into public.memberships (user_id, org_id, role) values
  ('c0000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'member'),
  ('c0000000-0000-4000-8000-000000000003', '22222222-2222-4222-8222-222222222222', 'member');

-- The seeded admins should not be sent to the set-password screen either.
update auth.users
   set raw_user_meta_data = raw_user_meta_data || '{"password_set": true}'::jsonb
 where email in ('usera@test.at','userb@test.at');


-- ---- 6. Park metadata -------------------------------------------------------
-- Alpha is fully configured, so its records export cleanly. Beta is left
-- incomplete ON PURPOSE, so `dwc_export_readiness` has something to report and
-- the difference between "has records" and "has publishable records" is
-- visible without contriving anything.
update public.organizations set
  slug            = 'org-alpha',
  country_code    = 'AT',
  dataset_name    = 'Org Alpha vascular plant occurrences',
  rights_holder   = 'Org Alpha',
  default_license = 'http://creativecommons.org/licenses/by/4.0/legalcode',
  contact_name    = 'Alpha Admin',
  contact_email   = 'usera@test.at',
  boundary        = ST_Multi(ST_SetSRID(ST_MakeEnvelope(12.50, 47.00, 13.00, 47.30), 4326))
where id = '11111111-1111-4111-8111-111111111111';

update public.organizations set
  slug         = 'org-beta',
  country_code = 'AT'
where id = '22222222-2222-4222-8222-222222222222';


-- ---- 7. Taxa: two species and one genus-rank class -------------------------
-- The genus row is not an oversight. The label space is mixed-rank by design
-- (1,050 species classes + 39 genus classes), because a park's own records are
-- routinely made at genus when the species cannot be determined.
insert into public.taxa (id, scientific_name, taxon_rank, kingdom, family, genus,
                         specific_epithet, scientific_name_authorship,
                         vernacular_name_de, gbif_taxon_key, source) values
  ('d0000000-0000-4000-8000-000000000001','Leontopodium nivale','species','Plantae',
   'Asteraceae','Leontopodium','nivale','(Ten.) Huet ex Hand.-Mazz.','Edelweiß',3111243,'park_checklist'),
  ('d0000000-0000-4000-8000-000000000002','Gentiana clusii','species','Plantae',
   'Gentianaceae','Gentiana','clusii','Perr. & Songeon','Clusius-Enzian',5343979,'park_checklist');
insert into public.taxa (id, scientific_name, taxon_rank, kingdom, family, genus,
                         vernacular_name_de, source) values
  ('d0000000-0000-4000-8000-000000000003','Hieracium','genus','Plantae','Asteraceae',
   'Hieracium','Habichtskraut','park_checklist');

insert into public.checklist_entries (org_id, taxon_id, tier, is_model_class) values
  ('11111111-1111-4111-8111-111111111111','d0000000-0000-4000-8000-000000000001','A',true),
  ('11111111-1111-4111-8111-111111111111','d0000000-0000-4000-8000-000000000002','A',true),
  ('11111111-1111-4111-8111-111111111111','d0000000-0000-4000-8000-000000000003','C',true),
  ('22222222-2222-4222-8222-222222222222','d0000000-0000-4000-8000-000000000001','A',true);


-- ---- 8. A model version, so identifications have provenance ---------------
insert into public.model_versions (id, name, version, arm, class_count, quantization, temperature)
values ('e0000000-0000-4000-8000-000000000001','thesis-offline','seed-v0','arm2_finetuned',
        1089,'int8',1.42);


-- ---- 9. A survey event, and records inside and outside it ------------------
insert into public.survey_events
  (id, org_id, event_type, event_started_at, event_ended_at, sampling_protocol,
   event_duration_min, target_taxonomic_scope, is_absence_reported,
   is_taxonomic_scope_fully_reported, site_count, created_by_user_id)
values
  ('f0000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111',
   'Survey','2026-07-14T09:00:00+02','2026-07-14T11:00:00+02',
   'timed meander, 2 h, vascular plants',120,'Tracheophyta',true,true,1,
   'c0000000-0000-4000-8000-000000000003');

insert into public.observations
  (id, org_id, survey_event_id, event_date, geometry, coordinate_uncertainty_m,
   georeference_protocol, recorded_by_user_id, recorded_by, habitat,
   individual_count, country_code, sensitivity)
values
  -- inside the survey, fully determined by an expert
  ('0a000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111',
   'f0000000-0000-4000-8000-000000000001','2026-07-14T09:41:00+02',
   ST_SetSRID(ST_MakePoint(12.6963,47.1097),4326),4.2,'device GNSS, single fix',
   'c0000000-0000-4000-8000-000000000003','R. Strammer','alpine grassland',3,'AT','open'),
  -- opportunistic, still only the on-device model's genus-level answer
  ('0a000000-0000-4000-8000-000000000002','11111111-1111-4111-8111-111111111111',
   null,'2026-07-15T14:12:00+02',
   ST_SetSRID(ST_MakePoint(12.7210,47.1240),4326),7.8,'device GNSS, single fix',
   'c0000000-0000-4000-8000-000000000003','R. Strammer','scree',1,'AT','open'),
  -- a sensitive record: stored precisely, generalised only on export
  ('0a000000-0000-4000-8000-000000000003','11111111-1111-4111-8111-111111111111',
   null,'2026-07-15T15:30:00+02',
   ST_SetSRID(ST_MakePoint(12.7431,47.1362),4326),3.5,'device GNSS, single fix',
   'c0000000-0000-4000-8000-000000000003','R. Strammer','wet meadow',1,'AT','generalised'),
  -- the same ranger, recording for the OTHER park on another day
  ('0b000000-0000-4000-8000-000000000001','22222222-2222-4222-8222-222222222222',
   null,'2026-07-18T10:05:00+02',
   ST_SetSRID(ST_MakePoint(14.6200,47.5600),4326),6.1,'device GNSS, single fix',
   'c0000000-0000-4000-8000-000000000003','R. Strammer','montane forest edge',2,'AT','open');


-- ---- 10. The three determination paths, on one observation -----------------
-- This is the shape the thesis measures: the on-device answer and the online
-- answer both survive next to the expert's, forever. Nothing overwrites
-- anything.
insert into public.identifications
  (observation_id, org_id, source, provider, model_version_id, taxon_id,
   taxon_rank_answered, confidence_raw, confidence_calibrated, checklist_masked,
   top_k, is_accepted, identified_by, verification_status, date_identified) values
  ('0a000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111',
   'offline_model','thesis-offline','e0000000-0000-4000-8000-000000000001',
   'd0000000-0000-4000-8000-000000000003','genus',0.61,0.48,true,
   '[{"name":"Hieracium","score":0.61},{"name":"Leontopodium nivale","score":0.22}]'::jsonb,
   false,'thesis-offline seed-v0','unverified','2026-07-14T09:41:10+02'),
  ('0a000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111',
   'online_service','plantnet',null,'d0000000-0000-4000-8000-000000000001','species',
   0.88,null,false,'[{"name":"Leontopodium nivale","score":0.88}]'::jsonb,
   false,'Pl@ntNet API','unverified','2026-07-14T18:02:00+02'),
  -- observation 2 has only the on-device answer so far, and it is the accepted
  -- one. A genus-level determination is a real determination.
  ('0a000000-0000-4000-8000-000000000002','11111111-1111-4111-8111-111111111111',
   'offline_model','thesis-offline','e0000000-0000-4000-8000-000000000001',
   'd0000000-0000-4000-8000-000000000003','genus',0.55,0.41,true,
   '[{"name":"Hieracium","score":0.55}]'::jsonb,
   true,'thesis-offline seed-v0','unverified','2026-07-15T14:12:05+02');

insert into public.identifications
  (observation_id, org_id, source, taxon_id, taxon_rank_answered, is_accepted,
   identified_by_user_id, identified_by, verification_status,
   identification_remarks, date_identified) values
  ('0a000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111','human',
   'd0000000-0000-4000-8000-000000000001','species',true,
   'a0000000-0000-4000-8000-000000000001','Alpha Admin','verified',
   'confirmed from the flower photograph','2026-07-20T11:00:00+02'),
  ('0a000000-0000-4000-8000-000000000003','11111111-1111-4111-8111-111111111111','human',
   'd0000000-0000-4000-8000-000000000002','species',true,
   'a0000000-0000-4000-8000-000000000001','Alpha Admin','verified',
   null,'2026-07-20T11:07:00+02'),
  ('0b000000-0000-4000-8000-000000000001','22222222-2222-4222-8222-222222222222','human',
   'd0000000-0000-4000-8000-000000000001','species',true,
   'b0000000-0000-4000-8000-000000000002','Beta Admin','verified',
   null,'2026-07-21T09:00:00+02');

insert into public.observation_media
  (observation_id, org_id, storage_path, organ, is_primary, license) values
  ('0a000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111',
   'obs/0a000001/flower.jpg','flower',true,
   'http://creativecommons.org/licenses/by/4.0/legalcode');


-- ---- 11. A pending invitation, so the admin screen is not empty ------------
insert into public.invitations (org_id, email, role, invited_by, status)
values ('11111111-1111-4111-8111-111111111111','newcomer@test.at','member',
        'a0000000-0000-4000-8000-000000000001','pending');


-- ---- 12. Where each seeded person is currently recording -------------------
insert into public.user_settings (user_id, active_org_id) values
  ('a0000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111'),
  ('b0000000-0000-4000-8000-000000000002','22222222-2222-4222-8222-222222222222'),
  ('c0000000-0000-4000-8000-000000000003','11111111-1111-4111-8111-111111111111');


-- ============================================================================
-- Added 2026-09-07 — testPark_A, the park to actually test with.
--
--   admin@park.at  / password123   → ADMIN of testPark_A
--   ranger@park.at / password123   → MEMBER of testPark_A
--
-- Note that `supabase db reset` wipes `auth.users`, so any account made with
-- tools/provision_org.ps1 disappears on every reset. Anything you want to
-- survive a reset belongs here, in the seed — that is what this section is.
--
-- testPark_A is configured for publication end to end (dataset name, rights
-- holder, licence, country, boundary), so `dwc_occurrence_export` produces
-- signable rows for it the moment a record is verified.
-- ============================================================================

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000',
   'aa000000-0000-4000-8000-00000000000a', 'authenticated', 'authenticated',
   'admin@park.at', extensions.crypt('password123', extensions.gen_salt('bf')),
   now(), '{"provider":"email","providers":["email"]}', '{"password_set": true}',
   '', '', '', '', now(), now()),
  ('00000000-0000-0000-0000-000000000000',
   'bb000000-0000-4000-8000-00000000000b', 'authenticated', 'authenticated',
   'ranger@park.at', extensions.crypt('password123', extensions.gen_salt('bf')),
   now(), '{"provider":"email","providers":["email"]}', '{"password_set": true}',
   '', '', '', '', now(), now());

insert into auth.identities (
  id, user_id, identity_data, provider, provider_id,
  last_sign_in_at, created_at, updated_at
) values
  (gen_random_uuid(), 'aa000000-0000-4000-8000-00000000000a',
   '{"sub":"aa000000-0000-4000-8000-00000000000a","email":"admin@park.at","email_verified":true}',
   'email', 'aa000000-0000-4000-8000-00000000000a', now(), now(), now()),
  (gen_random_uuid(), 'bb000000-0000-4000-8000-00000000000b',
   '{"sub":"bb000000-0000-4000-8000-00000000000b","email":"ranger@park.at","email_verified":true}',
   'email', 'bb000000-0000-4000-8000-00000000000b', now(), now(), now());

-- The park itself, fully configured for publication.
insert into public.organizations
  (id, name, slug, country_code, dataset_name, rights_holder, default_license,
   contact_name, contact_email, publishing_status, boundary)
values
  ('7e570000-0000-4000-8000-00000000000a', 'testPark_A', 'testpark-a', 'AT',
   'testPark_A vascular plant occurrences',
   'testPark_A',
   'http://creativecommons.org/licenses/by/4.0/legalcode',
   'Park Admin', 'admin@park.at', 'private',
   ST_Multi(ST_SetSRID(ST_MakeEnvelope(12.50, 47.00, 13.00, 47.30), 4326)));

insert into public.memberships (user_id, org_id, role) values
  ('aa000000-0000-4000-8000-00000000000a','7e570000-0000-4000-8000-00000000000a','admin'),
  ('bb000000-0000-4000-8000-00000000000b','7e570000-0000-4000-8000-00000000000a','member');

-- The ranger from the earlier section also works for testPark_A, so the
-- park switcher has three parks to choose from for that account.
insert into public.memberships (user_id, org_id, role) values
  ('c0000000-0000-4000-8000-000000000003','7e570000-0000-4000-8000-00000000000a','member');

insert into public.user_settings (user_id, active_org_id) values
  ('aa000000-0000-4000-8000-00000000000a','7e570000-0000-4000-8000-00000000000a'),
  ('bb000000-0000-4000-8000-00000000000b','7e570000-0000-4000-8000-00000000000a');

-- Its checklist: the same three taxa, so the taxon picker in the app has
-- something to offer from the first launch.
insert into public.checklist_entries (org_id, taxon_id, tier, is_model_class) values
  ('7e570000-0000-4000-8000-00000000000a','d0000000-0000-4000-8000-000000000001','A',true),
  ('7e570000-0000-4000-8000-00000000000a','d0000000-0000-4000-8000-000000000002','A',true),
  ('7e570000-0000-4000-8000-00000000000a','d0000000-0000-4000-8000-000000000003','C',true);

-- One record, so the list is not empty on first sign-in and the three-guess
-- view has something to show.
insert into public.observations
  (id, org_id, event_date, geometry, coordinate_uncertainty_m, georeference_protocol,
   recorded_by_user_id, recorded_by, habitat, individual_count, country_code)
values
  ('0c000000-0000-4000-8000-00000000000a','7e570000-0000-4000-8000-00000000000a',
   '2026-08-02T10:20:00+02', ST_SetSRID(ST_MakePoint(12.7500,47.1500),4326), 5.0,
   'device GNSS, single fix','bb000000-0000-4000-8000-00000000000b','Park Ranger',
   'alpine grassland', 2, 'AT');

insert into public.identifications
  (observation_id, org_id, source, provider, model_version_id, taxon_id,
   taxon_rank_answered, confidence_raw, confidence_calibrated, checklist_masked,
   top_k, is_accepted, identified_by, verification_status, date_identified) values
  ('0c000000-0000-4000-8000-00000000000a','7e570000-0000-4000-8000-00000000000a',
   'offline_model','thesis-offline','e0000000-0000-4000-8000-000000000001',
   'd0000000-0000-4000-8000-000000000003','genus',0.58,0.44,true,
   '[{"name":"Hieracium","score":0.58},{"name":"Leontopodium nivale","score":0.19}]'::jsonb,
   false,'thesis-offline seed-v0','unverified','2026-08-02T10:20:08+02'),
  ('0c000000-0000-4000-8000-00000000000a','7e570000-0000-4000-8000-00000000000a',
   'online_service','plantnet',null,'d0000000-0000-4000-8000-000000000001','species',
   0.91,null,false,'[{"name":"Leontopodium nivale","score":0.91}]'::jsonb,
   false,'Pl@ntNet API','unverified','2026-08-02T19:40:00+02');

insert into public.identifications
  (observation_id, org_id, source, taxon_id, taxon_rank_answered, is_accepted,
   identified_by_user_id, identified_by, verification_status, date_identified) values
  ('0c000000-0000-4000-8000-00000000000a','7e570000-0000-4000-8000-00000000000a',
   'human','d0000000-0000-4000-8000-000000000001','species',true,
   'aa000000-0000-4000-8000-00000000000a','admin@park.at','verified',
   '2026-08-03T09:00:00+02');
