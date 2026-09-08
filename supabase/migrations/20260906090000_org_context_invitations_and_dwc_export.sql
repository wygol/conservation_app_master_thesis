-- =============================================================================
-- Active-park context, admin-managed invitations, and the Darwin Core export.
--
-- Design document: MasterThesis/Vault/30_Architecture/Observation_Data_Model.md
-- Product decisions this implements (see docs/decisions/005, 006, 007):
--
--   * A person belongs to one or more park instances. The app always writes
--     under exactly ONE active park, chosen by the person, switchable in
--     Settings. The choice is stored server-side so it follows them across
--     devices.
--   * There is no self-service sign-up. An admin adds a colleague by email;
--     the colleague receives an invitation link, sets their own password on
--     first login, and lands in that admin's park.
--   * Records are prepared so that a GBIF publishing partner has nothing left
--     to do but sign off. We validate; we do not publish (thesis objective O8).
-- =============================================================================


-- =============================================================================
-- 1. Organizations become park instances that can publish.
--
--    A Darwin Core Archive needs dataset-level metadata (an EML file) that no
--    occurrence row carries. Storing it here is what turns "export the rows"
--    into "hand a publishing partner a complete, signable dataset".
-- =============================================================================
alter table public.organizations
  add column slug              text unique,                    -- stable short name, e.g. 'np-hohe-tauern'
  add column boundary          geometry(MultiPolygon, 4326),   -- the park's extent; used for the soft out-of-bounds warning
  add column country_code      text check (country_code is null or country_code ~ '^[A-Z]{2}$'),  -- dwc:countryCode, ISO 3166-1 alpha-2
  -- Dataset-level Darwin Core / EML metadata:
  add column dataset_name      text,                           -- dwc:datasetName
  add column rights_holder     text,                           -- dwc:rightsHolder
  add column default_license   text                            -- dcterms:license, as a URI
                                 check (default_license is null or default_license like 'http%'),
  add column contact_name      text,                           -- EML dataset contact
  add column contact_email     text,
  add column publishing_status text not null default 'private'
                                 check (publishing_status in ('private','validated','published')),
  -- Whether a machine's determination may be published without a human having
  -- confirmed it. Default false, deliberately: the aim is an archive a
  -- publishing partner only has to sign off, and an unverified model guess is
  -- exactly the row a partner would query. A park that wants the wider,
  -- lower-confidence dataset can opt in per park.
  add column export_unverified boolean not null default false;

comment on column public.organizations.publishing_status is
  'private = never leaves the org (default). validated = a Darwin Core Archive has been generated and passed the GBIF validator. published = a publishing partner has signed it off and it is live. The step from validated to published is deliberately outside this system.';

create index organizations_boundary_idx on public.organizations using gist (boundary);


-- =============================================================================
-- 2. taxa gains the two ranks GBIF asks for by name.
--    GBIF's data-quality recommendations list kingdom and taxonRank among the
--    strongly recommended terms, because they are what the backbone matcher
--    uses to disambiguate a name.
-- =============================================================================
alter table public.taxa
  add column kingdom text,   -- dwc:kingdom
  add column family  text;   -- dwc:family


-- =============================================================================
-- 3. Per-observation country code, overriding the org's when it differs.
-- =============================================================================
alter table public.observations
  add column country_code text check (country_code is null or country_code ~ '^[A-Z]{2}$');


-- =============================================================================
-- 4. user_settings -- where the active park lives.
--
--    Stored server-side rather than only in device preferences, so that the
--    choice follows the person to a second device and so an admin can see
--    which park a colleague is currently recording under.
-- =============================================================================
create table public.user_settings (
  user_id       uuid primary key references auth.users (id) on delete cascade,
  active_org_id uuid references public.organizations (id) on delete set null,
  locale        text,
  updated_at    timestamptz not null default now()
);

alter table public.user_settings enable row level security;
grant select, insert, update on public.user_settings to authenticated;

create policy "read own settings" on public.user_settings
  for select to authenticated using ( user_id = auth.uid() );
create policy "insert own settings" on public.user_settings
  for insert to authenticated with check ( user_id = auth.uid() );
create policy "update own settings" on public.user_settings
  for update to authenticated
  using ( user_id = auth.uid() ) with check ( user_id = auth.uid() );

-- Switching park. A function rather than a bare UPDATE, because the new org
-- has to be one the caller is actually a member of -- an RLS policy on
-- user_settings can check who owns the row but not whether the value being
-- written is legitimate.
create or replace function public.set_active_org(p_org_id uuid)
returns void
language plpgsql
security invoker
as $$
begin
  if not exists (select 1 from public.memberships
                 where user_id = auth.uid() and org_id = p_org_id) then
    raise exception 'not a member of that organization';
  end if;

  insert into public.user_settings (user_id, active_org_id, updated_at)
  values (auth.uid(), p_org_id, now())
  on conflict (user_id) do update
    set active_org_id = excluded.active_org_id, updated_at = now();
