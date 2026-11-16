#!/usr/bin/env bash
# One-click setup for the arr stack: installs the container runtime (macOS: OrbStack,
# Linux: Docker Engine, WSL: checks Docker Desktop), starts everything, wires the apps
# together through their APIs (wire.py), and generates the Homepage dashboard.
# Windows (PowerShell) users: run setup.ps1 instead.
# Needs, next to this script: docker-compose.yml, wire.py, arr-config.json
#
# Usage:  chmod +x setup.sh && ./setup.sh
# Optional env vars:
#   DISABLE_SLEEP=1   keep the machine from sleeping (asks for sudo)
#   DATA_DIR=/path    where torrents/media live (default: ./data next to this script)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NETWORK="arr-net"
SERVICES=(homepage seerr plex sonarr radarr prowlarr qbittorrent flaresolverr)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

for f in docker-compose.yml wire.py arr-config.json; do
  [[ -f "$f" ]] || die "$f not found next to setup.sh"
done

# ---------- OS detection ----------
detect_os() {
  case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then OS="wsl"; else OS="linux"; fi ;;
    MINGW*|MSYS*|CYGWIN*)
      die "Native Windows shell detected. Run setup.ps1 from PowerShell instead." ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
  log "Detected OS: $OS ($(uname -m))"
}

# Docker command wrapper (becomes 'sudo docker' on Linux if the group change isn't active yet)
DOCKER=(docker)
docker_ready() { command -v docker >/dev/null 2>&1 && "${DOCKER[@]}" info >/dev/null 2>&1; }

# ---------- macOS: OrbStack ----------
install_mac() {
  export PATH="$HOME/.orbstack/bin:/Applications/OrbStack.app/Contents/MacOS/xbin:/opt/homebrew/bin:/usr/local/bin:$PATH"

  if [[ -d /Applications/OrbStack.app ]]; then
    log "OrbStack already installed"
  elif command -v brew >/dev/null 2>&1; then
    log "Installing OrbStack via Homebrew"
    brew install --cask orbstack
  else
    log "Homebrew not found, downloading OrbStack directly"
    local url tmp
    if [[ "$(uname -m)" == "arm64" ]]; then
      url="https://orbstack.dev/download/stable/latest/arm64"
    else
      url="https://orbstack.dev/download/stable/latest/amd64"
    fi
    tmp="$(mktemp -d)"
    curl -fL "$url" -o "$tmp/OrbStack.dmg"
    hdiutil attach "$tmp/OrbStack.dmg" -nobrowse -quiet -mountpoint "$tmp/mnt"
    cp -R "$tmp/mnt/OrbStack.app" /Applications/
    hdiutil detach "$tmp/mnt" -quiet
    rm -rf "$tmp"
  fi

  log "Starting OrbStack"
  open -a OrbStack
  log "Waiting for the Docker engine (first launch may ask you to approve setup prompts)"
  local i
  for i in $(seq 1 90); do
    docker_ready && break
    sleep 2
  done
  docker_ready || die "Docker engine did not start. Open OrbStack once manually, finish its setup, then re-run."

  log "Configuring OrbStack"
  docker context use orbstack >/dev/null 2>&1 || true
  if command -v orbctl >/dev/null 2>&1; then
    orbctl config set app.start_at_login true >/dev/null 2>&1 \
      || warn "Could not enable start-at-login (set it in OrbStack settings)"
  fi
  if [[ "${DISABLE_SLEEP:-0}" == "1" ]]; then
    log "Disabling system sleep while on power (sudo required)"
    sudo pmset -c sleep 0 || warn "pmset failed"
  fi
}

