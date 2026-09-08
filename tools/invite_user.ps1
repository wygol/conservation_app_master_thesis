# ============================================================================
# invite_user.ps1 — the service-role half of the invitation flow (ADR 006).
#
# An admin creates an `invitations` row from inside the app. That row cannot
# send an e-mail: mailing requires GoTrue's admin API, which needs the SECRET
# key, which must never live in the app (CLAUDE.md §7). This script is that
# missing half, run by the operator.
#
# Post-thesis this becomes a Supabase Edge Function triggered on insert. For a
# thesis artefact, a script the operator runs is honest and is exactly the
# sales-led onboarding ADR 004 describes.
#
# Usage:
#   .\tools\invite_user.ps1                       # send every pending invitation
#   .\tools\invite_user.ps1 -Email a@park.at      # send just this one
#
# The secret key is read from the environment, never from a file in the repo:
#   $env:SUPABASE_SERVICE_ROLE_KEY = "<secret key from `supabase status`>"
# ============================================================================
param(
    [string]$Email,
    [string]$SupabaseUrl = 'http://127.0.0.1:54321',
    [string]$Container   = 'supabase_db_conservation_app',
    # Where the invited person lands after clicking the link. For a mobile-only
    # flow this is the app's deep link; during local dev, Inbucket shows the
    # mail at http://127.0.0.1:54324 and the link can be opened by hand.
    [string]$RedirectTo  = 'conservationapp://invite'
)

$ErrorActionPreference = 'Stop'

$serviceKey = $env:SUPABASE_SERVICE_ROLE_KEY
if ([string]::IsNullOrWhiteSpace($serviceKey)) {
    Write-Error "SUPABASE_SERVICE_ROLE_KEY is not set. Get it from ``supabase status`` and set it for this shell only:`n  `$env:SUPABASE_SERVICE_ROLE_KEY = '<key>'"
}

# ---- 1. Read the pending invitations straight from the database ------------
$filter = if ($Email) { "and i.email = '" + ($Email.Trim().ToLower() -replace "'", "''") + "'" } else { '' }
$query = @"
select i.id::text || '|' || i.email || '|' || i.role || '|' || o.name
from public.invitations i
join public.organizations o on o.id = i.org_id
where i.status = 'pending' and i.expires_at > now() $filter;
"@

$rows = docker exec -i $Container psql -U postgres -d postgres -At -c $query
if ($LASTEXITCODE -ne 0) { Write-Error "Could not reach the database container '$Container'. Is `supabase start` running?" }

$pending = @($rows | Where-Object { $_ -and $_.Trim() -ne '' })
if ($pending.Count -eq 0) {
    Write-Host "Nothing pending." -ForegroundColor Yellow
    exit 0
}

Write-Host "$($pending.Count) invitation(s) to send." -ForegroundColor Cyan

# ---- 2. Ask GoTrue to mail each one ----------------------------------------
foreach ($row in $pending) {
    $parts   = $row -split '\|'
    $invId   = $parts[0]
    $invMail = $parts[1]
    $invRole = $parts[2]
    $orgName = $parts[3]

    Write-Host "  -> $invMail ($invRole of $orgName)" -NoNewline

    $body = @{
        email = $invMail
        # `invited` is what the app's AuthGate reads to route this person to the
        # set-password screen on first sign-in; `password_set` is written by
        # that screen once they choose one.
        data  = @{ invited = $true; invited_to = $orgName; invited_role = $invRole }
    } | ConvertTo-Json -Depth 4

    try {
        Invoke-RestMethod -Method Post `
            -Uri "$SupabaseUrl/auth/v1/invite?redirect_to=$([uri]::EscapeDataString($RedirectTo))" `
            -Headers @{
                'apikey'        = $serviceKey
                'Authorization' = "Bearer $serviceKey"
                'Content-Type'  = 'application/json'
            } `
            -Body $body | Out-Null

        # Mark it sent, so a re-run does not mail the same person twice.
        $upd = "update public.invitations set status='sent', sent_at=now() where id='$invId';"
        docker exec -i $Container psql -U postgres -d postgres -q -c $upd | Out-Null
        Write-Host "  sent" -ForegroundColor Green
    }
    catch {
        # A user who already exists is not an error worth stopping for: they
        # simply sign in normally and accept_pending_invitations() picks the
        # membership up on their next authenticated call.
        $msg = $_.Exception.Message
        if ($msg -match '422|already registered|already been registered') {
            $upd = "update public.invitations set status='sent', sent_at=now() where id='$invId';"
            docker exec -i $Container psql -U postgres -d postgres -q -c $upd | Out-Null
            Write-Host "  already has an account - they will be added on next sign-in" -ForegroundColor Yellow
        }
        else {
            Write-Host "  FAILED: $msg" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "Local dev: the invitation mails appear in Inbucket at http://127.0.0.1:54324" -ForegroundColor DarkGray
