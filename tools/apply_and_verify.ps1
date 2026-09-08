# ============================================================================
# apply_and_verify.ps1 - apply every migration, reseed, and prove it worked.
#
#   .\tools\apply_and_verify.ps1
#   .\tools\apply_and_verify.ps1 -SkipReset     # just re-run the tests
#
# What it does:
#   1. checks Docker and the local Supabase stack are up
#   2. `supabase db reset`  -> replays every migration and seed.sql from scratch
#   3. runs both SQL test suites and counts PASS / FAIL
#   4. prints the test accounts and what to look for in the app
#
# READ THIS ONCE, then you can ignore the noise:
#
#   The test suites raise database ERRORs ON PURPOSE. Roughly a third of the
#   assertions are negative tests - "a member of another park must NOT be able
#   to insert here", "nobody may overwrite a determination". For those, the
#   ERROR line IS the pass. The only thing that means something went wrong is
#   the word FAIL, and the summary at the end counts them.
#
#   (Earlier this script died on the first such error. Windows PowerShell 5.1
#   turns any native command's stderr into a terminating error when
#   $ErrorActionPreference is 'Stop'. Every docker call now goes through
#   Invoke-Native, which drops to 'Continue' for the duration.)
#
# WARNING: `db reset` DESTROYS the local database and rebuilds it. Every account
#    made with tools/provision_org.ps1 disappears - those live only in the
#    running database, not in a migration or the seed. That is why testPark_A
#    and its admin are in supabase/seed.sql: the seed is the only thing that
#    survives a reset. Local dev data only; nothing in production is touched.
# ============================================================================
param(
    [switch]$SkipReset,
    [string]$Container = 'supabase_db_conservation_app'
)

$ErrorActionPreference = 'Stop'

# psql writes to stderr for every NOTICE and every ERROR, and the negative tests
# raise errors deliberately. Under PowerShell 5.1 that aborts the script unless
# $ErrorActionPreference is relaxed for the duration of the call.
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # ToString() flattens the ErrorRecords that 2>&1 makes out of a native
        # command's stderr. Without it PowerShell renders each one as a
        # multi-line "NativeCommandError / CategoryInfo / FullyQualifiedErrorId"
        # block in the middle of the psql output, which buries the actual
        # message under six lines of noise.
        (& $Command 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    }
    finally { $ErrorActionPreference = $prev }
}

