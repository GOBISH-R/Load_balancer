<#
.SYNOPSIS
  Failover under sustained load: keeps load-test.py running for -Duration seconds while
  the whole backend-1 EC2 instance is stopped and started again. Writes the evidence to
  docs/failover-under-load.md (+ per-request CSV).
.EXAMPLE
  .\scripts\test-failover-under-load.ps1 -Duration 150 -Concurrency 100
#>
param(
    [int]$Duration = 150,
    [int]$Concurrency = 100,
    [int]$BaselineSeconds = 15,
    [int]$DownSeconds = 15,
    [string]$Region
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $Region) { $Region = (aws configure get region); if (-not $Region) { $Region = 'ap-south-1' } }
$url        = Get-TfOutput 'app_url'
$instanceId = Get-BackendInstanceId 'backend-1'
$docsDir    = Join-Path $PSScriptRoot '..\docs'
New-Item -ItemType Directory -Force $docsDir | Out-Null
$rawOut  = Join-Path $docsDir 'failover-under-load.txt'
$rawErr  = Join-Path $docsDir 'failover-under-load.err.txt'
$csvPath = Join-Path $docsDir 'failover-under-load.csv'
$loadScript = Join-Path $PSScriptRoot 'load-test.py'

$events = New-Object System.Collections.Generic.List[object]
function Add-Event([string]$Text) {
    $e = [pscustomobject]@{ Time = (Get-Date).ToString('HH:mm:ss'); Event = $Text }
    $events.Add($e)
    Write-Host ("  {0}  {1}" -f $e.Time, $e.Event) -ForegroundColor Magenta
}

function Get-InstanceState {
    aws ec2 describe-instances --region $Region --instance-ids $instanceId `
        --query 'Reservations[0].Instances[0].State.Name' --output text
}

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSeconds, [int]$PollSeconds = 2) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep $PollSeconds
    }
    return $false
}

Write-Host "Failover under load: $Concurrency concurrent clients for $Duration s against $url" -ForegroundColor Cyan
Write-Host "backend-1 = $instanceId ($Region)`n" -ForegroundColor Cyan

$python = (Get-Command python).Source
$load = Start-Process $python -NoNewWindow -PassThru `
    -RedirectStandardOutput $rawOut -RedirectStandardError $rawErr `
    -ArgumentList @('-I', "`"$loadScript`"", '--url', $url, '--duration', $Duration,
                    '-c', $Concurrency, '--csv', "`"$csvPath`"")
Add-Event "Load test started ($Concurrency concurrent clients, $Duration s)"

Start-Sleep $BaselineSeconds

aws ec2 stop-instances --region $Region --instance-ids $instanceId | Out-Null
Add-Event 'Stop issued for the backend-1 EC2 instance'
if (Wait-Until { (Get-InstanceState) -eq 'stopped' } 240) { Add-Event 'backend-1 instance fully stopped' }
else { Add-Event 'WARNING: backend-1 did not reach "stopped" within 4 minutes' }

Start-Sleep $DownSeconds

aws ec2 start-instances --region $Region --instance-ids $instanceId | Out-Null
Add-Event 'Start issued for the backend-1 EC2 instance'
if (Wait-Until { (Get-InstanceState) -eq 'running' } 240) { Add-Event 'backend-1 instance running (booting, container starting)' }

$serving = Wait-Until {
    try { (Invoke-WebRequest "$($url)api" -UseBasicParsing -TimeoutSec 5).Headers['X-Backend-Server'] -eq 'backend-1' } catch { $false }
} 240 1
if ($serving) { Add-Event 'backend-1 serving traffic again (Nginx put it back in rotation)' }
else { Add-Event 'WARNING: backend-1 not serving within 4 minutes of start' }

if (-not $load.HasExited) { Write-Host "`n  waiting for the load test to finish..." }
$load.WaitForExit()
Add-Event 'Load test finished'

$output = Get-Content $rawOut | Where-Object { $_ -notmatch 'progress:' }
# Verdict from the report itself (Start-Process exit codes are unreliable in Windows PowerShell 5.1).
$failedLine = $output | Where-Object { $_ -match '^\s+Failed\s+(\d+)' } | Select-Object -First 1
$loadExit = 1
if ($failedLine -and [int]($failedLine -replace '\D', '') -eq 0) { $loadExit = 0 }
Write-Host ''
$output | ForEach-Object { Write-Host $_ }

$verdict = 'PASSED (0 failed requests)'
if ($loadExit -ne 0) { $verdict = 'FAILED (some requests failed, see below)' }
Write-Host "`nOverall: $verdict" -ForegroundColor $(if ($loadExit -eq 0) { 'Green' } else { 'Red' })

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Failover Under Load')
$md.Add('')
$md.Add("- **Endpoint:** $url")
$md.Add("- **Load:** $Concurrency concurrent clients for $Duration s (``scripts/load-test.py``)")
$md.Add("- **Failure injected:** whole EC2 instance ``backend-1`` ($instanceId) stopped, then started again")
$md.Add("- **Result:** **$verdict**")
$md.Add('')
$md.Add('## Events')
$md.Add('')
$md.Add('| Time | Event |')
$md.Add('|---|---|')
foreach ($e in $events) { $md.Add("| $($e.Time) | $($e.Event) |") }
$md.Add('')
$md.Add('## Load test output')
$md.Add('')
$md.Add('Read the timeline next to the event times: backend-1 drops to 0 while it is stopped, backend-2 takes')
$md.Add('all traffic, and the failed column stays at 0. "retried" counts requests Nginx re-sent to the other')
$md.Add('backend after the first one did not answer.')
$md.Add('')
$md.Add('```text')
$output | ForEach-Object { $md.Add($_) }
$md.Add('```')
$md.Add('')
$md.Add('Per-request log: [failover-under-load.csv](failover-under-load.csv)')
$md | Out-File -Encoding utf8 (Join-Path $docsDir 'failover-under-load.md')
Remove-Item $rawOut, $rawErr -ErrorAction SilentlyContinue
Write-Host "Evidence written to docs\failover-under-load.md and docs\failover-under-load.csv"

exit $loadExit
