-- =============================================================================
-- Member management, the flat "three guesses" view, and a placeholder photo
-- bucket.
--
-- Three things René asked for after seeing the schema:
--
--   1. The three determinations as COLUMNS. They are stored as rows in
--      `identifications` and must stay that way — that is what keeps them from
--      overwriting each other, which is the thesis' central measurement. But
--      "give me one row per observation with offline / online / expert side by
--      side" is a completely reasonable thing to want, and a view gives it
--      without touching storage. See `observations_wide` below.
--   2. Admins add and remove people. Removal must NEVER delete their records.
--   3. A photo bucket, as a placeholder, so nothing is blocked on it.
-- =============================================================================


-- =============================================================================
-- 1. observations_wide — one row per observation, the three paths side by side.
--
--    This is a READ view over the append-only log, not a second copy of the
--    data. Adding these as real columns would mean writing the same fact twice
--    and keeping them in sync, which is exactly the trap the earlier design
--    fell into.
--
--    "Most recent per source" is the rule: if the on-device model answered
--    twice, the later answer is the one shown. The full history stays in
--    `identifications`.
-- =============================================================================
create view public.observations_wide
with (security_invoker = true) as
select
  o.id,
  o.org_id,
  o.survey_event_id,
  o.event_date,
  o.geometry,
  ST_Y(ST_Centroid(o.geometry))      as latitude,
  ST_X(ST_Centroid(o.geometry))      as longitude,
  o.coordinate_uncertainty_m,
  o.occurrence_status,
  o.individual_count,
  o.life_stage,
  o.habitat,
  o.occurrence_remarks,
  o.sensitivity,
  o.country_code,
  o.recorded_by,
  o.recorded_by_user_id,
  o.attributes,
  o.created_at,
  o.updated_at,

  -- --- the on-device model's answer -------------------------------------
  off_t.scientific_name              as offline_guess,
  off_i.taxon_rank_answered          as offline_rank,
  off_i.confidence_calibrated        as offline_confidence,
  off_i.checklist_masked             as offline_checklist_masked,
  off_i.date_identified              as offline_at,

  -- --- the online service's answer ---------------------------------------
  onl_t.scientific_name              as online_guess,
  onl_i.taxon_rank_answered          as online_rank,
  onl_i.confidence_raw               as online_confidence,
  onl_i.date_identified              as online_at,

  -- --- a person's determination ------------------------------------------
  exp_t.scientific_name              as expert_guess,
  exp_i.taxon_rank_answered          as expert_rank,
  exp_i.identified_by                as expert_by,
  exp_i.verification_status          as expert_status,
  exp_i.date_identified              as expert_at,

  -- --- whichever of them currently stands ---------------------------------
  acc_t.scientific_name              as accepted_name,
  acc_t.vernacular_name_de           as accepted_vernacular,
  acc_i.source                       as accepted_source,
  acc_i.taxon_rank_answered          as accepted_rank,
  acc_i.verification_status          as accepted_status,
  acc_i.id                           as accepted_identification_id
from public.observations o
left join lateral (
    select i.* from public.identifications i
    where i.observation_id = o.id and i.source = 'offline_model'
    order by i.date_identified desc limit 1) off_i on true
left join public.taxa off_t on off_t.id = off_i.taxon_id
left join lateral (
    select i.* from public.identifications i
    where i.observation_id = o.id and i.source = 'online_service'
    order by i.date_identified desc limit 1) onl_i on true
left join public.taxa onl_t on onl_t.id = onl_i.taxon_id
left join lateral (
    select i.* from public.identifications i
    where i.observation_id = o.id and i.source = 'human'
    order by i.date_identified desc limit 1) exp_i on true
left join public.taxa exp_t on exp_t.id = exp_i.taxon_id
left join lateral (
    select i.* from public.identifications i
    where i.observation_id = o.id and i.is_accepted limit 1) acc_i on true
left join public.taxa acc_t on acc_t.id = acc_i.taxon_id
where o.deleted_at is null;

grant select on public.observations_wide to authenticated;

comment on view public.observations_wide is
  'One row per observation with the offline / online / expert determinations side by side, plus whichever is accepted. A READ view over the append-only identifications log — none of these are stored columns, and none of them is sent to GBIF (dwc_occurrence_export carries only the accepted determination plus previousIdentifications).';


-- =============================================================================
-- 2. Who is in this park — and getting them out again.
--
--    `memberships` holds a user_id; the address lives in `auth.users`, which
--    clients cannot read. So this is a function rather than a view: it is the
--    only way to expose an e-mail address to an admin without granting select
--    on the whole auth schema.
-- =============================================================================
create or replace function public.park_members(p_org_id uuid)
returns table (
  user_id           uuid,
  email             text,
  role              text,
  joined_at         timestamptz,
  observation_count bigint,
  is_self           boolean
)
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Any member may see who else is in their park; only admins may change it.
  -- Note the alias: this function's OUT parameters are called user_id and role,
  -- and PL/pgSQL resolves an unqualified name to the parameter before the
  -- column, so every column reference in here has to be qualified.
  if not exists (select 1 from public.memberships mm
                 where mm.user_id = auth.uid() and mm.org_id = p_org_id) then
    raise exception 'not a member of that organization';
  end if;

  return query
  select m.user_id,
         u.email::text,
         m.role,
         m.created_at,
         (select count(*) from public.observations o
           where o.recorded_by_user_id = m.user_id
             and o.org_id = p_org_id and o.deleted_at is null),
         (m.user_id = auth.uid())
  from public.memberships m
  join auth.users u on u.id = m.user_id
  where m.org_id = p_org_id
  order by m.role, u.email;