function Head($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Bad($t)  { Write-Host "   $t" -ForegroundColor Red }

# ---- 0. prerequisites -------------------------------------------------------
Head "Checking prerequisites"
$dockerOut = Invoke-Native { docker info }
if ($LASTEXITCODE -ne 0) { Bad "Docker is not running. Start Docker Desktop and try again."; exit 1 }
Ok "Docker is running"

$cliOut = Invoke-Native { supabase --version }
if ($LASTEXITCODE -ne 0) { Bad "The Supabase CLI is not on PATH."; exit 1 }
Ok "Supabase CLI found ($($cliOut.Trim()))"

$running = Invoke-Native { docker ps --filter "name=$Container" --format "{{.Names}}" }
if (-not $running.Trim()) {
    Write-Host "   Supabase is not running - starting it (this can take a minute)..." -ForegroundColor Yellow
    supabase start
    if ($LASTEXITCODE -ne 0) { Bad "supabase start failed."; exit 1 }
}
Ok "Supabase stack is up"

# ---- 1. reset ---------------------------------------------------------------
if (-not $SkipReset) {
    Head "Applying all migrations and reseeding (supabase db reset)"
    Write-Host "   This wipes the LOCAL database and replays every migration + seed.sql." -ForegroundColor DarkGray
    supabase db reset
    if ($LASTEXITCODE -ne 0) { Bad "db reset failed - see the output above."; exit 1 }
    Ok "Migrations applied and seed loaded"
} else {
    Head "Skipping reset (-SkipReset)"
}

# ---- 2. what actually exists now --------------------------------------------
Head "Tables and views now in the database"
$sqlObjects = "select string_agg(c.relname, ', ' order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','v') and c.relname not in ('spatial_ref_sys','geography_columns','geometry_columns');"
$objects = Invoke-Native { docker exec -i $Container psql -U postgres -d postgres -At -c $sqlObjects }
Write-Host "   $($objects.Trim())"

Head "Parks"
$sqlParks = "select string_agg(name || ' (' || coalesce(publishing_status,'?') || ')', ', ' order by name) from public.organizations;"
$parks = Invoke-Native { docker exec -i $Container psql -U postgres -d postgres -At -c $sqlParks }
Write-Host "   $($parks.Trim())"

# ---- 3. the test suites -----------------------------------------------------
$suites = @(
    'supabase/tests/test_observations_rls.sql',
    'supabase/tests/test_org_context_and_export.sql',
    'supabase/tests/test_function_privileges.sql'
)
$totalPass = 0; $totalFail = 0; $totalErr = 0
foreach ($suite in $suites) {
    if (-not (Test-Path $suite)) { Bad "missing: $suite"; continue }
    Head "Running $suite"

    # Copy the file INTO the container and run it with psql -f rather than
    # piping it to stdin: a pipe goes through PowerShell's default encoding,
    # which can mangle the file on the way in. A file copy cannot.
    $inContainer = "/tmp/" + (Split-Path $suite -Leaf)
    Invoke-Native { docker cp $suite "${Container}:$inContainer" } | Out-Null
    $out = Invoke-Native { docker exec -i $Container psql -U postgres -d postgres -f $inContainer }
    Invoke-Native { docker exec -i $Container rm -f $inContainer } | Out-Null

    $pass = ([regex]::Matches($out, '(?m)^\s*PASS\b')).Count
    $fail = ([regex]::Matches($out, '(?m)^\s*FAIL\b')).Count
    $errs = ([regex]::Matches($out, 'ERROR:')).Count
    $totalPass += $pass; $totalFail += $fail; $totalErr += $errs

    if ($fail -eq 0) { Ok "$pass assertions passed, 0 failed" }
    else {
        Bad "$pass passed, $fail FAILED"
        ($out -split "`n") | Where-Object { $_ -match 'FAIL' } | ForEach-Object {
            Write-Host "      $($_.Trim())" -ForegroundColor Red
        }
    }
    Write-Host "      ($errs database errors - EXPECTED; the negative tests assert refusal)" -ForegroundColor DarkGray

    if ($fail -gt 0 -or $pass -eq 0) {
        Write-Host "      full output follows:" -ForegroundColor DarkGray
        Write-Host $out
    }
}

# ---- 4. a look at the data the app will show --------------------------------
# Same file-copy mechanism as the suites: every Darwin Core column name is a
# quoted identifier, and PowerShell mangles embedded double quotes on their way
# to a native command.
Head "testPark_A"
$show = 'supabase/tests/show_testpark.sql'
if (Test-Path $show) {
    Invoke-Native { docker cp $show "${Container}:/tmp/show_testpark.sql" } | Out-Null
    Write-Host (Invoke-Native { docker exec -i $Container psql -U postgres -d postgres -f /tmp/show_testpark.sql })
    Invoke-Native { docker exec -i $Container rm -f /tmp/show_testpark.sql } | Out-Null
} else {
    Bad "missing: $show"
}

# ---- 5. summary -------------------------------------------------------------
Write-Host ""
if ($totalFail -eq 0 -and $totalPass -gt 0) {
    Write-Host "ALL $totalPass ASSERTIONS PASSED  ($totalErr expected errors along the way)" -ForegroundColor Green
} elseif ($totalPass -eq 0) {
    Write-Host "NO assertions ran - something is wrong with the suites or the container." -ForegroundColor Red
} else {
    Write-Host "$totalPass passed, $totalFail FAILED - see above" -ForegroundColor Red
}

Write-Host ""
Write-Host "Sign in to the app with:" -ForegroundColor Cyan
Write-Host "   admin@park.at  / password123   admin of testPark_A"
Write-Host "   ranger@park.at / password123   member of testPark_A"
Write-Host "   ranger@test.at / password123   member of THREE parks - use this to test the switcher"
Write-Host ""
Write-Host "Then check, in order:" -ForegroundColor Cyan
Write-Host "   1. Records tab shows one record in testPark_A"
Write-Host "   2. + Record  ->  fill it in  ->  Save        (lat ~47.15, lon ~12.75)"
Write-Host "   3. tap a record  ->  edit it  ->  the three determinations are listed"
Write-Host "   4. Settings -> People -> Invite               (admin only)"
Write-Host "   5. Settings -> People -> ... -> Remove        (records survive)"
Write-Host "   6. sign in as ranger@test.at -> Settings -> switch park"
Write-Host ""
Write-Host "Studio: http://127.0.0.1:54323    Mail (invitations): http://127.0.0.1:54324" -ForegroundColor DarkGray
if (-not $SkipReset) {
    Write-Host "Remember: adb reverse tcp:54321 tcp:54321   (tools\dev_connect.ps1)" -ForegroundColor DarkGray
}
