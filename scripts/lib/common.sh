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
SERVER_HOSTNAME="${SERVER_HOSTNAME:-biblioteca}"
MANAGER_ACCOUNT="${MANAGER_ACCOUNT:-reader}"
MANAGER_PASSWORD="${MANAGER_PASSWORD:-}"
SERVER_PORT="${SERVER_PORT:-80}"
BOOKS_DIR="${BOOKS_DIR:-/srv/books}"
SERVICE_USER="${SERVICE_USER:-copyparty}"
ENABLE_ZRAM="${ENABLE_ZRAM:-1}"
BAN_PW="${BAN_PW:-1}"
ENABLE_COVERS="${ENABLE_COVERS:-0}"
GUEST_ACCOUNT="${GUEST_ACCOUNT:-}"
GUEST_PASSWORD="${GUEST_PASSWORD:-}"

# Identity and URL layout. All of this is meant to be changed: two people
# running this project should not share a URL layout, so that a stock install
# is not guessable.
LIBRARY_TITLE="${LIBRARY_TITLE:-Biblioteca}"
BOOKS_ENDPOINT="${BOOKS_ENDPOINT:-books}"
MANAGER_ENDPOINT="${MANAGER_ENDPOINT:-manager}"
LANDING_DIR="${LANDING_DIR:-/srv/landing}"
# An always-empty directory backing /<MANAGER_ENDPOINT>/. It exists so that
# door lists its two children (books, wallpapers) instead of 403-ing, and it
# is mounted read-only so a mistyped upload cannot land in it.
MANAGER_ROOT_DIR="${MANAGER_ROOT_DIR:-/var/lib/copyparty/manager-root}"
# the reader itself opens epub/xtc/xtch/txt; the rest are for phones+computers
BOOKS_EXTS="${BOOKS_EXTS:-epub,xtc,xtch,txt,pdf,md,cbz,cbr,azw3,mobi,fb2}"

# Sleep-screen images, kept out of the book catalogue entirely.
WALLPAPERS_ENABLED="${WALLPAPERS_ENABLED:-1}"
WALLPAPERS_ENDPOINT="${WALLPAPERS_ENDPOINT:-wallpapers}"
WALLPAPERS_DIR="${WALLPAPERS_DIR:-/srv/wallpapers}"
# bmp and pxc are what the device can actually open; png is stored but not listed
WALLPAPERS_EXTS="${WALLPAPERS_EXTS:-bmp,pxc}"

# Remote access. Either, both, or neither entrance can be on; with both off
# the server is reachable on the LAN only and nothing is installed for it.
TAILSCALE_ENABLED="${TAILSCALE_ENABLED:-1}"
CLOUDFLARE_ENABLED="${CLOUDFLARE_ENABLED:-0}"
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-}"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"