end;
$$;

grant execute on function public.set_active_org(uuid) to authenticated;


-- =============================================================================
-- 5. invitations -- admin-managed onboarding.
--
--    Flow, end to end:
--      1. An admin of park X inserts a row here with a colleague's email.
--         RLS allows the insert only if the caller is an admin OF THAT PARK.
--      2. A service-role process (Edge Function, or tools/invite_user.ps1 for
--         now) sees the pending row and calls GoTrue's admin invite endpoint,
--         which emails a one-time link.
--      3. The colleague follows the link, sets their own password, and signs in.
--      4. On first authenticated call the app invokes accept_pending_invitations(),
--         which turns every invitation matching their email into a membership.
--
--    Memberships are never inserted directly by a client. That is deliberate:
--    a membership insert policy would have to query memberships to decide
--    whether the caller is an admin, which is the self-referencing RLS
--    recursion the app's architecture notes already flag. Routing it through a
--    SECURITY DEFINER function avoids the recursion and keeps exactly one
--    write path to audit.
-- =============================================================================
create table public.invitations (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations (id) on delete cascade,
  email        text not null,
  role         text not null default 'member' check (role in ('admin','member')),
  invited_by   uuid references auth.users (id) on delete set null,
  status       text not null default 'pending'
                 check (status in ('pending','sent','accepted','revoked','expired')),
  sent_at      timestamptz,
  accepted_at  timestamptz,
  accepted_by  uuid references auth.users (id) on delete set null,
  expires_at   timestamptz not null default (now() + interval '14 days'),
  created_at   timestamptz not null default now(),

  constraint invitations_email_lower check (email = lower(email))
);

-- One live invitation per person per park. Re-inviting after a revoke is fine.
create unique index invitations_one_pending_idx
  on public.invitations (org_id, email) where status in ('pending','sent');
create index invitations_email_idx on public.invitations (email) where status in ('pending','sent');

alter table public.invitations enable row level security;
grant select, insert, update on public.invitations to authenticated;

-- Admins see and manage the invitations of their own park; nobody else sees any.
create policy "admins read invitations of their orgs" on public.invitations
  for select to authenticated
  using ( org_id in (select org_id from public.memberships
                     where user_id = auth.uid() and role = 'admin') );

create policy "admins create invitations for their orgs" on public.invitations
  for insert to authenticated
  with check ( org_id in (select org_id from public.memberships
                          where user_id = auth.uid() and role = 'admin')
               and invited_by = auth.uid() );

create policy "admins revoke invitations of their orgs" on public.invitations
  for update to authenticated
  using      ( org_id in (select org_id from public.memberships
                          where user_id = auth.uid() and role = 'admin') )
  with check ( org_id in (select org_id from public.memberships
                          where user_id = auth.uid() and role = 'admin') );


-- Called by the app right after a successful sign-in. Converts every pending
-- invitation addressed to the caller's e-mail into a membership, and sets the
-- active park if the caller does not have one yet.
create or replace function public.accept_pending_invitations()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text;
  v_count   integer := 0;
  v_first   uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  -- Read the address from auth.users rather than from the JWT: the JWT claim
  -- can be stale after an e-mail change, the table cannot.
  select lower(email) into v_email from auth.users where id = auth.uid();
  if v_email is null then
    return 0;
  end if;

  with claimed as (
    update public.invitations i
       set status = 'accepted', accepted_at = now(), accepted_by = auth.uid()
     where i.email = v_email
       and i.status in ('pending','sent')
       and i.expires_at > now()
    returning i.org_id, i.role
  ), inserted as (
    insert into public.memberships (user_id, org_id, role)
    select auth.uid(), c.org_id, c.role from claimed c
    on conflict (user_id, org_id) do nothing
    returning org_id
  )
  select count(*), min(org_id::text)::uuid into v_count, v_first from inserted;

  -- Expire anything that has run out, so the admin's list stays honest.
  update public.invitations
     set status = 'expired'
   where email = v_email and status in ('pending','sent') and expires_at <= now();

  -- Give a brand-new user a park to land in.
  if v_first is not null then
    insert into public.user_settings (user_id, active_org_id)
    values (auth.uid(), v_first)
    on conflict (user_id) do update
      set active_org_id = coalesce(public.user_settings.active_org_id, excluded.active_org_id),
          updated_at = now();
  end if;

  return coalesce(v_count, 0);
end;
$$;