# ---------- Linux: Docker Engine ----------
install_linux() {
  if docker_ready && "${DOCKER[@]}" compose version >/dev/null 2>&1; then
    log "Docker Engine and compose plugin already installed"
  else
    command -v curl >/dev/null 2>&1 || die "curl is required. Install it with your package manager and re-run."
    log "Installing Docker Engine via get.docker.com (sudo required)"
    curl -fsSL https://get.docker.com | sudo sh
    log "Enabling and starting the Docker service"
    sudo systemctl enable --now docker || warn "Could not enable the docker service via systemctl"
  fi

  # Let the current user run docker without sudo (takes effect on next login)
  if ! id -nG "$USER" | grep -qw docker; then
    log "Adding $USER to the docker group (applies after you log out and back in)"
    sudo usermod -aG docker "$USER" || warn "Could not add $USER to the docker group"
  fi

  # Group change isn't active in this shell yet, so fall back to sudo if needed
  if ! docker_ready; then
    DOCKER=(sudo docker)
    warn "Using 'sudo docker' for this run"
  fi
  docker_ready || die "Docker is installed but not responding. Check: sudo systemctl status docker"
  "${DOCKER[@]}" compose version >/dev/null 2>&1 \
    || die "Docker compose plugin missing. Install 'docker-compose-plugin' with your package manager."

  if [[ "${DISABLE_SLEEP:-0}" == "1" ]]; then
    log "Disabling suspend/hibernate (sudo required)"
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target \
      || warn "Could not mask sleep targets"
  fi
}

# ---------- WSL: needs Docker Desktop with WSL integration ----------
check_wsl() {
  if docker_ready && docker compose version >/dev/null 2>&1; then
    log "Docker is available inside WSL (Docker Desktop integration)"
  else
    die "Docker not reachable from WSL. Install Docker Desktop on Windows (run setup.ps1 from PowerShell), then enable Settings > Resources > WSL integration for this distro, and re-run."
  fi
  warn "Keep this folder inside the WSL filesystem (e.g. ~/arr-stack), not /mnt/c, so hardlinks and databases work properly."
}

# ---------- shared: .env, folders, stack ----------
detect_timezone() {
  local tz=""
  if [[ "$OS" == "mac" ]]; then
    tz="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)"
  else
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)"
  fi
  echo "${tz:-UTC}"
}

env_get() { [[ -f .env ]] && grep -m1 "^$1=" .env | cut -d= -f2- || true; }

# env_set KEY VALUE  (replace if present, else append)
env_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  { [[ -f .env ]] && grep -v "^${key}=" .env || true; } > "$tmp"
  echo "${key}=${value}" >> "$tmp"
  cat "$tmp" > .env
  rm -f "$tmp"
}

# Set only if missing
env_default() { [[ -n "$(env_get "$1")" ]] || env_set "$1" "$2"; }

