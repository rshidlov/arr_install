# One-click Windows setup for the arr stack: installs Docker Desktop (WSL2 backend), starts
# the stack, wires the apps together through their APIs (wire.py), generates the Homepage
# dashboard, and prints service addresses. Mac/Linux users: run setup.sh instead.
# Needs, next to this script: docker-compose.yml, wire.py, arr-config.json
#
# Usage (PowerShell):  powershell -ExecutionPolicy Bypass -File .\setup.ps1
# It re-launches itself as Administrator if needed.
# Optional: set $env:DATA_DIR to put torrents/media elsewhere (default: .\data next to this script).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Network  = 'arr-net'
$Services = @(
  @{ Name = 'homepage';     Port = 3000  },
  @{ Name = 'seerr';        Port = 5055  },
  @{ Name = 'plex';         Port = 32400 },
  @{ Name = 'sonarr';       Port = 8989  },
  @{ Name = 'radarr';       Port = 7878  },
  @{ Name = 'prowlarr';     Port = 9696  },
  @{ Name = 'qbittorrent';  Port = 8080  },
  @{ Name = 'flaresolverr'; Port = 8191  }
)

function Log($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "xx  $m" -ForegroundColor Red; exit 1 }

# ---------- self-elevate ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Log 'Re-launching as Administrator...'
  Start-Process powershell -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}

Set-Location $PSScriptRoot
foreach ($f in @('docker-compose.yml', 'wire.py', 'arr-config.json')) {
  if (-not (Test-Path $f)) { Die "$f not found next to setup.ps1" }
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
Log "Detected OS: Windows ($arch)"

# Run a native command quietly and return its exit code (avoids PowerShell stderr errors)
function Test-Cmd([string]$cmdline) {
  cmd /c "$cmdline >nul 2>&1"
  return ($LASTEXITCODE -eq 0)
}

function Add-DockerToPath {
  $bin = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'
  if ((Test-Path $bin) -and ($env:Path -notlike "*$bin*")) { $env:Path = "$bin;$env:Path" }
}

function Docker-Ready { return (Test-Cmd 'docker info') }

# ---------- 1. WSL2 ----------
if (-not (Test-Cmd 'wsl --status')) {
  Log 'Installing WSL2 (required by Docker Desktop)'
  wsl --install --no-distribution
  Warn 'If Windows says a restart is required, reboot and run this script again.'
}

# ---------- 2. Docker Desktop ----------
Add-DockerToPath
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Log 'Installing Docker Desktop via winget'
    winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
  } else {
    Log 'winget not found, downloading the Docker Desktop installer'
    $installer = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
    $url = "https://desktop.docker.com/win/main/$arch/Docker%20Desktop%20Installer.exe"
    Invoke-WebRequest -Uri $url -OutFile $installer
    Start-Process -FilePath $installer -ArgumentList 'install --quiet --accept-license' -Wait
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
  }
  Add-DockerToPath
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Die 'Docker was installed but is not on PATH yet. Close this window, open a new PowerShell, and re-run.'
  }
} else {
  Log 'Docker already installed'
}

# ---------- 3. Start Docker Desktop and wait ----------
if (-not (Docker-Ready)) {
  Log 'Starting Docker Desktop'
  $exe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
  if (Test-Path $exe) { Start-Process $exe }
  Log 'Waiting for the Docker engine (this can take a few minutes on first start)'
  for ($i = 0; $i -lt 90; $i++) {
    if (Docker-Ready) { break }
    Start-Sleep -Seconds 2
  }
  if (-not (Docker-Ready)) {
    Die 'Docker engine did not start. Open Docker Desktop once, accept any prompts, then re-run. If you see a permissions error, sign out and back in (you were just added to the docker-users group).'
  }
}
Log 'Docker engine is ready'
Log 'Docker Desktop starts at sign-in by default. Check Settings > General if you want to change that.'