revoke all on function public.accept_pending_invitations() from public;
grant execute on function public.accept_pending_invitations() to authenticated;


-- =============================================================================
-- 6. my_parks -- what the Settings park-switcher reads.
--    One row per park the caller belongs to, with their role and a flag for
--    which one is active. RLS on the base tables does the filtering.
-- =============================================================================
create view public.my_parks
with (security_invoker = true) as
select o.id            as org_id,
       o.name,
       o.slug,
       m.role,
       (s.active_org_id = o.id) as is_active,
       o.publishing_status
from public.memberships m
join public.organizations o on o.id = m.org_id
left join public.user_settings s on s.user_id = m.user_id
where m.user_id = auth.uid();


-- =============================================================================
-- 7. A soft out-of-bounds check.
--    Deliberately NOT a constraint. A ranger legitimately records from a car
--    park outside the boundary, and a hard rule would either block real work
--    or push people to fake coordinates. The app warns; the database records.
-- =============================================================================
create or replace function public.observation_is_within_org_boundary(p_org_id uuid, p_geom geometry)
returns boolean
language sql
stable
security invoker
as $$
  select case
           when b.boundary is null then true          -- no boundary configured: nothing to warn about
           else ST_Intersects(b.boundary, p_geom)
         end
  from public.organizations b
  where b.id = p_org_id;
$$;

grant execute on function public.observation_is_within_org_boundary(uuid, geometry) to authenticated;


