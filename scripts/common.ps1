# Shared helpers for the load-balancer test scripts (Windows PowerShell 5.1+).

$script:TfDir = (Resolve-Path (Join-Path $PSScriptRoot '..\terraform')).Path

function Get-TfOutput([string]$Name) {
    $value = terraform "-chdir=$script:TfDir" output -raw $Name
    if ($LASTEXITCODE -ne 0 -or -not $value) { throw "Could not read terraform output '$Name'. Run 'terraform apply' first." }
    return $value
}

function Get-BackendInstanceId([string]$Backend) {
    $json = terraform "-chdir=$script:TfDir" output -json backend_instance_ids | Out-String
    return ($json | ConvertFrom-Json).$Backend
}

# Sends one request through the proxy and records who served it and how long it took.
function Send-LbRequest([string]$Url, [string]$Phase = '') {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $result = [pscustomobject]@{
        Phase    = $Phase
        Time     = (Get-Date).ToString('HH:mm:ss')
        Status   = 0
        Backend  = '-'
        Upstream = '-'
        Ms       = 0
    }
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15 -Headers @{ Accept = '*/*' }
        $result.Status   = [int]$r.StatusCode
        $result.Backend  = $r.Headers['X-Backend-Server']
        $result.Upstream = $r.Headers['X-Upstream-Addr']
    } catch {
        if ($_.Exception.Response) { $result.Status = [int]$_.Exception.Response.StatusCode }
    }
    $sw.Stop()
    $result.Ms = $sw.ElapsedMilliseconds
    return $result
}

function Write-LbRequest($r) {
    $color = 'Green'
    if ($r.Status -ne 200) { $color = 'Red' } elseif ($r.Ms -gt 1000) { $color = 'Yellow' }
    Write-Host ("  {0}  {1,3}  {2,-10} upstream={3,-32} {4,5} ms" -f $r.Time, $r.Status, $r.Backend, $r.Upstream, $r.Ms) -ForegroundColor $color
}

# Per-phase summary: request count, hits per backend, failures, latency.
function Get-LbSummary($Results, [string]$Phase) {
    # Flatten to a plain array: PS 5.1 throws "Argument types do not match" for generic Lists here.
    $Results = @($Results | ForEach-Object { $_ })
    $ok = @($Results | Where-Object { $_.Status -eq 200 })
    $ms = $Results | Measure-Object -Property Ms -Average -Maximum
    [pscustomobject]@{
        Phase     = $Phase
        Requests  = @($Results).Count
        Backend1  = @($ok | Where-Object { $_.Backend -eq 'backend-1' }).Count
        Backend2  = @($ok | Where-Object { $_.Backend -eq 'backend-2' }).Count
        Failures  = @($Results).Count - $ok.Count
        AvgMs     = [int]$ms.Average
        MaxMs     = [int]$ms.Maximum
    }
}