load_env() {
  if [ -f "$ENV_FILE" ]; then
    # library.env is sourced as shell, so an unquoted value containing a space
    # or an apostrophe is a syntax error (or worse, silently empty). Catch it
    # here with a message that says what to do.
    if ! bash -n "$ENV_FILE" 2>/dev/null; then
      die "$ENV_FILE has a syntax error. Values with spaces or apostrophes must be quoted, e.g. LIBRARY_TITLE=\"Your Name's Shelf\""
    fi
    # bash -n accepts KEY=two words as valid syntax (it parses as an env-prefixed
    # command), so the value silently vanishes. Catch unquoted spaces explicitly.
    _bad="$(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^"'"'"'][^#]*[[:space:]][^#]*$' "$ENV_FILE" 2>/dev/null || true)"
    if [ -n "$_bad" ]; then
      printf '%s\n' "$_bad" | sed 's/^/    /' >&2
      die "$ENV_FILE: the value(s) above contain spaces but are not quoted; write LIBRARY_TITLE=\"Your Name's Shelf\""
    fi
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
  fi
  # re-apply defaults for anything the env file left empty
  SERVER_HOSTNAME="${SERVER_HOSTNAME:-biblioteca}"
  MANAGER_ACCOUNT="${MANAGER_ACCOUNT:-reader}"
  SERVER_PORT="${SERVER_PORT:-80}"
  BOOKS_DIR="${BOOKS_DIR:-/srv/books}"
  SERVICE_USER="${SERVICE_USER:-copyparty}"
  ENABLE_ZRAM="${ENABLE_ZRAM:-1}"
  ENABLE_COVERS="${ENABLE_COVERS:-0}"
  GUEST_ACCOUNT="${GUEST_ACCOUNT:-}"
  GUEST_PASSWORD="${GUEST_PASSWORD:-}"
  BAN_PW="${BAN_PW:-1}"
  LIBRARY_TITLE="${LIBRARY_TITLE:-Biblioteca}"
  BOOKS_ENDPOINT="${BOOKS_ENDPOINT:-books}"
  MANAGER_ENDPOINT="${MANAGER_ENDPOINT:-manager}"
  LANDING_DIR="${LANDING_DIR:-/srv/landing}"
  MANAGER_ROOT_DIR="${MANAGER_ROOT_DIR:-/var/lib/copyparty/manager-root}"
  BOOKS_EXTS="${BOOKS_EXTS:-epub,xtc,xtch,txt,pdf,md,cbz,cbr,azw3,mobi,fb2}"
  WALLPAPERS_ENABLED="${WALLPAPERS_ENABLED:-1}"
  WALLPAPERS_ENDPOINT="${WALLPAPERS_ENDPOINT:-wallpapers}"
  WALLPAPERS_DIR="${WALLPAPERS_DIR:-/srv/wallpapers}"
  WALLPAPERS_EXTS="${WALLPAPERS_EXTS:-bmp,pxc}"
  TAILSCALE_ENABLED="${TAILSCALE_ENABLED:-1}"
  CLOUDFLARE_ENABLED="${CLOUDFLARE_ENABLED:-0}"
  WALLPAPERS_ENDPOINT="$(trim_path "$WALLPAPERS_ENDPOINT")"
  # tolerate "/books", "books/" or "/books/" in library.env
  BOOKS_ENDPOINT="$(trim_path "$BOOKS_ENDPOINT")"
  MANAGER_ENDPOINT="$(trim_path "$MANAGER_ENDPOINT")"
  [ -n "$BOOKS_ENDPOINT" ]   || die "BOOKS_ENDPOINT must not be empty"
  [ -n "$MANAGER_ENDPOINT" ] || die "MANAGER_ENDPOINT must not be empty"
  [ "$BOOKS_ENDPOINT" != "$MANAGER_ENDPOINT" ] || die "BOOKS_ENDPOINT and MANAGER_ENDPOINT must differ"
  [ -n "$LIBRARY_TITLE" ] || die "LIBRARY_TITLE is empty — if it contains spaces, quote it: LIBRARY_TITLE=\"My Library\""
  if [ "$WALLPAPERS_ENABLED" = "1" ]; then
    [ -n "$WALLPAPERS_ENDPOINT" ] || die "WALLPAPERS_ENDPOINT must not be empty"
    for _e in "$BOOKS_ENDPOINT" "$MANAGER_ENDPOINT"; do
      [ "$WALLPAPERS_ENDPOINT" != "$_e" ] || die "WALLPAPERS_ENDPOINT must differ from $_e"
    done
  fi
  if [ "$CLOUDFLARE_ENABLED" = "1" ]; then
    [ -n "$PUBLIC_HOSTNAME" ] || die "CLOUDFLARE_ENABLED=1 but PUBLIC_HOSTNAME is empty (e.g. your-shelf.example.com)"
    [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ] || die "CLOUDFLARE_ENABLED=1 but CLOUDFLARE_TUNNEL_TOKEN is empty — Zero Trust -> Networks -> Tunnels -> your tunnel"
    # tolerate a pasted URL
    PUBLIC_HOSTNAME="$(printf '%s' "$PUBLIC_HOSTNAME" | sed -e 's|^https\{0,1\}://||' -e 's|/.*$||')"
    # Cloudflare's free wildcard certificate covers one label below the
    # registered domain; deeper names get no certificate at all
    case "$PUBLIC_HOSTNAME" in
      *.*.*.*) warn "PUBLIC_HOSTNAME has several labels; the free wildcard cert may not cover it (use x.<domain>)" ;;
    esac
  fi
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
    printf '%s=\"%s\"\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
  else
    printf '%s=\"%s\"\n' "$key" "$val" >> "$ENV_FILE"
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
  if [ "$SERVER_PORT" = "80" ]; then
    printf 'http://%s.local' "$SERVER_HOSTNAME"
  else
    printf 'http://%s.local:%s' "$SERVER_HOSTNAME" "$SERVER_PORT"
  fi
}

# strip surrounding slashes so "/books/", "books/" and "books" all work
trim_path() { printf '%s' "$1" | sed -e 's|^/*||' -e 's|/*$||'; }

# The three doors, as URLs a human can paste.
books_url()    { printf '%s/%s/' "$(lan_url)" "$BOOKS_ENDPOINT"; }
opds_url()     { printf '%s/%s/?opds' "$(lan_url)" "$BOOKS_ENDPOINT"; }
manager_url()       { printf '%s/%s/' "$(lan_url)" "$MANAGER_ENDPOINT"; }
manager_books_url() { printf '%s/%s/books/' "$(lan_url)" "$MANAGER_ENDPOINT"; }
wallpapers_url()      { printf '%s/%s/' "$(lan_url)" "$WALLPAPERS_ENDPOINT"; }
wallpapers_opds_url() { printf '%s/%s/?opds' "$(lan_url)" "$WALLPAPERS_ENDPOINT"; }
wallpapers_mgr_url()  { printf '%s/%s/wallpapers/' "$(lan_url)" "$MANAGER_ENDPOINT"; }

# The short public address, when Cloudflare Tunnel is on.
public_url() { printf 'https://%s' "$PUBLIC_HOSTNAME"; }

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
