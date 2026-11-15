#!/usr/bin/env bash
# Point Prowlarr at Sonarr and Radarr, and add qBittorrent as their download client.
# Does not add indexers. Safe to run again after a settings change.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [ ! -f .env ]; then
  echo "Missing .env. Run ./bootstrap.sh first." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to talk to the app APIs." >&2
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

BIND_ADDRESS=$(dotenv BIND_ADDRESS)
SONARR_PORT=$(dotenv SONARR_PORT)
RADARR_PORT=$(dotenv RADARR_PORT)
PROWLARR_PORT=$(dotenv PROWLARR_PORT)
QBITTORRENT_PORT=$(dotenv QBITTORRENT_PORT)
QBITTORRENT_USERNAME=$(dotenv QBITTORRENT_USERNAME)
QBITTORRENT_PASSWORD=$(dotenv QBITTORRENT_PASSWORD)
CONFIG_ROOT=$(dotenv CONFIG_ROOT)

if [ "$BIND_ADDRESS" = "0.0.0.0" ] || [ -z "$BIND_ADDRESS" ]; then
  CURL_HOST=127.0.0.1
else
  CURL_HOST=$BIND_ADDRESS
fi

if [ -z "$QBITTORRENT_USERNAME" ] || [ -z "$QBITTORRENT_PASSWORD" ] || [ "$QBITTORRENT_PASSWORD" = "replace-me" ]; then
  echo "Set QBITTORRENT_USERNAME and QBITTORRENT_PASSWORD in .env, then recreate qBittorrent:" >&2
  echo "  docker compose --profile vpn up -d qbittorrent" >&2
  exit 1
fi

echo "Waiting for config files and the VPN web UIs"
ready=0
for _ in $(seq 1 60); do
  if [ -f "$CONFIG_ROOT/sonarr/config.xml" ] \
    && [ -f "$CONFIG_ROOT/radarr/config.xml" ] \
    && [ -f "$CONFIG_ROOT/prowlarr/config.xml" ] \
    && curl -sf -m 5 -o /dev/null "http://${CURL_HOST}:${PROWLARR_PORT}/ping" \
    && curl -sf -m 5 -o /dev/null "http://${CURL_HOST}:${SONARR_PORT}/ping" \
    && curl -sf -m 5 -o /dev/null "http://${CURL_HOST}:${RADARR_PORT}/ping"; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" != 1 ]; then
  echo "Sonarr, Radarr, or Prowlarr is not ready." >&2
  echo "Prowlarr starts only after the VPN is up. Set WIREGUARD_PRIVATE_KEY and run ./bootstrap.sh, then try again." >&2
  exit 1
fi

apikey() {
  sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "$CONFIG_ROOT/$1/config.xml" | head -1
}

echo "Checking qBittorrent login"
jar=$(mktemp)
trap 'rm -f "$jar"' EXIT
code=$(curl -s -m 15 -c "$jar" -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode "username=${QBITTORRENT_USERNAME}" \
  --data-urlencode "password=${QBITTORRENT_PASSWORD}" \
  "http://${CURL_HOST}:${QBITTORRENT_PORT}/api/v2/auth/login")
if [ "$code" != "200" ]; then
  echo "qBittorrent login failed (HTTP $code)." >&2
  echo "The WebUI stays down until the tunnel has an address. Check: docker compose --profile vpn logs gluetun" >&2
  echo "A password change applies after: docker compose --profile vpn up -d qbittorrent" >&2
  exit 1
fi
echo "qBittorrent login ok ($(curl -s -m 5 -b "$jar" "http://${CURL_HOST}:${QBITTORRENT_PORT}/api/v2/app/version"))"
rm -f "$jar"
trap - EXIT

export SONARR_KEY=$(apikey sonarr)
export RADARR_KEY=$(apikey radarr)
export PROWLARR_KEY=$(apikey prowlarr)
export CURL_HOST SONARR_PORT RADARR_PORT PROWLARR_PORT
export QBITTORRENT_PORT QBITTORRENT_USERNAME QBITTORRENT_PASSWORD

python3 <<'PY'
import json, os, sys, urllib.error, urllib.request

