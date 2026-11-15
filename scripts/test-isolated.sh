#!/usr/bin/env bash
# Smoke-test the core apps in a throwaway Compose project.
# Publishes on 127.0.0.1 only, uses a temp directory, and does not start Gluetun.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not available to this user." >&2
  exit 1
fi

snap=$(mktemp)
docker ps -aq --no-trunc | sort > "$snap"
: > "$snap.state"
while read -r id; do
  [ -n "$id" ] || continue
  docker inspect -f '{{.Id}} {{.State.Status}} {{.State.StartedAt}}' "$id" >> "$snap.state"
done < "$snap"

tmp=$(mktemp -d /tmp/jfboot-test.XXXXXX)
envfile=$tmp/test.env
mkdir -p \
  "$tmp/config/jellyfin" \
  "$tmp/config/radarr" \
  "$tmp/config/sonarr" \
  "$tmp/config/bazarr" \
  "$tmp/config/seerr" \
  "$tmp/media/movies" \
  "$tmp/media/series" \
  "$tmp/media/downloads"

cat > "$envfile" <<EOF
PUID=$(id -u)
PGID=$(id -g)
TZ=UTC
CONFIG_ROOT=$tmp/config
MEDIA_ROOT=$tmp/media
BIND_ADDRESS=127.0.0.1
JELLYFIN_PORT=18096
RADARR_PORT=17878
SONARR_PORT=18989
BAZARR_PORT=16767
SEERR_PORT=15055
QBITTORRENT_PORT=18090
PROWLARR_PORT=19696
QBITTORRENT_USERNAME=isolated-test
QBITTORRENT_PASSWORD=isolated-test-password
WIREGUARD_PRIVATE_KEY=
VPN_SERVER_COUNTRIES=United States
EOF
chmod 600 "$envfile"

compose() {
  docker compose --env-file "$envfile" -p jfboot-test "$@"
}

cleanup_ran=0
finish() {
  local rc=$?
  trap - EXIT
  if [ "$cleanup_ran" = 0 ]; then
    cleanup_ran=1
    echo "Stopping the test project"
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$tmp"
  fi
  echo "Checking containers that were already running"
  local changed=0 id now before
  while read -r id; do
    [ -n "$id" ] || continue
    if ! now=$(docker inspect -f '{{.Id}} {{.State.Status}} {{.State.StartedAt}}' "$id" 2>/dev/null); then
      echo "Container $id disappeared during the test" >&2
      changed=1
      continue
    fi
    before=$(grep -F "$id" "$snap.state" || true)
    if [ "$now" != "$before" ]; then
      echo "Container changed: before [$before] after [$now]" >&2
      changed=1
    fi
  done < "$snap"
  rm -f "$snap" "$snap.state"
  if [ "$changed" != 0 ]; then
    exit 1
  fi
  echo "Existing containers are unchanged"
  exit "$rc"
}
trap finish EXIT

echo "Rendering the VPN profile without starting it"
compose --profile vpn config > "$tmp/rendered.yml"
if grep -q '/home/kmiyahara/media' "$tmp/rendered.yml"; then
  echo "Rendered config points at the live media folder." >&2
  exit 1
fi
if grep -q 'media-stack' "$tmp/rendered.yml"; then
  echo "Rendered config points at the live stack." >&2
  exit 1
fi

echo "Starting the core profile in project jfboot-test"
compose up -d

services=$(compose ps -a --format '{{.Service}}' | sort)
expected=$(printf '%s\n' bazarr jellyfin radarr seerr sonarr)
if [ "$services" != "$expected" ]; then
  echo "Unexpected services running:" >&2
  echo "$services" >&2
  exit 1
fi

python3 - "$tmp" <<'PY'
import json, subprocess, sys
tmp = sys.argv[1]
raw = subprocess.check_output([
    "docker", "ps", "-q",
    "--filter", "label=com.docker.compose.project=jfboot-test",
], text=True).split()
if not raw:
    sys.exit("no jfboot-test containers")
wanted = {"18096", "17878", "18989", "16767", "15055"}
loopback = {"127.0.0.1", "::1"}
seen = []
for cid in raw:
    ports = json.loads(subprocess.check_output(
        ["docker", "inspect", "-f", "{{json .NetworkSettings.Ports}}", cid], text=True))
    for bindings in (ports or {}).values():
        for item in bindings or []:
            seen.append((item.get("HostIp"), item.get("HostPort")))
hosts_ports = {port for _, port in seen}
if hosts_ports != wanted:
    sys.exit(f"published host ports {sorted(hosts_ports)} != {sorted(wanted)}")
bad = [item for item in seen if item[0] not in loopback]
if bad:
    sys.exit(f"ports are not limited to loopback: {bad}")
print("published ports are on 127.0.0.1 only")
PY

wait_http() {
  local name=$1 service=$2 url=$3
  local code
  for _ in $(seq 1 90); do
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$url" || true)
    case "$code" in
      200|301|302|307|308) echo "$name is up ($code)"; return 0 ;;
    esac
    sleep 2
  done
  echo "$name did not answer at $url (last HTTP $code)" >&2
  compose logs --tail 40 "$service" >&2 || true
  return 1
}

wait_http Jellyfin jellyfin "http://127.0.0.1:18096/health"
wait_http Sonarr sonarr "http://127.0.0.1:18989/ping"
wait_http Radarr radarr "http://127.0.0.1:17878/ping"
wait_http Bazarr bazarr "http://127.0.0.1:16767/"
wait_http Seerr seerr "http://127.0.0.1:15055/"

health=$(curl -s -m 5 "http://127.0.0.1:18096/health" | tr -d '[:space:]' || true)
if [ "$health" != "Healthy" ]; then
  echo "Jellyfin /health returned: $health" >&2
  exit 1
fi
echo "Jellyfin health check returned Healthy"
echo "Isolated checks passed"
