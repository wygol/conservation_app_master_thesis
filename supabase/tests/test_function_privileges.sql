-- =============================================================================
-- Regression test for a class of bug, not one instance of it.
--
-- record_identification() shipped as SECURITY INVOKER while reading auth.users.
-- SECURITY INVOKER runs with the caller's privileges, `authenticated` has no
-- SELECT on auth.users, so every attempt to save a determination failed with
-- "permission denied for table users" -- after the observation row had already
-- been written. The record appeared; the species did not.
--
-- Any future function that reads auth.users has the same trap waiting. This
-- asserts the rule instead of remembering it.
-- =============================================================================
\set ON_ERROR_STOP off

\echo ''
\echo '######## FUNCTION PRIVILEGES ########'

-- PostGIS installs ~776 functions into `public`, and some of them ARE
-- SECURITY DEFINER (st_estimatedextent, for one) with no reason on earth to
-- reference auth.uid(). These assertions are about OUR functions, so anything
-- owned by an extension has to be excluded - otherwise the test reports on
-- someone else's code and the failure means nothing.
--
-- This was found the hard way: the test passed on PostGIS 3.4.2, where
-- st_estimatedextent is not SECURITY DEFINER, and failed on the newer PostGIS
-- Supabase ships, where it is. A test that depends on an extension's internals
-- is not a test.


\echo '-- 1. no SECURITY INVOKER function in public may read auth.users'
select case when count(*) = 0 then 'PASS' else 'FAIL' end as t1_no_invoker_reads_auth_users,
       coalesce(string_agg(proname, ', '), 'none') as offenders
from (
  select p.proname
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'            -- plain functions; pg_get_functiondef errors on aggregates
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
    and not p.prosecdef
    and pg_get_functiondef(p.oid) like '%auth.users%'
) q;

\echo '-- 2. every SECURITY DEFINER function must check membership or auth.uid()'
-- A definer function bypasses RLS, so it has to re-state the rule itself.
-- accept_pending_invitations and park_members check auth.uid() directly;
-- the rest check memberships.
select case when count(*) = 0 then 'PASS' else 'FAIL' end as t2_definers_check_the_caller,
       coalesce(string_agg(proname, ', '), 'none') as offenders
from (
  select p.proname
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
    and pg_get_functiondef(p.oid) not like '%auth.uid()%'
) q;

\echo '-- 3. the app can actually save a determination now'
begin;
insert into auth.users (id, email) values
  ('dd000000-0000-4000-8000-00000000000d','saver@test.invalid')
on conflict (id) do nothing;
insert into public.organizations (id, name) values
  ('ee000000-0000-4000-8000-00000000000e','TEST Save Park')
on conflict (id) do nothing;
insert into public.memberships (user_id, org_id, role) values
  ('dd000000-0000-4000-8000-00000000000d','ee000000-0000-4000-8000-00000000000e','member')
on conflict do nothing;
insert into public.taxa (id, scientific_name, taxon_rank, genus, specific_epithet)
values ('ff000000-0000-4000-8000-00000000000f','Testus plantus','species','Testus','plantus')
on conflict (id) do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'dd000000-0000-4000-8000-00000000000d';

insert into public.observations (id, org_id, event_date, geometry,
                                 coordinate_uncertainty_m, recorded_by)
values ('ab000000-0000-4000-8000-00000000000a','ee000000-0000-4000-8000-00000000000e',
        now(), ST_SetSRID(ST_MakePoint(12.75,47.15),4326), 10, 'saver@test.invalid');

select case when public.record_identification(
                 'ab000000-0000-4000-8000-00000000000a','human',
                 'Testus plantus','ff000000-0000-4000-8000-00000000000f','species') is not null
            then 'PASS' else 'FAIL' end as t3_determination_saves;

select case when scientific_name = 'Testus plantus' then 'PASS' else 'FAIL' end
         as t4_it_shows_up_in_the_view, scientific_name, identification_source
from public.observations_current where id = 'ab000000-0000-4000-8000-00000000000a';

\echo '-- 4. an observation with NO determination is fine, not an error'
insert into public.observations (id, org_id, event_date, geometry,
                                 coordinate_uncertainty_m, recorded_by)
values ('ac000000-0000-4000-8000-00000000000a','ee000000-0000-4000-8000-00000000000e',
        now(), ST_SetSRID(ST_MakePoint(12.76,47.16),4326), 10, 'saver@test.invalid');
select case when count(*) = 1 then 'PASS' else 'FAIL' end as t5_undetermined_record_is_valid,
       count(*) from public.observations_current
 where id = 'ac000000-0000-4000-8000-00000000000a' and scientific_name is null;

\echo '-- 5. NEGATIVE: a non-member cannot write a determination (expect: error)'
savepoint sp_nonmember;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.record_identification(
         'ab000000-0000-4000-8000-00000000000a','human',
         'Testus plantus','ff000000-0000-4000-8000-00000000000f','species');
rollback to savepoint sp_nonmember;

\echo '-- 6. NEGATIVE: an empty determination is refused (expect: error)'
savepoint sp_empty;
set local request.jwt.claim.sub = 'dd000000-0000-4000-8000-00000000000d';
select public.record_identification('ab000000-0000-4000-8000-00000000000a','human');
rollback to savepoint sp_empty;

reset role; reset request.jwt.claim.sub;
rollback;
\echo ''
\echo 'Rolled back - the database is unchanged.'
