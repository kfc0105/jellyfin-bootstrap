#!/usr/bin/env bash
# Remove the stack this bootstrap started, plus the config, media, and .env it created.
# The scripts in this folder stay. Docker images stay.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

YES=0
INCLUDE_EXTERNAL=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    --include-external) INCLUDE_EXTERNAL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "Usage: ./teardown.sh [--yes] [--dry-run] [--include-external]"
      echo "Deletes this Compose project, its config directory, its media directory, and .env."
      echo "Paths outside this folder are kept unless you pass --include-external."
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose is not available, so the containers cannot be removed." >&2
  exit 1
fi

dotenv() {
  local line val
  [ -f .env ] || return 0
  line=$(grep -E "^$1=" .env | tail -1 || true)
  val=${line#*=}
  val=${val%$'\r'}
  if [ "${val#\"}" != "$val" ] && [ "${val%\"}" != "$val" ]; then
    val=${val#\"}
    val=${val%\"}
  fi
  printf '%s' "$val"
}

abspath() {
  realpath -m "$1"
}

CONFIG_ROOT=$(dotenv CONFIG_ROOT)
MEDIA_ROOT=$(dotenv MEDIA_ROOT)
CONFIG_ROOT=${CONFIG_ROOT:-$ROOT/config}
MEDIA_ROOT=${MEDIA_ROOT:-$ROOT/media}
CONFIG_ROOT=$(abspath "$CONFIG_ROOT")
MEDIA_ROOT=$(abspath "$MEDIA_ROOT")
ENV_FILE="$ROOT/.env"

assert_deletable() {
  local path=$1 label=$2
  local protected home_real
  home_real=$(abspath "$HOME")
  if [ "$path" = "/" ] || [ "$path" = "$home_real" ] || [ "$path" = "$ROOT" ]; then
    echo "Refusing to delete $label ($path)." >&2
    exit 1
  fi
  for protected in \
    /home/kmiyahara/media \
    /home/kmiyahara/media-stack \
    /etc /usr /var /opt /bin /sbin /lib /lib64
  do
    protected=$(abspath "$protected")
    if [ "$path" = "$protected" ] || [[ "$path" == "$protected"/* ]]; then
      echo "Refusing to delete $label ($path). That path is outside this bootstrap." >&2
      exit 1
    fi
  done
  if [[ "$path" != "$ROOT"/* ]]; then
    if [ "$INCLUDE_EXTERNAL" != 1 ]; then
      echo "$label is outside this folder: $path" >&2
      echo "Re-run with --include-external if you really want that directory removed." >&2
      exit 1
    fi
  fi
}

assert_deletable "$CONFIG_ROOT" "CONFIG_ROOT"
assert_deletable "$MEDIA_ROOT" "MEDIA_ROOT"

echo "This will permanently delete the stack created from $ROOT:"
echo "  - its containers, network, and anonymous volumes"
echo "  - $CONFIG_ROOT"
echo "  - $MEDIA_ROOT"
echo "  - $ENV_FILE"
echo "The scripts in this folder stay. Docker images stay."

if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run only. Nothing was deleted."
  exit 0
fi

if [ "$YES" != 1 ]; then
  printf 'Type "delete" to continue: '
  read -r answer
  if [ "$answer" != "delete" ]; then
    echo "Left everything in place."
    exit 1
  fi
fi

echo "Stopping containers"
docker compose --profile vpn down -v --remove-orphans

remove_path() {
  local path=$1
  if [ ! -e "$path" ]; then
    echo "Already gone: $path"
    return 0
  fi
  if rm -rf -- "$path"; then
    echo "Removed $path"
    return 0
  fi
  echo "Could not remove $path. Some files may be owned by root." >&2
  echo "Remove them with: sudo rm -rf -- $(printf '%q' "$path")" >&2
  return 1
}

rc=0
remove_path "$CONFIG_ROOT" || rc=1
remove_path "$MEDIA_ROOT" || rc=1
remove_path "$ENV_FILE" || rc=1

if [ "$rc" != 0 ]; then
  exit "$rc"
fi

echo "Teardown finished. Run ./bootstrap.sh to start over."
