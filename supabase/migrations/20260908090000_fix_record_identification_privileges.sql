-- =============================================================================
-- Bug fix: saving a record reported "permission denied for table users" while
-- the record itself was created.
--
-- WHAT HAPPENED, exactly. The app saves in two steps: insert the observation,
-- then call record_identification() for the determination. Step 1 succeeded;
-- step 2 failed. So the record appeared in the list (after a refresh, and to
-- other users immediately) with no species on it, while the app showed an
-- error. It looked like a permissions problem with `observations`; it was not.
--
-- THE CAUSE. record_identification() was the only SECURITY INVOKER function in
-- the schema that reads `auth.users` -- it looked up the caller's e-mail for
-- dwc:identifiedBy. SECURITY INVOKER means the function runs with the CALLER's
-- privileges, and `authenticated` has no SELECT on auth.users (correctly: the
-- user table is not client-readable). Every other function that touches
-- auth.users -- accept_pending_invitations, park_members, remove_member -- was
-- already SECURITY DEFINER, which is why none of them showed the problem.
--
-- THE FIX. Make it SECURITY DEFINER like its siblings. But SECURITY DEFINER
-- also bypasses RLS, so the org check that RLS was doing implicitly now has to
-- be explicit -- that is the `not exists (... memberships ...)` block below.
-- Losing that check while gaining the privilege is exactly how a fix like this
-- turns into a data leak.
--
-- The regression test for the whole class is in
-- supabase/tests/test_function_privileges.sql: it asserts that no SECURITY
-- INVOKER function anywhere in `public` references auth.users.
-- =============================================================================

create or replace function public.record_identification(
  p_observation_id  uuid,
  p_source          text,
  p_scientific_name text default null,
  p_taxon_id        uuid default null,
  p_rank            text default null,
  p_confidence      numeric default null,
  p_provider        text default null,
  p_checklist_masked boolean default false,
  p_remarks         text default null,
  p_accept          boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_id  uuid;
  v_by  text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select org_id into v_org from public.observations where id = p_observation_id;
  if v_org is null then
    raise exception 'observation not found';
  end if;

  -- SECURITY DEFINER bypasses RLS, so the rule RLS was enforcing has to be
  -- stated here. Without this, any authenticated user could write a
  -- determination onto any organisation's record.
  if not exists (select 1 from public.memberships m
                 where m.user_id = auth.uid() and m.org_id = v_org) then
    raise exception 'not a member of the organization that owns this record';
  end if;

  if p_source not in ('offline_model','online_service','human') then
    raise exception 'source must be offline_model, online_service or human';
  end if;

  -- A determination must say *something*: either a taxon from the checklist or
  -- a verbatim name. Silently writing an empty one would put a row in the log
  -- that means nothing.
  if p_taxon_id is null and coalesce(trim(p_scientific_name), '') = '' then
    raise exception 'a determination needs either a taxon or a name';
  end if;

  select coalesce(u.email::text, 'unknown') into v_by
    from auth.users u where u.id = auth.uid();

  insert into public.identifications
    (observation_id, org_id, source, provider, taxon_id, verbatim_identification,
     taxon_rank_answered, confidence_raw, checklist_masked, is_accepted,
     identified_by_user_id, identified_by, verification_status, identification_remarks)
  values
    (p_observation_id, v_org, p_source,
     case when p_source = 'human' then null else coalesce(p_provider, 'unknown') end,
     p_taxon_id, p_scientific_name, p_rank,
     case when p_source = 'human' then null else coalesce(p_confidence, 0) end,
     p_checklist_masked, false,
     case when p_source = 'human' then auth.uid() else null end,
     case when p_source = 'human' then v_by else coalesce(p_provider, 'unknown') end,
     case when p_source = 'human' then 'verified' else 'unverified' end,
     p_remarks)
  returning id into v_id;

  if p_accept then
    perform public.accept_identification(v_id);
  end if;

  return v_id;
end;
$$;

revoke all on function public.record_identification(uuid, text, text, uuid, text, numeric, text, boolean, text, boolean) from public;
grant execute on function public.record_identification(uuid, text, text, uuid, text, numeric, text, boolean, text, boolean) to authenticated;


-- =============================================================================
-- While here: a record with NO determination is a legitimate, expected state,
-- not a half-finished one.
--
-- The workflow this system is being built for is photograph-first: capture the
-- plant, let the on-device model and then the online service propose names, and
-- have a person confirm one later at a desk. So an observation arrives with no
-- determination by design, and the schema already allowed it -- but the app was
-- refusing to save without one, which had it backwards.
--
-- This comment is the only change needed in the database; it is recorded here
-- so the intent is visible next to the schema rather than only in the app.
-- =============================================================================
comment on table public.observations is
  'A dwc:Occurrence. May legitimately have NO accepted identification: the intended workflow is photograph first, determination later (on-device model, then online service, then a person). observations_current shows such a record with a null scientific_name; that means "not determined yet", not "broken".';

comment on function public.record_identification(uuid, text, text, uuid, text, numeric, text, boolean, text, boolean) is
  'Append one determination to an observation and optionally make it the accepted one. SECURITY DEFINER because it reads auth.users for dwc:identifiedBy; the organisation check that RLS would otherwise perform is therefore explicit inside the function.';
