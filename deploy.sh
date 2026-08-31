#!/usr/bin/env bash
# deploy.sh -- run this ON THE MAC. Copies the repo to the Pi and installs.
#
#   ./deploy.sh                    uses PI_SSH from library.env
#   ./deploy.sh pi@raspberrypi.local
#   ./deploy.sh pi@raspberrypi.local --dry-run
#
# Uses rsync over ssh; library.env travels with it (it holds the password),
# which is why it is gitignored rather than absent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_ROOT/library.env"

C_BOLD=$'\033[1m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RESET=$'\033[0m'

# macOS still ships bash 3.2, so keep this array-free.
TARGET=""; EXTRA_ARGS=""
for a in "$@"; do
  case "$a" in
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) EXTRA_ARGS="$EXTRA_ARGS $a" ;;
    *)   TARGET="$a" ;;
  esac
done

if [ -z "$TARGET" ] && [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  TARGET="$(. "$ENV_FILE"; printf '%s' "${PI_SSH:-}")"
fi

[ -n "$TARGET" ] || {
  echo "error: no target. Pass one (pi@raspberrypi.local) or set PI_SSH in library.env" >&2
  exit 1
}

REMOTE_DIR="${REMOTE_DIR:-biblioteca}"

printf '%s==>%s syncing to %s:%s\n' "$C_BOLD" "$C_RESET" "$TARGET" "$REMOTE_DIR"
rsync -az --delete \
  --exclude '.git' --exclude '.DS_Store' \
  "$REPO_ROOT/" "$TARGET:$REMOTE_DIR/"

printf '%s==>%s running installer on the Pi\n' "$C_BOLD" "$C_RESET"
# -t so sudo prompts and the tailscale login URL are visible and interactive
ssh -t "$TARGET" "cd '$REMOTE_DIR' && ./install.sh$EXTRA_ARGS" || {
  printf '%sinstall failed - ssh in and re-run ./install.sh to see more%s\n' "$C_YEL" "$C_RESET" >&2
  exit 1
}

printf '\n%s==>%s pulling library.env back (it may now hold a generated password)\n' "$C_BOLD" "$C_RESET"
rsync -az "$TARGET:$REMOTE_DIR/library.env" "$REPO_ROOT/library.env" 2>/dev/null || true

printf '%s==> deployed. Next:  ssh %s "cd %s && ./scripts/50-verify.sh"%s\n' \
  "$C_GRN" "$TARGET" "$REMOTE_DIR" "$C_RESET"
