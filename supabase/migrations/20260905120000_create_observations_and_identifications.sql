-- =============================================================================
-- Observations, identifications and the standards-aligned reference tables.
--
-- Design document: MasterThesis/Vault/30_Architecture/Observation_Data_Model.md
-- Follows ADR 002 (uuid PKs, timestamptz) and ADR 003 (deny-by-default RLS via
-- the memberships subquery). Nothing here changes organizations/memberships.
--
-- The one idea worth carrying in your head while reading this: Darwin Core
-- allows exactly ONE identification per occurrence ("One dwc:Identification
-- object is allowed per dwc:Occurrence object" -- dwc:identificationID).
-- We need three or more, never overwritten, because the offline-vs-online
-- comparison IS the thesis. So identifications is a separate append-only
-- table, and Darwin Core is what we project to at EXPORT time, not what we
-- store in. dwc:previousIdentifications carries the history out.
-- =============================================================================

-- 0. PostGIS. The Supabase image ships it; it was never enabled.
create extension if not exists postgis;


-- =============================================================================
-- 1. taxa -- the label space. NOT org-scoped: a taxon is a fact about the
--    world, not about a tenant. Mixed rank by design (D-016: 1,050 species
--    classes + 39 genus classes).
-- =============================================================================
create table public.taxa (
  id                          uuid primary key default gen_random_uuid(),
  scientific_name             text not null,
  taxon_rank                  text not null
                                check (taxon_rank in ('species','genus','family','order','class','phylum','kingdom')),
  genus                       text,
  specific_epithet            text,
  scientific_name_authorship  text,
  vernacular_name_de          text,

  -- The join to everything external. accepted_gbif_key is set when
  -- gbif_taxon_key is a synonym -- GBIF indexes occurrences under the ACCEPTED
  -- taxon, which is why the Task 0 coverage script initially returned ~0 for
  -- synonyms (Chrysanthemum leucanthemum -> 0, Leucanthemum vulgare -> 100,060).
  gbif_taxon_key              integer,
  accepted_gbif_key           integer,

  parent_taxon_id             uuid references public.taxa (id),
  source                      text not null default 'park_checklist'
                                check (source in ('park_checklist','gbif_backbone','manual')),
  created_at                  timestamptz not null default now(),

  -- A genus-rank row has no specific epithet; a species-rank row must have one.
  constraint taxa_rank_epithet_consistent check (
    (taxon_rank = 'species' and specific_epithet is not null)
    or (taxon_rank <> 'species')
  )
);

create index taxa_scientific_name_idx on public.taxa (scientific_name);
create index taxa_gbif_key_idx        on public.taxa (gbif_taxon_key);
create index taxa_parent_idx          on public.taxa (parent_taxon_id);


-- =============================================================================
-- 2. checklist_entries -- which taxa an org expects to occur.
--    This is the object the offline model's output mask is built from, which
--    is what makes proposition P2 a stored fact rather than a constant baked
--    into a model file.
-- =============================================================================
create table public.checklist_entries (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations (id) on delete cascade,
  taxon_id        uuid not null references public.taxa (id)          on delete restrict,
  tier            text check (tier in ('A','B','C','D')),   -- photo-identifiability triage, D-016
  is_model_class  boolean not null default false,           -- one of the 1,089 the shipped model can answer
  expected_status text not null default 'present'
                    check (expected_status in ('present','historical','unlikely')),
  created_at      timestamptz not null default now(),
  unique (org_id, taxon_id)
);

create index checklist_entries_org_idx on public.checklist_entries (org_id) where is_model_class;


-- =============================================================================
-- 3. model_versions -- provenance for the on-device model. Thin, but Chapter 7
--    has to be able to say which artefact produced a given prediction, and a
--    free-text version string drifts.
-- =============================================================================
create table public.model_versions (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,                     -- 'thesis-offline'
  version         text not null,                     -- 'mnv3s-int8-v3'
  arm             text check (arm in ('arm1_masked_vit','arm2_finetuned','arm3_distilled')),
  class_count     integer,
  quantization    text check (quantization in ('fp32','fp16','int8')),
  temperature     numeric,                           -- fitted temperature scaling parameter, D-018
  artifact_sha256 text,
  trained_at      timestamptz,
  released_at     timestamptz,
  created_at      timestamptz not null default now(),
  unique (name, version)
);


-- =============================================================================
-- 4. survey_events -- the Humboldt Extension layer.
--    Eight of the fifty-five ratified terms: the ones a phone in a ranger's
--    hand can fill honestly. observations.survey_event_id is NULLABLE, so
--    opportunistic records (most of them) need none of this.
--    Definitions: https://eco.tdwg.org/terms/ and https://dwc.tdwg.org/list/
-- =============================================================================
create table public.survey_events (
  id                       uuid primary key default gen_random_uuid(),   -- dwc:eventID
  org_id                   uuid not null references public.organizations (id) on delete cascade,
  parent_event_id          uuid references public.survey_events (id),    -- dwc:parentEventID
  event_type               text,                                          -- dwc:eventType
  event_started_at         timestamptz not null,                          -- dwc:eventDate (start)
  event_ended_at           timestamptz,                                   -- dwc:eventDate (end)
  sampling_protocol        text,                                          -- dwc:samplingProtocol
  event_duration_min       numeric,                                       -- eco:eventDurationValue (unit fixed: minutes)
  target_taxonomic_scope   text,                                          -- eco:targetTaxonomicScope
  is_absence_reported      boolean not null default false,                -- eco:isAbsenceReported
  is_taxonomic_scope_fully_reported boolean,                              -- eco:isTaxonomicScopeFullyReported
  site_count               integer,                                       -- eco:siteCount
  geometry                 geometry(Geometry, 4326),                      -- dwc:footprintWKT, when there is an area
  event_remarks            text,                                          -- dwc:eventRemarks
  created_by_user_id       uuid references auth.users (id) on delete set null,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint survey_events_time_order check (event_ended_at is null or event_ended_at >= event_started_at)
);

create index survey_events_org_idx  on public.survey_events (org_id);
create index survey_events_geom_idx on public.survey_events using gist (geometry);


-- =============================================================================
-- 5. observations -- the dwc:Occurrence.
--
--    Note what is NOT here: there is no scientific_name column. The
--    determination is not an attribute of the occurrence; it is a separate,
--    versioned, contestable thing. Read it back through observations_current.
-- =============================================================================
create table public.observations (
  id                        uuid primary key default gen_random_uuid(),   -- dwc:occurrenceID (GBIF's one REQUIRED term)
  org_id                    uuid not null references public.organizations (id) on delete cascade,
  survey_event_id           uuid references public.survey_events (id) on delete set null,

  basis_of_record           text not null default 'HumanObservation'
                              check (basis_of_record in ('HumanObservation','MachineObservation','PreservedSpecimen',
                                                         'LivingSpecimen','FossilSpecimen','MaterialSample','Occurrence')),
  occurrence_status         text not null default 'present'
                              check (occurrence_status in ('present','absent')),

  -- FIELD-CAPTURE time, client-supplied. Distinct from created_at, which is
  -- server arrival time -- ADR 002 anticipated exactly this split.
  event_date                timestamptz not null,                          -- dwc:eventDate

  -- Point or polygon (the brief allows both).
  geometry                  geometry(Geometry, 4326) not null,
  coordinate_uncertainty_m  numeric,                                       -- dwc:coordinateUncertaintyInMeters
  georeference_protocol     text,                                          -- dwc:georeferenceProtocol

  individual_count          integer,                                       -- dwc:individualCount
  organism_quantity         numeric,                                       -- dwc:organismQuantity
  organism_quantity_type    text,                                          -- dwc:organismQuantityType
  life_stage                text,                                          -- dwc:lifeStage

  recorded_by_user_id       uuid references auth.users (id) on delete set null,
  recorded_by               text not null,                                 -- dwc:recordedBy, snapshotted at capture

  habitat                   text,                                          -- dwc:habitat
  occurrence_remarks        text,                                          -- dwc:occurrenceRemarks

  -- Publication policy. The STORED coordinate is never degraded; generalisation
  -- happens at export only, and carries dwc:dataGeneralizations with it.
  sensitivity               text not null default 'open'
                              check (sensitivity in ('open','generalised','withheld')),

  -- The swappable domain layer (CLAUDE.md section 4).
  attributes                jsonb not null default '{}'::jsonb,

  client_created_at         timestamptz,                                   -- device clock; audit only, never trusted
  created_at                timestamptz not null default now(),            -- server arrival
  updated_at                timestamptz not null default now(),            -- dcterms:modified
  deleted_at                timestamptz,                                   -- soft delete so sync can propagate it

  constraint observations_geometry_kind check (
    ST_GeometryType(geometry) in ('ST_Point','ST_Polygon','ST_MultiPolygon')
  ),
  constraint observations_uncertainty_sane check (
    coordinate_uncertainty_m is null or coordinate_uncertainty_m >= 0
  ),
  constraint observations_quantity_paired check (
    (organism_quantity is null) = (organism_quantity_type is null)
  ),
  -- An absence is only meaningful inside a survey event: "I looked here, for
  -- this long, for this taxon group, and did not find it."
  constraint observations_absence_needs_event check (
    occurrence_status <> 'absent' or survey_event_id is not null
  )
);

-- The denormalised org_id on the child tables is enforced, not merely convention:
-- this unique key is the target of a composite foreign key from identifications
-- and observation_media, so a child can never disagree with its parent about
-- which organisation owns the record. (Called for in the July data-model spec,
-- Vault/30_Architecture/Data_Model_Specification.md section 7.)
alter table public.observations add constraint observations_id_org_key unique (id, org_id);

create index observations_org_idx       on public.observations (org_id) where deleted_at is null;
create index observations_event_idx     on public.observations (survey_event_id);
create index observations_date_idx      on public.observations (org_id, event_date desc);
create index observations_geom_idx      on public.observations using gist (geometry);
create index observations_attributes_idx on public.observations using gin (attributes);


-- =============================================================================
-- 6. identifications -- THE APPEND-ONLY DETERMINATION LOG.
--
--    Every determination attempt, machine and human, kept forever. This table
--    is what proposition P1 is measured from: two rows on one observation_id,
--    one from the offline model and one from the online service, on the same
--    image. If the online result were allowed to overwrite the offline one,
--    the measurement would be destroyed at the moment it was taken.
-- =============================================================================
create table public.identifications (
  id                     uuid primary key default gen_random_uuid(),       -- dwc:identificationID
  observation_id         uuid not null references public.observations (id) on delete cascade,
  org_id                 uuid not null references public.organizations (id) on delete cascade,

  source                 text not null
                           check (source in ('offline_model','online_service','human')),
  provider               text,                                             -- 'plantnet' | 'thesis-offline' | null
  model_version_id       uuid references public.model_versions (id),

  taxon_id               uuid references public.taxa (id),
  verbatim_identification text,                                            -- dwc:verbatimIdentification
  taxon_rank_answered    text                                              -- dwc:taxonRank -- the rank ACTUALLY answered
                           check (taxon_rank_answered in ('species','genus','family','order','class','phylum','kingdom')),

  confidence_raw         numeric check (confidence_raw is null or (confidence_raw >= 0 and confidence_raw <= 1)),
  confidence_calibrated  numeric check (confidence_calibrated is null or (confidence_calibrated >= 0 and confidence_calibrated <= 1)),

  -- Was the checklist prior applied? This single column is proposition P2.
  checklist_masked       boolean not null default false,

  -- The full candidate list: [{"taxon_id":…,"name":…,"score":…}, …].
  -- Without it, top-5 accuracy cannot be computed from production data at all.
  top_k                  jsonb,

  is_accepted            boolean not null default false,

  identified_by_user_id  uuid references auth.users (id) on delete set null,
  identified_by          text,                                             -- dwc:identifiedBy
  date_identified        timestamptz not null default now(),               -- dwc:dateIdentified
  verification_status    text                                              -- dwc:identificationVerificationStatus
                           check (verification_status in ('verified','unverified','unable to verify')),
  identification_remarks text,                                             -- dwc:identificationRemarks

  superseded_by_id       uuid references public.identifications (id),
  created_at             timestamptz not null default now(),

  -- A human identification names a human.
  constraint identifications_human_has_user check (
    source <> 'human' or identified_by_user_id is not null
  ),
  -- A machine identification carries a score and a provider.
  constraint identifications_machine_has_score check (
    source = 'human' or (confidence_raw is not null and provider is not null)
  ),
  -- Only the offline model can claim to have been checklist-masked.
  constraint identifications_mask_only_offline check (
    checklist_masked = false or source = 'offline_model'
  ),
  -- The denormalised org_id must agree with the parent observation's.
  constraint identifications_org_matches_observation
    foreign key (observation_id, org_id)
    references public.observations (id, org_id) on delete cascade
);

-- At most one accepted determination per observation.
create unique index identifications_one_accepted_idx
  on public.identifications (observation_id) where is_accepted;

create index identifications_observation_idx on public.identifications (observation_id);
create index identifications_org_source_idx  on public.identifications (org_id, source);
create index identifications_taxon_idx       on public.identifications (taxon_id);


-- =============================================================================
-- 7. observation_media -- the photographs.
-- =============================================================================
create table public.observation_media (
  id             uuid primary key default gen_random_uuid(),
  observation_id uuid not null references public.observations (id) on delete cascade,
  org_id         uuid not null references public.organizations (id) on delete cascade,
  storage_path   text not null,                                            -- dwc:associatedMedia (Supabase Storage object)
  organ          text check (organ in ('leaf','flower','fruit','bark','habit','other')),
  is_primary     boolean not null default false,                           -- the image sent for identification
  captured_at    timestamptz,
  width_px       integer,
  height_px      integer,
  bytes          integer,
  sha256         text,
  -- A photo's embedded GPS tag is a second copy of the coordinate that no
  -- export policy governs. Strip it on the device, before upload.
  exif_stripped  boolean not null default true,
  license        text,                                                     -- dcterms:license, per image
  created_at     timestamptz not null default now(),
  constraint observation_media_org_matches_observation
    foreign key (observation_id, org_id)
    references public.observations (id, org_id) on delete cascade
);

create unique index observation_media_one_primary_idx
  on public.observation_media (observation_id) where is_primary;
create index observation_media_observation_idx on public.observation_media (observation_id);


-- =============================================================================
-- 8. The read-back view. security_invoker means it inherits the RLS of its
--    base tables rather than running as the view owner -- so the isolation
--    guarantee of ADR 003 carries over without being restated.
-- =============================================================================
create view public.observations_current
with (security_invoker = true) as
select
  o.id, o.org_id, o.survey_event_id, o.basis_of_record, o.occurrence_status,
  o.event_date, o.geometry, o.coordinate_uncertainty_m,
  o.individual_count, o.recorded_by, o.recorded_by_user_id,
  o.habitat, o.occurrence_remarks, o.sensitivity, o.attributes,
  o.created_at, o.updated_at,
  i.id                    as identification_id,
  i.source                as identification_source,
  i.provider              as identification_provider,
  t.id                    as taxon_id,
  t.scientific_name,
  t.vernacular_name_de,
  i.taxon_rank_answered,
  i.confidence_calibrated,
  i.verification_status
from public.observations o
left join public.identifications i on i.observation_id = o.id and i.is_accepted
left join public.taxa            t on t.id = i.taxon_id
where o.deleted_at is null;

-- A view needs its own grant: RLS on the base tables decides WHICH ROWS come
-- back, but the GRANT decides whether the role may read the view at all. Both
-- layers, every time (ADR 003).
grant select on public.observations_current to authenticated;


-- =============================================================================
-- 9. Row-Level Security. Same two-layer pattern as ADR 003: GRANTs decide
--    whether an operation is possible at all, policies decide which rows.
--    Deny-by-default -- forgetting a policy fails closed.
-- =============================================================================
alter table public.taxa              enable row level security;
alter table public.checklist_entries enable row level security;
alter table public.model_versions    enable row level security;
alter table public.survey_events     enable row level security;
alter table public.observations      enable row level security;
alter table public.identifications   enable row level security;
alter table public.observation_media enable row level security;

-- Reference tables: readable by any authenticated user, writable by nobody
-- through the API (service_role only -- these are loaded by migration/tooling).
grant select on public.taxa           to authenticated;
grant select on public.model_versions to authenticated;

create policy "read taxa" on public.taxa
  for select to authenticated using (true);

create policy "read model versions" on public.model_versions
  for select to authenticated using (true);

-- Org-scoped tables.
grant select, insert, update on public.observations      to authenticated;
grant select, insert         on public.identifications   to authenticated;
grant select, insert, update on public.observation_media to authenticated;
grant select, insert, update on public.survey_events     to authenticated;
grant select                 on public.checklist_entries to authenticated;

-- checklist_entries: read the checklists of orgs you belong to.
create policy "read checklists in my orgs" on public.checklist_entries
  for select to authenticated
  using ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

-- survey_events
create policy "read survey events in my orgs" on public.survey_events
  for select to authenticated
  using ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

create policy "insert survey events in my orgs" on public.survey_events
  for insert to authenticated
  with check ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

create policy "update survey events in my orgs" on public.survey_events
  for update to authenticated
  using      ( org_id in (select org_id from public.memberships where user_id = auth.uid()) )
  with check ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

-- observations
create policy "read observations in my orgs" on public.observations
  for select to authenticated
  using ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

create policy "insert observations in my orgs" on public.observations
  for insert to authenticated
  with check ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

create policy "update observations in my orgs" on public.observations
  for update to authenticated
  using      ( org_id in (select org_id from public.memberships where user_id = auth.uid()) )
  with check ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

-- identifications: INSERT ONLY, no update policy at all.
-- Superseding a determination is an insert plus flipping is_accepted, never an
-- overwrite. The absence of an UPDATE policy is what protects the measurement.
create policy "read identifications in my orgs" on public.identifications
  for select to authenticated
  using ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

create policy "insert identifications in my orgs" on public.identifications
  for insert to authenticated
  with check ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

-- observation_media
create policy "read media in my orgs" on public.observation_media
  for select to authenticated
  using ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

create policy "insert media in my orgs" on public.observation_media
  for insert to authenticated
  with check ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

create policy "update media in my orgs" on public.observation_media
  for update to authenticated
  using      ( org_id in (select org_id from public.memberships where user_id = auth.uid()) )
  with check ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );


-- =============================================================================
-- 10. Accepting a determination. is_accepted is exclusive per observation, so
--     flipping it needs to clear the previous one atomically. Doing it in a
--     SECURITY DEFINER function keeps the client from needing UPDATE on
--     identifications, which is what keeps the log append-only.
-- =============================================================================
create or replace function public.accept_identification(p_identification_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_obs uuid;
  v_org uuid;
begin
  select observation_id, org_id into v_obs, v_org
  from public.identifications where id = p_identification_id;

  if v_obs is null then
    raise exception 'identification % not found', p_identification_id;
  end if;

  -- Enforce the same org rule the RLS policies would: SECURITY DEFINER
  -- bypasses RLS, so the check has to be explicit here.
  if not exists (select 1 from public.memberships
                 where user_id = auth.uid() and org_id = v_org) then
    raise exception 'not a member of the owning organization';
  end if;

  update public.identifications
     set is_accepted = false,
         superseded_by_id = p_identification_id
   where observation_id = v_obs and is_accepted and id <> p_identification_id;

  update public.identifications
     set is_accepted = true
   where id = p_identification_id;

  update public.observations
     set updated_at = now()
   where id = v_obs;
end;
$$;

revoke all on function public.accept_identification(uuid) from public;
grant execute on function public.accept_identification(uuid) to authenticated;
