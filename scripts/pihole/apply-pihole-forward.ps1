Param(
  [string]$Domain = "mycavanaughnetwork.com",
  [string]$ForwardIp = "192.168.0.36",   # k8s_gateway DNS LB
  [string]$PiHoleHost = "192.168.0.99",
  [string]$PiHoleUser = "root",
  [string]$PiHoleContainer = "",         # set to container name/id if using Docker/Podman
  [string]$ContainerEngine = "docker",   # or "podman"
  [int]$Port = 22,
  [string]$IdentityFile = ""             # leave empty for password auth
)

$ErrorActionPreference = 'Stop'

function Invoke-Exec {
  param([string]$FilePath, [string[]]$ArgList)
  Write-Host "`n> $FilePath $($ArgList -join ' ')" -ForegroundColor Cyan
  $p = Start-Process -FilePath $FilePath -ArgumentList $ArgList -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -ne 0) { throw "Command failed ($($p.ExitCode)): $FilePath $($ArgList -join ' ')" }
}

# Ensure ssh/scp exist
foreach ($cmd in @('ssh','scp')) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    throw "'$cmd' not found. Install Windows OpenSSH client or add to PATH."
  }
}

# Build temp config (ensure trailing newline)
$content = @(
  "server=/$Domain/$ForwardIp",
  "rebind-domain-ok=/$Domain/"
) -join "`n" + "`n"

$tmp = [System.IO.Path]::GetTempFileName()
Set-Content -LiteralPath $tmp -Value $content -Encoding ascii
Write-Host "Created temp config: $tmp" -ForegroundColor Green

try {
  # scp → /tmp
  $scpArgs = @()
  if ($IdentityFile) { $scpArgs += @('-i', $IdentityFile, '-o','IdentitiesOnly=yes') }
  if ($Port)        { $scpArgs += @('-P', "$Port") }
  $scpArgs += @('-o','StrictHostKeyChecking=accept-new', $tmp, "$($PiHoleUser)@$($PiHoleHost):/tmp/15-k8s-gateway.conf")
  Invoke-Exec -FilePath 'scp' -ArgList $scpArgs

  # remote actions
  $sudo = 'sudo'
  $installHostPath = '/etc/dnsmasq.d/15-k8s-gateway.conf'
  if ($PiHoleContainer) {
    # If your user needs sudo to run the engine, keep $sudo; otherwise set $sudo='' above.
    $remoteCmd = "$sudo $ContainerEngine cp /tmp/15-k8s-gateway.conf $($PiHoleContainer):$installHostPath && " +
                 "$sudo $ContainerEngine exec $($PiHoleContainer) pihole restartdns && rm -f /tmp/15-k8s-gateway.conf"
  } else {
    $remoteCmd = "$sudo install -m 0644 -o root -g root /tmp/15-k8s-gateway.conf $installHostPath && " +
                 "$sudo pihole restartdns && rm -f /tmp/15-k8s-gateway.conf"
  }

  $sshArgs = @()
  if ($IdentityFile) { $sshArgs += @('-i', $IdentityFile, '-o','IdentitiesOnly=yes') }
  if ($Port)        { $sshArgs += @('-p', "$Port") }
  $sshArgs += @('-o','StrictHostKeyChecking=accept-new', "$($PiHoleUser)@$($PiHoleHost)", $remoteCmd)
  Invoke-Exec -FilePath 'ssh' -ArgList $sshArgs

  Write-Host "Done. Validate from Windows:" -ForegroundColor Green
  Write-Host "  ipconfig /flushdns" -ForegroundColor Yellow
  Write-Host "  nslookup longhorn.$Domain $PiHoleHost" -ForegroundColor Yellow
  Write-Host "Expected answer: 192.168.0.37 (internal gateway)" -ForegroundColor Yellow
}
finally {
  if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