end;
$$;

revoke all on function public.park_members(uuid) from public;
grant execute on function public.park_members(uuid) to authenticated;


-- Remove a person from a park. Their records stay exactly where they are.
--
-- `observations.recorded_by_user_id` is `on delete set null` and is NOT what
-- attributes a record to a person for publication — `observations.recorded_by`
-- is, and it is a plain text snapshot taken at capture time. So a record keeps
-- its `dwc:recordedBy` even if the account is deleted outright, which is what
-- makes the archive stable. Removing a membership touches neither.
create or replace function public.remove_member(p_user_id uuid, p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role        text;
  v_admin_count integer;
begin
  if not exists (select 1 from public.memberships
                 where user_id = auth.uid() and org_id = p_org_id and role = 'admin') then
    raise exception 'only an admin of this organization can remove members';
  end if;

  select role into v_role from public.memberships
   where user_id = p_user_id and org_id = p_org_id;
  if v_role is null then
    raise exception 'that person is not a member of this organization';
  end if;

  -- Never leave a park with no way in.
  if v_role = 'admin' then
    select count(*) into v_admin_count from public.memberships
     where org_id = p_org_id and role = 'admin';
    if v_admin_count <= 1 then
      raise exception 'cannot remove the last admin of an organization';
    end if;
  end if;

  delete from public.memberships where user_id = p_user_id and org_id = p_org_id;

  -- If they were recording under this park, unset it rather than leaving them
  -- pointing at a park they can no longer read.
  update public.user_settings
     set active_org_id = (select org_id from public.memberships
                           where user_id = p_user_id limit 1),
         updated_at = now()
   where user_id = p_user_id and active_org_id = p_org_id;

  -- Any invitation that brought them in is spent; drop stale pending ones too.
  update public.invitations
     set status = 'revoked'
   where org_id = p_org_id
     and status in ('pending','sent')
     and email = (select lower(email) from auth.users where id = p_user_id);
end;
$$;

revoke all on function public.remove_member(uuid, uuid) from public;
grant execute on function public.remove_member(uuid, uuid) to authenticated;


-- Promote or demote. Same guard against removing the last admin.
create or replace function public.set_member_role(p_user_id uuid, p_org_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_count integer;
begin
  if p_role not in ('admin','member') then
    raise exception 'role must be admin or member';
  end if;
  if not exists (select 1 from public.memberships
                 where user_id = auth.uid() and org_id = p_org_id and role = 'admin') then
    raise exception 'only an admin of this organization can change roles';
  end if;

  if p_role = 'member' then
    select count(*) into v_admin_count from public.memberships
     where org_id = p_org_id and role = 'admin';
    if v_admin_count <= 1 and exists (select 1 from public.memberships
                                       where user_id = p_user_id and org_id = p_org_id
                                         and role = 'admin') then
      raise exception 'cannot demote the last admin of an organization';
    end if;
  end if;

  update public.memberships set role = p_role
   where user_id = p_user_id and org_id = p_org_id;
end;
$$;

revoke all on function public.set_member_role(uuid, uuid, text) from public;
grant execute on function public.set_member_role(uuid, uuid, text) to authenticated;


-- =============================================================================
-- 3. record_identification — one call, one determination, from the app.
--
--    Writing an identification from the client means an insert plus, if it is
--    to become the accepted one, flipping a flag that must stay exclusive.
--    Two round-trips that must not half-succeed. One function instead.
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
security invoker
as $$
declare
  v_org uuid;
  v_id  uuid;
  v_by  text;
begin
  select org_id into v_org from public.observations where id = p_observation_id;
  if v_org is null then
    raise exception 'observation not found';
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

grant execute on function public.record_identification(uuid, text, text, uuid, text, numeric, text, boolean, text, boolean) to authenticated;


-- =============================================================================
-- 4. A photo bucket — PLACEHOLDER, deliberately.
--
--    ⚠️ These policies are org-scoped by path convention (`<org_id>/<...>`) and
--    that convention is NOT enforced anywhere. They are good enough to unblock
--    photo upload and NOT good enough to be part of the sovereignty claim. The
--    real design has to decide whether photos are private-with-signed-URLs or
--    public-read, and enforce the path rather than trusting it.
--
--    Guarded, because the storage schema only exists inside real Supabase —
--    the SQL test harness runs on plain PostgreSQL.
-- =============================================================================
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema absent (plain PostgreSQL) - skipping bucket setup';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit)
  values ('observation-photos', 'observation-photos', false, 26214400)
  on conflict (id) do nothing;

  execute $p$
    create policy "photos: read within my orgs" on storage.objects
      for select to authenticated
      using ( bucket_id = 'observation-photos'
              and (storage.foldername(name))[1] in (
                    select org_id::text from public.memberships
                     where user_id = auth.uid()) ) $p$;
  execute $p$
    create policy "photos: write within my orgs" on storage.objects
      for insert to authenticated
      with check ( bucket_id = 'observation-photos'
                   and (storage.foldername(name))[1] in (
                         select org_id::text from public.memberships
                          where user_id = auth.uid()) ) $p$;
exception
  when duplicate_object then
    raise notice 'storage policies already present - skipping';
end $$;
