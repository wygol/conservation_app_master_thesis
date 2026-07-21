# ============================================================================
# provision_org.ps1 — concierge onboarding (ADR 004).
# Creates ONE customer org + its first admin (confirmed user) + membership,
# in a single transaction, against the LOCAL Supabase database.
#
# Usage:
#   .\tools\provision_org.ps1 -OrgName "Nationalpark Test" `
#       -AdminEmail "admin@park.at" -AdminPassword "choose-a-password"
#
# Notes:
# - LOCAL/DEV convenience: writes directly into auth.users (superuser via
#   the DB container), same technique as seed.sql. For PRODUCTION, prefer
#   creating the user via the GoTrue Admin API / dashboard invite and use
#   SQL only for the org + membership rows.
# - Post-thesis, this script's SQL is the template for the Stripe-webhook
#   provisioning handler (CLAUDE.md §5).
# ============================================================================
param(
    [Parameter(Mandatory = $true)][string]$OrgName,
    [Parameter(Mandatory = $true)][string]$AdminEmail,
    [Parameter(Mandatory = $true)][string]$AdminPassword,
    # Default container name of the Supabase-CLI local DB: supabase_db_<project_id>
    [string]$Container = 'supabase_db_conservation_app'
)

# Send UTF-8 to psql so org names with umlauts survive.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# Escape single quotes for SQL string literals.
function Esc([string]$s) { return $s -replace "'", "''" }
$org = Esc $OrgName
$email = Esc ($AdminEmail.Trim().ToLower())
$pw = Esc $AdminPassword

# Single-quoted here-string: nothing interpolates; tokens replaced below.
$sql = @'
begin;
do $$
declare
  v_org  uuid;
  v_user uuid := gen_random_uuid();
begin
  if exists (select 1 from auth.users where email = '__EMAIL__') then
    raise exception 'User __EMAIL__ already exists — aborting (nothing was created).';
  end if;

  insert into public.organizations (name)
  values ('__ORG__')
  returning id into v_org;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_user, 'authenticated',
    'authenticated', '__EMAIL__',
    extensions.crypt('__PW__', extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{}',
    '', '', '', '', now(), now()
  );

  insert into auth.identities (
    id, user_id, identity_data, provider, provider_id,
    last_sign_in_at, created_at, updated_at
  ) values (
    gen_random_uuid(), v_user,
    jsonb_build_object('sub', v_user::text, 'email', '__EMAIL__',
                       'email_verified', true),
    'email', v_user::text, now(), now(), now()
  );

  insert into public.memberships (user_id, org_id, role)
  values (v_user, v_org, 'admin');

  raise notice 'Provisioned org "%" (%) with admin % (%)',
    '__ORG__', v_org, '__EMAIL__', v_user;
end $$;
commit;
'@

$sql = $sql.Replace('__ORG__', $org).Replace('__EMAIL__', $email).Replace('__PW__', $pw)

Write-Host "Provisioning org '$OrgName' with admin '$AdminEmail' in container '$Container'..."
$sql | docker exec -i $Container psql -U postgres -d postgres -v ON_ERROR_STOP=1

if ($LASTEXITCODE -eq 0) {
    Write-Host "OK: org + admin + membership created. The admin can log in now." -ForegroundColor Green
} else {
    Write-Host "FAILED (see message above). Nothing partial was written (single transaction)." -ForegroundColor Red
    Write-Host "Is Docker running? Is 'supabase start' up? Check name: docker ps --format '{{.Names}}'"
    exit 1
}
