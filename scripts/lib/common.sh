#!/usr/bin/env bash
# Shared helpers for the Biblioteca scripts.
# Sourced, never executed directly.

# --- strict mode -------------------------------------------------------------
set -euo pipefail

# --- paths -------------------------------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
ENV_FILE="$REPO_ROOT/library.env"

# --- output ------------------------------------------------------------------
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_BLU" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
hint() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# --- dry run -----------------------------------------------------------------
# Every mutating command goes through run(). With --dry-run we print instead.
DRY_RUN="${DRY_RUN:-0}"

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"
  else
    "$@"
  fi
}

# run_sh: for pipelines / redirection that run() cannot express as argv.
run_sh() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    %s[dry-run]%s sh -c %q\n' "$C_DIM" "$C_RESET" "$1"
  else
    sh -c "$1"
  fi
}

parse_common_flags() {
  REMAINING_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -h|--help) print_usage; exit 0 ;;
      *) REMAINING_ARGS+=("$1") ;;
    esac
    shift
  done
}

# --- privilege ---------------------------------------------------------------
# Scripts are written to work both as root and as a normal user with sudo.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

require_sudo() {
  [ -z "$SUDO" ] && return 0
  command -v sudo >/dev/null 2>&1 || die "sudo not found and not running as root"
  sudo -n true 2>/dev/null || {
    info "this script needs sudo; you may be prompted for your password"
    sudo -v || die "sudo authentication failed"
  }
}

# --- config ------------------------------------------------------------------
# Defaults; library.env overrides them.
LIBRARY_ALIAS="${LIBRARY_ALIAS:-biblioteca}"
COPYPARTY_ACCOUNT="${COPYPARTY_ACCOUNT:-reader}"
COPYPARTY_PASSWORD="${COPYPARTY_PASSWORD:-}"
COPYPARTY_PORT="${COPYPARTY_PORT:-80}"
BOOKS_DIR="${BOOKS_DIR:-/srv/books}"
SERVICE_USER="${SERVICE_USER:-copyparty}"
ENABLE_ZRAM="${ENABLE_ZRAM:-1}"
BAN_PW="${BAN_PW:-1}"
ENABLE_COVERS="${ENABLE_COVERS:-0}"
GUEST_ACCOUNT="${GUEST_ACCOUNT:-}"
GUEST_PASSWORD="${GUEST_PASSWORD:-}"

load_env() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
  fi
  # re-apply defaults for anything the env file left empty
  LIBRARY_ALIAS="${LIBRARY_ALIAS:-biblioteca}"
  COPYPARTY_ACCOUNT="${COPYPARTY_ACCOUNT:-reader}"
  COPYPARTY_PORT="${COPYPARTY_PORT:-80}"
  BOOKS_DIR="${BOOKS_DIR:-/srv/books}"
  SERVICE_USER="${SERVICE_USER:-copyparty}"
  ENABLE_ZRAM="${ENABLE_ZRAM:-1}"
  ENABLE_COVERS="${ENABLE_COVERS:-0}"
  GUEST_ACCOUNT="${GUEST_ACCOUNT:-}"
  GUEST_PASSWORD="${GUEST_PASSWORD:-}"
  BAN_PW="${BAN_PW:-1}"
}

# Persist a key=value into library.env (creating it, 0600).
save_env() {
  local key="$1" val="$2"
  if [ "$DRY_RUN" = "1" ]; then
    printf '    %s[dry-run]%s save %s to %s\n' "$C_DIM" "$C_RESET" "$key" "$ENV_FILE"
    return 0
  fi
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # portable in-place edit (no GNU sed -i assumptions)
    local tmp; tmp="$(mktemp)"
    grep -vE "^${key}=" "$ENV_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
}

# --- small utilities ---------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# guarded so these are simply false on a machine without systemd
unit_active()  { have systemctl && systemctl is-active  --quiet "$1" 2>/dev/null; }
unit_enabled() { have systemctl && systemctl is-enabled --quiet "$1" 2>/dev/null; }

# The primary IPv4 the kernel would use for outbound traffic.
primary_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i+1); exit } }'
}

# The base URL a LAN client uses, honouring a non-default port.
lan_url() {
  if [ "$COPYPARTY_PORT" = "80" ]; then
    printf 'http://%s.local' "$LIBRARY_ALIAS"
  else
    printf 'http://%s.local:%s' "$LIBRARY_ALIAS" "$COPYPARTY_PORT"
  fi
}

tailnet_hostname() {
  have tailscale || return 1
  $SUDO tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    n = (d.get("Self") or {}).get("DNSName") or ""
    print(n.rstrip("."))
except Exception:
    pass' 2>/dev/null
}
