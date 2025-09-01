#requires -Version 7.0
param(
    # Auth: choose ONE method
    [Parameter(Mandatory=$false)] [string] $ApiToken,
    [Parameter(Mandatory=$false)] [string] $GlobalApiKey,
    [Parameter(Mandatory=$false)] [string] $Email,

    # Zone + host context
    [Parameter(Mandatory=$true)] [string] $ZoneName,
    [string] $Hostname = 'plex.mycavanaughnetwork.com',

    # What to do (defaults: disable for troubleshooting)
    [switch] $DisableRocketLoader,
    [switch] $DisableBrowserIntegrityCheck,
    [switch] $DisableBotFightMode,
    [switch] $SecurityEssentiallyOff,
    [switch] $DisableAutomaticHttpsRewrites,
    [switch] $DisableEmailObfuscation,
    [switch] $PurgeHostnameCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ApiToken -and (-not $GlobalApiKey -or -not $Email)) {
    throw "Provide either -ApiToken or both -GlobalApiKey and -Email."
}

function Invoke-CfApi {
    param(
        [Parameter(Mandatory=$true)] [ValidateSet('GET','PATCH','POST')] [string] $Method,
        [Parameter(Mandatory=$true)] [string] $Path,
        [Parameter()] [hashtable] $Body
    )
    $uri = "https://api.cloudflare.com/client/v4$Path"
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($ApiToken) { $headers['Authorization'] = "Bearer $ApiToken" }
    else { $headers['X-Auth-Key'] = $GlobalApiKey; $headers['X-Auth-Email'] = $Email }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $json = $Body | ConvertTo-Json -Depth 6
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $json
    } else {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
    }
}

Write-Host "Looking up Zone ID for '$ZoneName'..." -ForegroundColor Cyan
$zoneResp = Invoke-CfApi -Method GET -Path "/zones?name=$ZoneName"
$zoneId = $zoneResp.result[0].id
if (-not $zoneId) { throw "Could not find zone id for zone '$ZoneName'" }
Write-Host "Zone ID: $zoneId" -ForegroundColor Green

function Set-Setting {
    param([string] $Key, [string] $Value)
    Write-Host "Setting '$Key' => '$Value'" -ForegroundColor Yellow
    $resp = Invoke-CfApi -Method PATCH -Path "/zones/$zoneId/settings/$Key" -Body @{ value = $Value }
    if (-not $resp.success) { throw "Failed to set ${Key}: $($resp | ConvertTo-Json -Depth 6)" }
}

if ($DisableRocketLoader) { Set-Setting -Key 'rocket_loader' -Value 'off' }
if ($DisableBrowserIntegrityCheck) { Set-Setting -Key 'browser_check' -Value 'off' }
if ($SecurityEssentiallyOff) { Set-Setting -Key 'security_level' -Value 'essentially_off' }
if ($DisableAutomaticHttpsRewrites) { Set-Setting -Key 'automatic_https_rewrites' -Value 'off' }
if ($DisableEmailObfuscation) { Set-Setting -Key 'email_obfuscation' -Value 'off' }
if ($DisableBotFightMode) {
    Write-Host "Disabling bot fight mode" -ForegroundColor Yellow
    $resp = Invoke-CfApi -Method PATCH -Path "/zones/$zoneId/settings/bot_fight_mode" -Body @{ value = 'off' }
    if (-not $resp.success) { throw "Failed to set bot_fight_mode: $($resp | ConvertTo-Json -Depth 6)" }
}

if ($PurgeHostnameCache) {
    Write-Host "Purging cache for '$Hostname'..." -ForegroundColor Cyan
    $purge = Invoke-CfApi -Method POST -Path "/zones/$zoneId/purge_cache" -Body @{ hosts = @($Hostname) }
    if (-not $purge.success) { throw "Cache purge failed: $($purge | ConvertTo-Json -Depth 6)" }
}

Write-Host "All requested settings applied." -ForegroundColor Green
