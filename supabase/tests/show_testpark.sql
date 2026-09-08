-- Read-only look at testPark_A, run by tools/apply_and_verify.ps1 after a reset.
-- Kept as a file rather than inline SQL because PowerShell mangles embedded
-- double quotes on their way to a native command, and every Darwin Core column
-- name is a quoted identifier.
\echo ''
\echo '--- the three determinations, side by side (observations_wide) ---'
select left(id::text,8) as obs, latitude, longitude,
       offline_guess, online_guess, expert_guess, accepted_source
from public.observations_wide
where org_id = '7e570000-0000-4000-8000-00000000000a';

\echo ''
\echo '--- what a GBIF partner would receive (dwc_occurrence_export) ---'
select "occurrenceID", "scientificName", "taxonRank", "kingdom",
       "decimalLatitude", "decimalLongitude", "countryCode",
       "identificationVerificationStatus" as verified
from public.dwc_occurrence_export
where org_id = '7e570000-0000-4000-8000-00000000000a';

\echo ''
\echo '--- anything a partner would reject (dwc_export_readiness) ---'
select left(observation_id::text,8) as obs, blockers
from public.dwc_export_readiness
where org_id = '7e570000-0000-4000-8000-00000000000a'
  and cardinality(blockers) > 0;

\echo ''
\echo '--- who is in testPark_A ---'
select u.email, m.role
from public.memberships m join auth.users u on u.id = m.user_id
where m.org_id = '7e570000-0000-4000-8000-00000000000a'
order by m.role, u.email;