# ---------- 4. .env, folders ----------
function Get-EnvValue([string]$key) {
  if (Test-Path '.env') {
    $line = Get-Content '.env' | Where-Object { $_ -like "$key=*" } | Select-Object -First 1
    if ($line) { return $line.Substring($key.Length + 1) }
  }
  return ''
}
function Set-EnvValue([string]$key, [string]$value) {
  $lines = @()
  if (Test-Path '.env') { $lines = @(Get-Content '.env' | Where-Object { $_ -notlike "$key=*" }) }
  $lines += "$key=$value"
  Set-Content -Path '.env' -Value $lines -Encoding ascii
}
function Set-EnvDefault([string]$key, [string]$value) {
  if (-not (Get-EnvValue $key)) { Set-EnvValue $key $value }
}
function New-Secret {
  $b = New-Object byte[] 18
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Host address other devices (and the dashboard links) should use
$lan = 'localhost'
try {
  $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
  $addr = Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 | Select-Object -First 1
  if ($addr) { $lan = $addr.IPAddress }
} catch { }

Log 'Updating .env (IDs, timezone, qBittorrent login, dashboard hosts)'
if (-not (Test-Path '.env')) { New-Item -ItemType File -Path '.env' | Out-Null }
$tz = 'UTC'
try {
  $iana = $null
  if ([System.TimeZoneInfo]::TryConvertWindowsIdToIanaId([System.TimeZoneInfo]::Local.Id, [ref]$iana)) { $tz = $iana }
} catch { }
Set-EnvDefault 'PUID' '1000'
Set-EnvDefault 'PGID' '1000'
Set-EnvDefault 'TZ' $tz
Set-EnvDefault 'QBIT_USER' 'admin'
Set-EnvDefault 'QBIT_PASS' (New-Secret)
if ($env:DATA_DIR) { Set-EnvValue 'DATA_DIR' $env:DATA_DIR }
$hn = $env:COMPUTERNAME.ToLower()
$hosts = "localhost:3000,127.0.0.1:3000,${hn}:3000"
if ($lan -ne 'localhost') { $hosts += ",${lan}:3000" }
Set-EnvValue 'HOMEPAGE_ALLOWED_HOSTS' $hosts

$data = if ($env:DATA_DIR) { $env:DATA_DIR } else { Join-Path $PSScriptRoot 'data' }
Log "Creating folders under $data"
foreach ($d in @("$data\torrents", "$data\media\tv", "$data\media\movies")) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}
foreach ($c in @('prowlarr', 'sonarr', 'radarr', 'qbittorrent', 'plex', 'seerr', 'homepage')) {
  New-Item -ItemType Directory -Force -Path "config\$c" | Out-Null
}

# ---------- 5. Start the stack ----------
Log 'Pulling images and starting containers'
docker compose pull
if ($LASTEXITCODE -ne 0) { Die 'docker compose pull failed' }
docker compose up -d
if ($LASTEXITCODE -ne 0) { Die 'docker compose up failed' }

# ---------- 6. Wire the apps together ----------
Log 'Wiring the apps together (this waits for each app''s first start, can take a few minutes)'
$temp = ''
for ($i = 0; $i -lt 30; $i++) {
  $logs = cmd /c "docker logs qbittorrent 2>&1"
  $hit = $logs | Select-String -Pattern 'temporary password' | Select-Object -Last 1
  if ($hit -and ($hit.Line -match ':\s*(\S+)\s*$')) { $temp = $Matches[1]; break }
  Start-Sleep -Seconds 2
}
$runArgs = @(
  'run', '--rm', '--network', $Network,
  '-e', "HOST_ADDR=$lan",
  '-e', "QBIT_USER=$(Get-EnvValue 'QBIT_USER')",
  '-e', "QBIT_PASS=$(Get-EnvValue 'QBIT_PASS')",
  '-e', "QBIT_TEMP_PASS=$temp",
  '-v', "${PSScriptRoot}:/work",
  'python:3-alpine', 'python', '/work/wire.py'
)
& docker @runArgs
if ($LASTEXITCODE -ne 0) { Warn 'Wiring reported problems (see above). Fix arr-config.json if needed and re-run this script.' }

# ---------- 7. Report ----------
Start-Sleep -Seconds 3

Write-Host ''
'{0,-14} {1,-16} {2,-30} {3}' -f 'SERVICE', 'CONTAINER IP', 'FROM HOST / LAN', 'INTERNAL (between containers)'
'{0,-14} {1,-16} {2,-30} {3}' -f '-------', '------------', '---------------', '-----------------------------'
foreach ($s in $Services) {
  $ip = (docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $s.Name 2>$null)
  if (-not $ip) { $ip = 'n/a' }
  '{0,-14} {1,-16} {2,-30} {3}' -f $s.Name, $ip, ("http://{0}:{1}" -f $lan, $s.Port), ("http://{0}:{1}" -f $s.Name, $s.Port)
}

Write-Host ''
Write-Host "Host address: $lan   (also reachable as http://localhost:<port>)"
Write-Host 'Container IPs live inside Docker Desktop''s VM and are NOT reachable from Windows. Use localhost or the host address.'
Write-Host ''
Write-Host "Dashboard: http://${lan}:3000   (links to everything above)"
Write-Host 'Re-run this script any time: it skips what already exists. Private tracker logins go in arr-config.json.'
Write-Host ''
Warn 'Windows folders mounted into containers are slower, and hardlinks and SQLite databases can be unreliable there.'
Warn 'For best results, run setup.sh inside a WSL Ubuntu distro with Docker Desktop WSL integration, with this folder under ~/arr-stack.'
Warn 'To reach the apps from other devices, allow the ports through Windows Firewall when prompted.'
