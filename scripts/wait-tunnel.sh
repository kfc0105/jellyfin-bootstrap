#!/bin/sh
# Runs inside the qBittorrent container, which shares Gluetun's network namespace.
# Holds the app until tun0 has an IPv4 address, then starts the image's real init.
echo "wait-tunnel: waiting for an IPv4 address on tun0"
n=0
while ! ip -4 -o addr show dev tun0 2>/dev/null | grep -q inet; do
  n=$((n + 1))
  if [ "$n" -ge 180 ]; then
    echo "wait-tunnel: tun0 had no IPv4 address after 180s" >&2
    exit 1
  fi
  sleep 1
done
echo "wait-tunnel: tun0 is up"
exec /init "$@"
