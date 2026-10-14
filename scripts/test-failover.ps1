<#
.SYNOPSIS
  End-to-end failover test: stops the whole backend-1 EC2 instance while sending
  traffic through Nginx, verifies every request still succeeds on backend-2, starts
  backend-1 again and verifies the load is shared again. Writes docs/results.md.
.EXAMPLE
  .\scripts\test-failover.ps1 -Requests 20
#>
param(
    [string]$Url,
    [string]$InstanceId,
    [string]$Region,
    [int]$Requests = 20,
    [int]$TimeoutMinutes = 6
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $Url)        { $Url = Get-TfOutput 'app_url' }
if (-not $InstanceId) { $InstanceId = Get-BackendInstanceId 'backend-1' }
if (-not $Region)     { $Region = (aws configure get region); if (-not $Region) { $Region = 'ap-south-1' } }

$docsDir = Join-Path $PSScriptRoot '..\docs'
New-Item -ItemType Directory -Force $docsDir | Out-Null
$all = New-Object System.Collections.Generic.List[object]
$summaries = New-Object System.Collections.Generic.List[object]
$startedAt = Get-Date

function Get-InstanceState {
    aws ec2 describe-instances --region $Region --instance-ids $InstanceId `
        --query 'Reservations[0].Instances[0].State.Name' --output text
}

function Invoke-FixedPhase([string]$Phase) {
    Write-Host "`n== $Phase ($Requests requests)" -ForegroundColor Cyan
    $phaseResults = foreach ($i in 1..$Requests) {
        $r = Send-LbRequest $Url $Phase
        Write-LbRequest $r
        $r
    }
    $phaseResults | ForEach-Object { $all.Add($_) }
    $summaries.Add((Get-LbSummary $phaseResults $Phase))
}

# Keeps sending requests until $Until returns true; used while AWS changes instance state.
function Invoke-UntilPhase([string]$Phase, [scriptblock]$Until) {
    Write-Host "`n== $Phase" -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $phaseResults = New-Object System.Collections.Generic.List[object]
    $n = 0
    while ($true) {
        $r = Send-LbRequest $Url $Phase
        Write-LbRequest $r
        $phaseResults.Add($r); $all.Add($r)
        $n++
        if (& $Until $r $n) { break }
        if ((Get-Date) -gt $deadline) { Write-Warning "$Phase timed out after $TimeoutMinutes minutes"; break }
        Start-Sleep -Milliseconds 500
    }
    $summaries.Add((Get-LbSummary $phaseResults $Phase))
}

Write-Host "Failover test against $Url (backend-1 = $InstanceId, region $Region)" -ForegroundColor Cyan

# 1. Both backends healthy.
Invoke-FixedPhase '1. Baseline (both up)'

# 2. Stop the whole backend-1 instance and keep sending traffic while it shuts down.
Write-Host "`n>> Stopping backend-1 instance $InstanceId" -ForegroundColor Magenta
aws ec2 stop-instances --region $Region --instance-ids $InstanceId | Out-Null
$stopIssuedAt = Get-Date
Invoke-UntilPhase '2. During shutdown' { param($r, $n) ($n % 5 -eq 0) -and ((Get-InstanceState) -eq 'stopped') }
$stoppedAfter = [int]((Get-Date) - $stopIssuedAt).TotalSeconds

# 3. backend-1 fully stopped: everything must be served by backend-2.
Invoke-FixedPhase '3. Backend-1 stopped'

# 4. Start backend-1 again and wait until Nginx routes traffic to it.
Write-Host "`n>> Starting backend-1 instance $InstanceId" -ForegroundColor Magenta
aws ec2 start-instances --region $Region --instance-ids $InstanceId | Out-Null
$startIssuedAt = Get-Date
Invoke-UntilPhase '4. During recovery' { param($r, $n) $r.Backend -eq 'backend-1' }
$recoveredAfter = [int]((Get-Date) - $startIssuedAt).TotalSeconds

