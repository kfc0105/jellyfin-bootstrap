#!/usr/bin/env bash
# Create folders, write .env, and start the stack.
# Re-running is safe. A WireGuard key turns on the VPN profile.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

if [ -f "$ROOT/MEMORY.md" ] && [ -d "$ROOT/config/prowlarr/Definitions" ]; then
  echo "This folder looks like an already-configured media stack. Run this from a fresh jellyfin-bootstrap copy." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "Docker is not available to this user." >&2
  echo "Install Docker Engine and the Compose plugin, then add your user to the docker group and log in again." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "The Docker Compose plugin is missing. Install the docker-compose-plugin package." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  echo "python3 and openssl are required." >&2
  exit 1
fi

dotenv() {
  local line val
  line=$(grep -E "^$1=" .env | tail -1 || true)
  val=${line#*=}
  val=${val%$'\r'}
  if [ "${val#\"}" != "$val" ] && [ "${val%\"}" != "$val" ]; then
    val=${val#\"}
    val=${val%\"}
  fi
  printf '%s' "$val"
}

detect_tz() {
  local tz=""
  if [ -r /etc/timezone ]; then
    tz=$(tr -d '[:space:]' < /etc/timezone)
  fi
  if [ -z "$tz" ] && command -v timedatectl >/dev/null 2>&1; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  fi
  if [ -z "$tz" ]; then
    tz=UTC
  fi
  printf '%s' "$tz"
}

if [ ! -f .env ]; then
  echo "Creating .env"
  cp .env.example .env
  password=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)
  python3 - "$password" "$(id -u)" "$(id -g)" "$(detect_tz)" "$ROOT" <<'PY'
import pathlib, sys
password, puid, pgid, tz, root = sys.argv[1:]
path = pathlib.Path(".env")
repl = {
    "PUID": puid,
    "PGID": pgid,
    "TZ": tz,
    "CONFIG_ROOT": f"{root}/config",
    "MEDIA_ROOT": f"{root}/media",
    "QBITTORRENT_PASSWORD": password,
}
lines = []
for line in path.read_text().splitlines():
    if line.startswith("#") or "=" not in line:
        lines.append(line)
        continue
    key, value = line.split("=", 1)
    if key in repl:
        lines.append(f'{key}={repl[key]}')
    else:
        lines.append(line)
path.write_text("\n".join(lines) + "\n")
PY
  echo "Generated a qBittorrent password and saved it in .env"
else
  echo "Using the existing .env"
fi
chmod 600 .env

mkdir -p \
  "$(dotenv CONFIG_ROOT)/jellyfin" \
  "$(dotenv CONFIG_ROOT)/radarr" \
  "$(dotenv CONFIG_ROOT)/sonarr" \
  "$(dotenv CONFIG_ROOT)/bazarr" \
  "$(dotenv CONFIG_ROOT)/seerr" \
  "$(dotenv CONFIG_ROOT)/vpn" \
  "$(dotenv CONFIG_ROOT)/prowlarr" \
  "$(dotenv CONFIG_ROOT)/qbittorrent" \
  "$(dotenv MEDIA_ROOT)/movies" \
  "$(dotenv MEDIA_ROOT)/series" \
  "$(dotenv MEDIA_ROOT)/downloads"

key=$(dotenv WIREGUARD_PRIVATE_KEY)
vpn=0
if [ -n "$key" ] && [ "$key" != "replace-me" ]; then
  vpn=1
fi

port_conflict() {
  local port=$1 id wd
  local ids
  ids=$(docker ps -q --filter "publish=$port")
  if [ -n "$ids" ]; then
    for id in $ids; do
      wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id")
      if [ "$wd" != "$ROOT" ]; then
        return 0
      fi
    done
    return 1
  fi
  if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
    return 0
  fi
  return 1
}

check_port() {
  local name=$1 port=$2
  if port_conflict "$port"; then
    echo "$name port $port is already in use by something else." >&2
    echo "Stop that program, or change the port in .env, then run ./bootstrap.sh again." >&2
    exit 1
  fi
}

check_port Jellyfin "$(dotenv JELLYFIN_PORT)"
check_port Radarr "$(dotenv RADARR_PORT)"
check_port Sonarr "$(dotenv SONARR_PORT)"
check_port Bazarr "$(dotenv BAZARR_PORT)"
check_port Seerr "$(dotenv SEERR_PORT)"
if [ "$vpn" = 1 ]; then
  check_port qBittorrent "$(dotenv QBITTORRENT_PORT)"
  check_port Prowlarr "$(dotenv PROWLARR_PORT)"
fi

if [ "$vpn" = 1 ]; then
  echo "Starting Jellyfin, the library apps, and the VPN profile"
  docker compose --profile vpn up -d
else
  echo "No WireGuard key in .env yet."
  echo "Starting Jellyfin, Sonarr, Radarr, Bazarr, and Seerr."
  echo "qBittorrent and Prowlarr stay off until you add WIREGUARD_PRIVATE_KEY and run ./bootstrap.sh again."
  docker compose up -d
fi

bind=$(dotenv BIND_ADDRESS)
host_for_url=$bind
if [ "$bind" = "0.0.0.0" ] || [ -z "$bind" ]; then
  host_for_url=$(hostname -I 2>/dev/null | awk '{print $1}')
  host_for_url=${host_for_url:-127.0.0.1}
fi

echo
echo "Open these in a browser:"
echo "  Jellyfin   http://${host_for_url}:$(dotenv JELLYFIN_PORT)"
echo "  Sonarr     http://${host_for_url}:$(dotenv SONARR_PORT)"
echo "  Radarr     http://${host_for_url}:$(dotenv RADARR_PORT)"
echo "  Bazarr     http://${host_for_url}:$(dotenv BAZARR_PORT)"
echo "  Seerr      http://${host_for_url}:$(dotenv SEERR_PORT)"
if [ "$vpn" = 1 ]; then
  echo "  qBittorrent http://${host_for_url}:$(dotenv QBITTORRENT_PORT)"
  echo "  Prowlarr   http://${host_for_url}:$(dotenv PROWLARR_PORT)"
  echo
  echo "qBittorrent username: $(dotenv QBITTORRENT_USERNAME)"
  echo "qBittorrent password: $(dotenv QBITTORRENT_PASSWORD)"
  echo "The same password is stored in .env."
  echo
  echo "When the tunnel is up, connect the apps with:"
  echo "  ./scripts/wire-apps.sh"
else
  echo
  echo "Next: paste your Proton WireGuard private key into WIREGUARD_PRIVATE_KEY in .env"
  echo "and run ./bootstrap.sh again. Steps are in README.md."
fi