host = os.environ["CURL_HOST"]
prowlarr = f"http://{host}:{os.environ['PROWLARR_PORT']}"
# Host ports can change. Inside the compose network the listen ports stay fixed,
# except qBittorrent, whose listen port is QBITTORRENT_PORT on purpose.
apps = {
    "Sonarr": {
        "port": os.environ["SONARR_PORT"],
        "base": "http://sonarr:8989",
        "key": os.environ["SONARR_KEY"],
        "category_field": "tvCategory",
        "category": "sonarr",
    },
    "Radarr": {
        "port": os.environ["RADARR_PORT"],
        "base": "http://radarr:7878",
        "key": os.environ["RADARR_KEY"],
        "category_field": "movieCategory",
        "category": "radarr",
    },
}

def request(method, url, key, body=None, timeout=30):
    data = None if body is None else json.dumps(body).encode()
    headers = {"X-Api-Key": key}
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:400]
        sys.exit(f"{method} {url} failed (HTTP {exc.code}): {detail}")

def set_field(fields, name, value):
    for field in fields:
        if field.get("name") == name:
            field["value"] = value
            return
    sys.exit(f"schema is missing field {name}")

print("Registering Sonarr and Radarr in Prowlarr")
schema = request("GET", f"{prowlarr}/api/v1/applications/schema", os.environ["PROWLARR_KEY"])[1]
existing = request("GET", f"{prowlarr}/api/v1/applications", os.environ["PROWLARR_KEY"])[1]
by_impl = {item.get("implementation"): item for item in existing}
for impl, info in apps.items():
    tmpl = next(item for item in schema if item.get("implementation") == impl)
    fields = tmpl["fields"]
    set_field(fields, "prowlarrUrl", "http://gluetun:9696")
    set_field(fields, "baseUrl", info["base"])
    set_field(fields, "apiKey", info["key"])
    body = {
        "name": impl,
        "implementation": impl,
        "configContract": tmpl["configContract"],
        "syncLevel": "fullSync",
        "fields": fields,
    }
    current = by_impl.get(impl)
    if current:
        body["id"] = current["id"]
        request("PUT", f"{prowlarr}/api/v1/applications/{current['id']}", os.environ["PROWLARR_KEY"], body)
        action = "updated"
    else:
        created = request("POST", f"{prowlarr}/api/v1/applications", os.environ["PROWLARR_KEY"], body)[1]
        body["id"] = created["id"]
        action = "added"
    request("POST", f"{prowlarr}/api/v1/applications/test", os.environ["PROWLARR_KEY"], body)
    print(f"  {impl}: {action}, connection test passed ({info['base']})")

print("Adding qBittorrent to Sonarr and Radarr")
for impl, info in apps.items():
    base = f"http://{host}:{info['port']}"
    key = info["key"]
    schemas = request("GET", f"{base}/api/v3/downloadclient/schema", key)[1]
    tmpl = next(item for item in schemas if item.get("implementation") == "QBittorrent")
    want = {
        "host": "gluetun",
        "port": int(os.environ["QBITTORRENT_PORT"]),
        "useSsl": False,
        "username": os.environ["QBITTORRENT_USERNAME"],
        "password": os.environ["QBITTORRENT_PASSWORD"],
        info["category_field"]: info["category"],
    }
    for field in tmpl["fields"]:
        if field["name"] in want:
            field["value"] = want[field["name"]]
    body = {
        "name": "qBittorrent",
        "implementation": "QBittorrent",
        "configContract": tmpl["configContract"],
        "enable": True,
        "protocol": "torrent",
        "priority": 1,
        "fields": tmpl["fields"],
        "tags": [],
    }
    clients = request("GET", f"{base}/api/v3/downloadclient", key)[1]
    current = next((item for item in clients if item.get("implementation") == "QBittorrent"), None)
    if current:
        body["id"] = current["id"]
        request("PUT", f"{base}/api/v3/downloadclient/{current['id']}", key, body)
        action = "updated"
    else:
        request("POST", f"{base}/api/v3/downloadclient", key, body)
        action = "added"
    request("POST", f"{base}/api/v3/downloadclient/test", key, body, timeout=40)
    print(f"  {impl}: {action}, connection test passed (gluetun:{os.environ['QBITTORRENT_PORT']})")

print("Done. Indexers are still yours to add in Prowlarr.")
print("Completed downloads are shared at /downloads in qBittorrent, Sonarr, and Radarr.")
PY