# 5. Both backends healthy again.
Invoke-FixedPhase '5. After recovery'

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
$s = @{}; foreach ($x in $summaries) { $s[$x.Phase] = $x }
$checks = [ordered]@{
    'Baseline uses both backends'                 = ($s['1. Baseline (both up)'].Backend1 -gt 0 -and $s['1. Baseline (both up)'].Backend2 -gt 0)
    'No failed requests during shutdown'          = ($s['2. During shutdown'].Failures -eq 0)
    'All requests served by backend-2 while down' = ($s['3. Backend-1 stopped'].Backend2 -eq $Requests)
    'No failed requests during recovery'          = ($s['4. During recovery'].Failures -eq 0)
    'Both backends used again after recovery'     = ($s['5. After recovery'].Backend1 -gt 0 -and $s['5. After recovery'].Backend2 -gt 0)
}
$passed = -not ($checks.Values -contains $false)

Write-Host ''
$summaries | Format-Table -AutoSize
foreach ($k in $checks.Keys) {
    $mark = 'FAIL'; $col = 'Red'
    if ($checks[$k]) { $mark = 'PASS'; $col = 'Green' }
    Write-Host ("  [{0}] {1}" -f $mark, $k) -ForegroundColor $col
}
$verdict = 'FAILED'; if ($passed) { $verdict = 'PASSED' }
Write-Host "`nOverall: $verdict" -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })

# ---------------------------------------------------------------------------
# Evidence: docs/results.md and docs/failover-requests.csv
# ---------------------------------------------------------------------------
$csvPath = Join-Path $docsDir 'failover-requests.csv'
$all | Export-Csv -NoTypeInformation -Encoding UTF8 $csvPath

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Failover Test Results')
$md.Add('')
$md.Add("- **Run:** $($startedAt.ToString('yyyy-MM-dd HH:mm:ss')) (local time)")
$md.Add("- **Endpoint:** $Url")
$md.Add("- **Failure injected:** whole EC2 instance ``backend-1`` ($InstanceId) stopped with ``aws ec2 stop-instances``")
$md.Add("- **Instance fully stopped after:** $stoppedAfter s")
$md.Add("- **backend-1 serving again after start:** $recoveredAfter s")
$md.Add("- **Overall result:** **$verdict**")
$md.Add('')
$md.Add('## Summary')
$md.Add('')
$md.Add('| Phase | Requests | backend-1 | backend-2 | Failed | Avg ms | Max ms |')
$md.Add('|---|---|---|---|---|---|---|')
foreach ($x in $summaries) {
    $md.Add("| $($x.Phase) | $($x.Requests) | $($x.Backend1) | $($x.Backend2) | $($x.Failures) | $($x.AvgMs) | $($x.MaxMs) |")
}
$md.Add('')
$md.Add('## Checks')
$md.Add('')
foreach ($k in $checks.Keys) {
    # Emoji via code points: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
    $mark = [char]0x274C; if ($checks[$k]) { $mark = [char]0x2705 }
    $md.Add("- $mark $k")
}
$md.Add('')
$md.Add('## Notable requests')
$md.Add('')
$md.Add('Requests that were retried on the other backend (two upstream addresses), slower than 1 s, or failed.')
$md.Add('')
$md.Add('| Phase | Time | Status | Served by | Upstream tried | ms |')
$md.Add('|---|---|---|---|---|---|')
$notable = @($all | Where-Object { $_.Status -ne 200 -or $_.Ms -gt 1000 -or "$($_.Upstream)" -like '*,*' })
if ($notable.Count -eq 0) {
    $md.Add('| – | – | – | – | none | – |')
} else {
    foreach ($r in $notable) { $md.Add("| $($r.Phase) | $($r.Time) | $($r.Status) | $($r.Backend) | $($r.Upstream) | $($r.Ms) |") }
}
$md.Add('')
$md.Add('Full per-request log: [failover-requests.csv](failover-requests.csv)')

$md | Out-File -Encoding utf8 (Join-Path $docsDir 'results.md')
Write-Host "Evidence written to docs\results.md and docs\failover-requests.csv"

if (-not $passed) { exit 1 }
