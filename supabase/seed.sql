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