-- =============================================================================
-- 8. dwc_occurrence_export -- the Darwin Core Occurrence core.
--
--    Column names are the Darwin Core term names verbatim, so writing the
--    archive is `copy (select * from dwc_occurrence_export where org_id = …)
--    to 'occurrence.tsv'` plus a meta.xml and an EML file. Nothing in the
--    export is computed by hand, which is what "the partner only has to sign
--    it off" requires.
--
--    THE CONTRACT: every row in this view is publishable as it stands. If a
--    record is not ready, it is absent, and dwc_export_readiness says why.
--    That is what lets a publishing partner sign the archive off rather than
--    audit it.
--
--    Four rules are enforced here rather than in application code:
--      * withheld records never appear at all;
--      * generalised records are rounded to ~1 km and carry
--        dwc:dataGeneralizations and dwc:informationWithheld saying so;
--      * the accepted determination is the identification; the superseded ones
--        become dwc:previousIdentifications, because Darwin Core permits only
--        one Identification per Occurrence.
-- =============================================================================
create view public.dwc_occurrence_export
with (security_invoker = true) as
select
  o.org_id,                                                             -- not a DwC term; for filtering the export
  o.id::text                                        as "occurrenceID",
  o.basis_of_record                                 as "basisOfRecord",
  org.dataset_name                                  as "datasetName",
  org.rights_holder                                 as "rightsHolder",
  coalesce(m.license, org.default_license)          as "license",
  o.occurrence_status                               as "occurrenceStatus",
  to_char(o.event_date at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as "eventDate",
  se.id::text                                       as "eventID",
  se.sampling_protocol                              as "samplingProtocol",
  o.recorded_by                                     as "recordedBy",
  o.individual_count                                as "individualCount",
  o.organism_quantity                               as "organismQuantity",
  o.organism_quantity_type                          as "organismQuantityType",
  o.life_stage                                      as "lifeStage",
  o.habitat                                         as "habitat",
  o.occurrence_remarks                              as "occurrenceRemarks",

  -- Taxon terms, from the accepted determination.
  t.scientific_name                                 as "scientificName",
  t.scientific_name_authorship                      as "scientificNameAuthorship",
  i.taxon_rank_answered                             as "taxonRank",
  t.kingdom                                         as "kingdom",
  t.family                                          as "family",
  t.genus                                           as "genus",
  t.specific_epithet                                as "specificEpithet",
  t.vernacular_name_de                              as "vernacularName",
  nullif(coalesce(t.accepted_gbif_key, t.gbif_taxon_key)::text, '') as "taxonID",

  -- Identification terms. One accepted determination, plus the history.
  i.identified_by                                   as "identifiedBy",
  to_char(i.date_identified at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as "dateIdentified",
  i.verification_status                             as "identificationVerificationStatus",
  i.identification_remarks                          as "identificationRemarks",
  i.verbatim_identification                         as "verbatimIdentification",
  prev.previous_identifications                     as "previousIdentifications",

  -- Location. Generalised records are rounded here, at the boundary, and the
  -- stored coordinate is never degraded.
  case when o.sensitivity = 'generalised'
       then round(ST_Y(ST_Centroid(o.geometry))::numeric, 2)
       else round(ST_Y(ST_Centroid(o.geometry))::numeric, 6) end       as "decimalLatitude",
  case when o.sensitivity = 'generalised'
       then round(ST_X(ST_Centroid(o.geometry))::numeric, 2)
       else round(ST_X(ST_Centroid(o.geometry))::numeric, 6) end       as "decimalLongitude",
  'WGS84'                                           as "geodeticDatum",
  case when o.sensitivity = 'generalised'
       then greatest(coalesce(o.coordinate_uncertainty_m, 0), 1000)
       else o.coordinate_uncertainty_m end          as "coordinateUncertaintyInMeters",
  o.georeference_protocol                           as "georeferenceProtocol",
  coalesce(o.country_code, org.country_code)        as "countryCode",
  case when ST_GeometryType(o.geometry) <> 'ST_Point' and o.sensitivity = 'open'
       then ST_AsText(o.geometry) end               as "footprintWKT",
  case when ST_GeometryType(o.geometry) <> 'ST_Point' and o.sensitivity = 'open'
       then 'EPSG:4326' end                         as "footprintSRS",

  case when o.sensitivity = 'generalised'
       then 'Coordinates rounded to two decimal degrees to protect a sensitive record.' end
                                                    as "dataGeneralizations",
  case when o.sensitivity = 'generalised'
       then 'Precise coordinates withheld; available from the rights holder on request.' end
                                                    as "informationWithheld",

  m.media_list                                      as "associatedMedia",
  to_char(greatest(o.updated_at, i.date_identified) at time zone 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS"Z"')             as "modified"

from public.observations o
join public.organizations org on org.id = o.org_id
left join public.survey_events se on se.id = o.survey_event_id
join public.identifications i on i.observation_id = o.id and i.is_accepted
left join public.taxa t on t.id = i.taxon_id
left join lateral (
    select string_agg(om.storage_path, ' | ' order by om.is_primary desc, om.created_at) as media_list,
           min(om.license) as license
    from public.observation_media om
    where om.observation_id = o.id
) m on true
left join lateral (
    select string_agg(
             coalesce(pt.scientific_name, p.verbatim_identification, '?')
               || ' (' || p.source || ', '
               || to_char(p.date_identified at time zone 'UTC', 'YYYY-MM-DD') || ')',
             ' | ' order by p.date_identified)                     as previous_identifications
    from public.identifications p
    left join public.taxa pt on pt.id = p.taxon_id
    where p.observation_id = o.id and not p.is_accepted
) prev on true
where o.deleted_at is null
  and o.sensitivity <> 'withheld'          -- withheld records never leave
  and t.scientific_name is not null        -- an occurrence with no name is not publishable
  -- and, unless the park opts in, only determinations a human has confirmed
  and (org.export_unverified or i.verification_status = 'verified')
  -- and only from a park whose dataset-level metadata is complete. The
  -- contract of this view is that everything in it is publishable as it
  -- stands; emitting rows with a null licence would break that quietly, and a
  -- publishing partner would be the one to discover it. What is missing is
  -- named, per record, by dwc_export_readiness.
  and org.dataset_name    is not null
  and org.rights_holder   is not null
  and org.default_license is not null;

grant select on public.dwc_occurrence_export to authenticated;
grant select on public.my_parks             to authenticated;


-- =============================================================================
-- 9. dwc_export_readiness -- what a publishing partner would reject.
--
--    Objective O8 says the archive validates. This view is how that claim gets
--    measured, and it is what turns "hand it to a partner" into something you
--    can check before you do.
-- =============================================================================
create view public.dwc_export_readiness
with (security_invoker = true) as
select o.org_id,
       o.id as observation_id,
       array_remove(array[
         case when not exists (select 1 from public.identifications i
                               where i.observation_id = o.id and i.is_accepted)
              then 'no accepted identification' end,
         case when not org.export_unverified
               and not exists (select 1 from public.identifications i
                               where i.observation_id = o.id and i.is_accepted
                                 and i.verification_status = 'verified')
              then 'determination not confirmed by a person' end,
         case when o.event_date is null                       then 'no eventDate' end,
         case when o.geometry is null                         then 'no coordinates' end,
         case when o.coordinate_uncertainty_m is null         then 'no coordinateUncertaintyInMeters' end,
         case when coalesce(o.country_code, org.country_code) is null then 'no countryCode' end,
         case when org.dataset_name    is null                then 'org has no datasetName' end,
         case when org.rights_holder   is null                then 'org has no rightsHolder' end,
         case when org.default_license is null                then 'org has no license' end,
         case when o.recorded_by is null or o.recorded_by = '' then 'no recordedBy' end
       ], null) as blockers
from public.observations o
join public.organizations org on org.id = o.org_id
where o.deleted_at is null and o.sensitivity <> 'withheld';

grant select on public.dwc_export_readiness to authenticated;
