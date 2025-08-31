Param(
  [string]$Domain = "mycavanaughnetwork.com",
  [string]$ForwardIp = "192.168.0.36",
  [string]$PiHoleHost = "192.168.0.99",
  [string]$PiHoleUser = "pi",
  [string]$PiHoleContainer = "",
  [int]$Port = 22,
  [string]$IdentityFile = ""
)

$ErrorActionPreference = 'Stop'

function Invoke-Exec {
  param([string]$FilePath, [string[]]$Args)
  Write-Host "`n> $FilePath $($Args -join ' ')" -ForegroundColor Cyan
  $p = Start-Process -FilePath $FilePath -ArgumentList $Args -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -ne 0) { throw "Command failed ($($p.ExitCode)): $FilePath $($Args -join ' ')" }
}

try {
  # Ensure ssh/scp are available
  foreach ($cmd in @('ssh','scp')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
      throw "'$cmd' not found. Install Windows OpenSSH client (Settings > Optional Features) or add to PATH."
    }
  }

  # Build temp config file
  $content = @(
    "server=/$Domain/$ForwardIp",
    "rebind-domain-ok=/$Domain/"
  ) -join "`n"

  $tmp = [System.IO.Path]::GetTempFileName()
  Set-Content -LiteralPath $tmp -Value $content -NoNewline -Encoding ascii
  Write-Host "Created temp config: $tmp" -ForegroundColor Green

  # scp to host
  $scpArgs = @()
  if ($IdentityFile) { $scpArgs += @('-i', $IdentityFile) }
  if ($Port)        { $scpArgs += @('-P', "$Port") }
  $scpArgs += @($tmp, "$PiHoleUser@$PiHoleHost:/tmp/15-k8s-gateway.conf")
  Invoke-Exec -FilePath 'scp' -Args $scpArgs

  # ssh to install and restart DNS
  if ($PiHoleContainer) {
    $remoteCmd = "docker cp /tmp/15-k8s-gateway.conf $PiHoleContainer:/etc/dnsmasq.d/15-k8s-gateway.conf && docker exec $PiHoleContainer pihole restartdns && rm -f /tmp/15-k8s-gateway.conf"
  } else {
    $remoteCmd = "sudo mv /tmp/15-k8s-gateway.conf /etc/dnsmasq.d/15-k8s-gateway.conf && sudo chown root:root /etc/dnsmasq.d/15-k8s-gateway.conf && sudo chmod 644 /etc/dnsmasq.d/15-k8s-gateway.conf && sudo pihole restartdns"
  }

  $sshArgs = @()
  if ($IdentityFile) { $sshArgs += @('-i', $IdentityFile) }
  if ($Port)        { $sshArgs += @('-p', "$Port") }
  $sshArgs += @("$PiHoleUser@$PiHoleHost", $remoteCmd)
  Invoke-Exec -FilePath 'ssh' -Args $sshArgs

  Write-Host "Done. Validate from Windows:" -ForegroundColor Green
  Write-Host "  nslookup longhorn.$Domain $PiHoleHost" -ForegroundColor Yellow
  Write-Host "Expected answer: 192.168.0.37 (internal gateway)" -ForegroundColor Yellow
}
finally {
  if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

