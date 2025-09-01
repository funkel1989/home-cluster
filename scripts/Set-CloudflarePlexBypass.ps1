#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
Creates/updates a Cloudflare Page Rule to bypass security, performance (incl. Rocket Loader), and caching for a Plex hostname.

.DESCRIPTION
This script upserts a Page Rule for the given hostname pattern (e.g., plex.example.com/*) that:
  - Disables Security (WAF/BIC/bot challenges) for the host
  - Disables Performance features (e.g., Rocket Loader)
  - Disables Apps
  - Sets Cache Level to Bypass

This is useful for Plex Web, which breaks when Cloudflare challenges or Rocket Loader interfere with its SPA bootstrap.

.PARAMETER ApiToken
Cloudflare API token with scopes: Zone:Read and Page Rules:Edit for the zone.

.PARAMETER GlobalApiKey
Cloudflare Global API Key (alternative to ApiToken). Requires accompanying Email.

.PARAMETER Email
Cloudflare account email (used with GlobalApiKey authentication).

.PARAMETER ZoneName
Cloudflare zone name, e.g. mycavanaughnetwork.com

.PARAMETER Hostname
The Plex hostname, e.g. plex.mycavanaughnetwork.com

.PARAMETER Priority
Page Rule priority (lower numbers are evaluated first). Defaults to 1.

.PARAMETER PurgeHostnameCache
If set, purges Cloudflare cache for the hostname after applying the rule.

.EXAMPLE (API Token)
./Set-CloudflarePlexBypass.ps1 -ApiToken 'CF_TOKEN' -ZoneName 'mycavanaughnetwork.com' -Hostname 'plex.mycavanaughnetwork.com' -PurgeHostnameCache

.EXAMPLE (Global API Key)
./Set-CloudflarePlexBypass.ps1 -GlobalApiKey 'CF_GLOBAL_KEY' -Email 'you@example.com' -ZoneName 'mycavanaughnetwork.com' -Hostname 'plex.mycavanaughnetwork.com' -PurgeHostnameCache

#>

param(
    # Auth: choose ONE method
    [Parameter(Mandatory=$false)] [string] $ApiToken,
    [Parameter(Mandatory=$false)] [string] $GlobalApiKey,
    [Parameter(Mandatory=$false)] [string] $Email,

    # Common
    [Parameter(Mandatory=$true)] [string] $ZoneName,
    [Parameter(Mandatory=$true)] [string] $Hostname,
    [int] $Priority = 1,
    [switch] $PurgeHostnameCache
)

if (-not $ApiToken -and (-not $GlobalApiKey -or -not $Email)) {
    throw "Provide either -ApiToken or both -GlobalApiKey and -Email."
}

function Invoke-CfApi {
    param(
        [Parameter(Mandatory=$true)] [ValidateSet('GET','POST','PATCH','DELETE')] [string] $Method,
        [Parameter(Mandatory=$true)] [string] $Path,
        [Parameter()] [string] $BodyJson
    )
    $uri = "https://api.cloudflare.com/client/v4$Path"
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($ApiToken) {
        $headers['Authorization'] = "Bearer $ApiToken"
    } else {
        $headers['X-Auth-Key']   = $GlobalApiKey
        $headers['X-Auth-Email'] = $Email
    }
    if ($PSBoundParameters.ContainsKey('BodyJson')) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $BodyJson
    } else {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
    }
}

Write-Host "Looking up Zone ID for '$ZoneName'..." -ForegroundColor Cyan
$zoneResp = Invoke-CfApi -Method GET -Path "/zones?name=$ZoneName"
$zoneId = $zoneResp.result[0].id
if (-not $zoneId) { throw "Could not find zone id for zone '$ZoneName'" }
Write-Host "Zone ID: $zoneId" -ForegroundColor Green

$targetValue = "$Hostname/*"

Write-Host "Fetching existing Page Rules..." -ForegroundColor Cyan
$rulesResp = Invoke-CfApi -Method GET -Path "/zones/$zoneId/pagerules"
$existingRule = $rulesResp.result | Where-Object { $_.targets.constraint.value -eq $targetValue -or $_.targets[0].constraint.value -eq $targetValue } | Select-Object -First 1

$body = @{ 
    status   = 'active'
    priority = $Priority
    actions  = @(
        @{ id = 'disable_security' }
        @{ id = 'disable_apps' }
        @{ id = 'disable_performance' }
        @{ id = 'cache_level'; value = 'bypass' }
    )
    targets  = @(
        @{ target = 'url'; constraint = @{ operator = 'matches'; value = $targetValue } }
    )
} | ConvertTo-Json -Depth 6

if ($existingRule) {
    Write-Host "Updating existing Page Rule '$($existingRule.id)' for $targetValue ..." -ForegroundColor Yellow
    $update = Invoke-CfApi -Method PATCH -Path "/zones/$zoneId/pagerules/$($existingRule.id)" -BodyJson $body
    if (-not $update.success) { throw "Cloudflare API update failed: $($update | ConvertTo-Json -Depth 6)" }
    Write-Host "Updated Page Rule: $($update.result.id)" -ForegroundColor Green
} else {
    Write-Host "Creating Page Rule for $targetValue ..." -ForegroundColor Yellow
    $create = Invoke-CfApi -Method POST -Path "/zones/$zoneId/pagerules" -BodyJson $body
    if (-not $create.success) { throw "Cloudflare API create failed: $($create | ConvertTo-Json -Depth 6)" }
    Write-Host "Created Page Rule: $($create.result.id)" -ForegroundColor Green
}

if ($PurgeHostnameCache) {
    Write-Host "Purging cache for hostname '$Hostname'..." -ForegroundColor Cyan
    $purgeBody = @{ hosts = @($Hostname) } | ConvertTo-Json
    $purge = Invoke-CfApi -Method POST -Path "/zones/$zoneId/purge_cache" -BodyJson $purgeBody
    if (-not $purge.success) { throw "Cloudflare cache purge failed: $($purge | ConvertTo-Json -Depth 6)" }
    Write-Host "Cache purge requested." -ForegroundColor Green
}

Write-Host "Done. Verify in Cloudflare: Rules → Page Rules. Then test Plex in a Private window." -ForegroundColor Green
