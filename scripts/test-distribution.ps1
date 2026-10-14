<#
.SYNOPSIS
  Sends repeated requests through the Nginx proxy and shows how they were distributed.
.EXAMPLE
  .\scripts\test-distribution.ps1 -Count 20
#>
param(
    [string]$Url,
    [int]$Count = 20
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $Url) { $Url = Get-TfOutput 'app_url' }

Write-Host "Sending $Count requests to $Url" -ForegroundColor Cyan
$results = foreach ($i in 1..$Count) {
    $r = Send-LbRequest $Url 'distribution'
    Write-LbRequest $r
    $r
}

Get-LbSummary $results 'distribution' | Format-Table -AutoSize