random_secret() { head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

write_env() {
  log "Updating .env (IDs, timezone, qBittorrent login, dashboard hosts)"
  touch .env
  env_default PUID "$(id -u)"
  env_default PGID "$(id -g)"
  env_default TZ "$(detect_timezone)"
  env_default QBIT_USER admin
  env_default QBIT_PASS "$(random_secret)"
  [[ -n "${DATA_DIR:-}" ]] && env_set DATA_DIR "$DATA_DIR"

  # Homepage only answers to hosts it is told about; refresh each run (IP may change)
  local lan hosts hn
  lan="$(host_ip)"
  hn="$(hostname | tr '[:upper:]' '[:lower:]')"
  hosts="localhost:3000,127.0.0.1:3000,${hn}:3000,${hn%%.*}.local:3000"
  [[ "$lan" != "unknown" && "$lan" != "localhost" ]] && hosts="${hosts},${lan}:3000"
  env_set HOMEPAGE_ALLOWED_HOSTS "$hosts"
}

prepare_folders() {
  local data="${DATA_DIR:-$SCRIPT_DIR/data}"
  log "Creating folders under $data"
  mkdir -p "$data/torrents" "$data/media/tv" "$data/media/movies"
  mkdir -p config/{prowlarr,sonarr,radarr,qbittorrent,plex,seerr,homepage}
  # Seerr runs as UID/GID 1000 inside its container
  if [[ "$OS" != "mac" && "$(id -u)" != "1000" ]]; then
    sudo chown -R 1000:1000 config/seerr || warn "Could not chown config/seerr to 1000:1000 (Seerr may fail to start)"
  fi
}

start_stack() {
  log "Pulling images and starting containers"
  "${DOCKER[@]}" compose pull
  "${DOCKER[@]}" compose up -d
}

# ---------- wire the apps together (qBittorrent, Sonarr, Radarr, Prowlarr, Homepage) ----------
qbit_temp_password() {
  local i pw=""
  for i in $(seq 1 30); do
    pw="$("${DOCKER[@]}" logs qbittorrent 2>&1 | grep -i 'temporary password' | tail -n1 | sed 's/.*: *//' | tr -d '\r' || true)"
    [[ -n "$pw" ]] && break
    sleep 2
  done
  echo "$pw"
}

wire_stack() {
  log "Wiring the apps together (this waits for each app's first start, can take a few minutes)"
  local temp
  temp="$(qbit_temp_password)"
  "${DOCKER[@]}" run --rm \
    --network arr-net \
    --user "$(id -u):$(id -g)" \
    -e HOST_ADDR="$(host_ip)" \
    -e QBIT_USER="$(env_get QBIT_USER)" \
    -e QBIT_PASS="$(env_get QBIT_PASS)" \
    -e QBIT_TEMP_PASS="$temp" \
    -v "$SCRIPT_DIR":/work \
    python:3-alpine python /work/wire.py \
    || warn "Wiring reported problems (see above). You can fix arr-config.json and re-run this script."
}

# ---------- report ----------
port_for() {
  case "$1" in
    homepage) echo 3000 ;;
    seerr) echo 5055 ;;
    prowlarr) echo 9696 ;;
    sonarr) echo 8989 ;;
    radarr) echo 7878 ;;
    qbittorrent) echo 8080 ;;
    flaresolverr) echo 8191 ;;
    plex) echo 32400 ;;
  esac
}

container_ip() {
  "${DOCKER[@]}" inspect -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{.IPAddress}}{{end}}" "$1" 2>/dev/null || true
}

host_ip() {
  local ip=""
  case "$OS" in
    mac)   ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)" ;;
    linux) ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
           [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)" ;;
    wsl)   ip="localhost" ;;
  esac
  echo "${ip:-unknown}"
}

report() {
  local lan name port ip
  lan="$(host_ip)"
  sleep 5

  echo
  printf '%-14s %-16s %-30s %s\n' "SERVICE" "CONTAINER IP" "FROM HOST / LAN" "INTERNAL (between containers)"
  printf '%-14s %-16s %-30s %s\n' "-------" "------------" "---------------" "-----------------------------"
  for name in "${SERVICES[@]}"; do
    port="$(port_for "$name")"
    ip="$(container_ip "$name")"
    printf '%-14s %-16s %-30s %s\n' "$name" "${ip:-n/a}" "http://$lan:$port" "http://$name:$port"
  done

  echo
  echo "Host address: $lan"
  case "$OS" in
    mac)   echo "OrbStack also gives each container a hostname, e.g. http://prowlarr.orb.local:9696" ;;
    linux) echo "Container IPs are reachable directly from this machine on the Docker bridge." ;;
    wsl)   echo "Under WSL, use localhost from Windows. Container IPs are inside Docker Desktop's VM." ;;
  esac
  echo
  echo "Dashboard: http://$lan:3000   (links to everything above)"
  echo "Re-run this script any time: it skips what already exists. Private tracker logins go in arr-config.json."
  if [[ "$OS" == "linux" ]] && [[ "${DOCKER[0]}" == "sudo" ]]; then
    echo
    warn "Log out and back in so you can run 'docker' without sudo."
  fi
}

detect_os
case "$OS" in
  mac)   install_mac ;;
  linux) install_linux ;;
  wsl)   check_wsl ;;
esac
prepare_folders
write_env
start_stack
wire_stack
report
