#!/usr/bin/env bash
# 00-preflight.sh -- check every assumption before anything is installed.
# Exits non-zero on a hard failure so install.sh stops before it half-installs.

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

print_usage() { cat <<'USAGE'
usage: 00-preflight.sh [--dry-run]

Verifies the Pi can host the library: architecture, python3, sudo, free RAM,
a free listen port, avahi, curl and systemd. Changes nothing.
USAGE
}

parse_common_flags "$@"
load_env

FAILURES=0
fail() { warn "$*"; FAILURES=$((FAILURES + 1)); }

step "Preflight checks"

# --- OS ----------------------------------------------------------------------
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  ok "os: ${PRETTY_NAME:-unknown}"
  case "${ID:-}:${ID_LIKE:-}" in
    *debian*|debian*|raspbian*) : ;;
    *) warn "not a Debian-family OS; apt steps will not work" ;;
  esac
else
  fail "no /etc/os-release - is this Linux? (run this on the Pi, not the Mac)"
fi

# --- architecture ------------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  armv6l|armv7l|aarch64|x86_64)
    ok "arch: $ARCH"
    if [ "$ARCH" = "armv6l" ] || [ "$ARCH" = "armv7l" ]; then
      hint "32-bit userland: Node 22 / Bun are unavailable, which is why this"
      hint "stack is pure-Python copyparty rather than a JS server."
    fi
    ;;
  *) fail "unexpected architecture: $ARCH" ;;
esac

# --- systemd -----------------------------------------------------------------
if have systemctl && [ -d /run/systemd/system ]; then
  ok "systemd: present"
else
  fail "systemd not running - the boot/restart requirement needs it"
fi

# --- python3 -----------------------------------------------------------------
if have python3; then
  ok "python3: $(python3 --version 2>&1)"
else
  fail "python3 not found (apt install python3)"
fi

# --- curl --------------------------------------------------------------------
have curl && ok "curl: present" || fail "curl not found (apt install curl)"

# --- sudo --------------------------------------------------------------------
if [ -z "$SUDO" ]; then
  ok "privileges: running as root"
elif have sudo; then
  ok "privileges: sudo available"
else
  fail "not root and sudo not found"
fi

# --- memory ------------------------------------------------------------------
if [ -r /proc/meminfo ]; then
  MEM_TOTAL_MB=$(awk '/^MemTotal:/  {print int($2/1024)}' /proc/meminfo)
  MEM_AVAIL_MB=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
  if [ "${MEM_AVAIL_MB:-0}" -ge 150 ]; then
    ok "memory: ${MEM_AVAIL_MB} MB available of ${MEM_TOTAL_MB} MB"
  else
    fail "only ${MEM_AVAIL_MB} MB available; want >= 150 MB free before installing"
  fi
else
  warn "cannot read /proc/meminfo - skipping memory check"
fi

# --- disk --------------------------------------------------------------------
DISK_PARENT="$(dirname "$BOOKS_DIR")"
[ -d "$DISK_PARENT" ] || DISK_PARENT=/
DISK_FREE_MB=$(df -Pm "$DISK_PARENT" 2>/dev/null | awk 'NR==2 {print $4}')
if [ "${DISK_FREE_MB:-0}" -ge 500 ]; then
  ok "disk: ${DISK_FREE_MB} MB free on $DISK_PARENT"
else
  warn "only ${DISK_FREE_MB:-?} MB free on $DISK_PARENT - fine to start, but books need room"
fi

# --- listen port -------------------------------------------------------------
if have ss; then
  PORT_LINE="$($SUDO ss -ltnpH "sport = :${SERVER_PORT}" 2>/dev/null | head -1 || true)"
  if [ -z "$PORT_LINE" ]; then
    ok "port ${SERVER_PORT}: free"
  elif printf '%s' "$PORT_LINE" | grep -q 'copyparty\|python3'; then
    ok "port ${SERVER_PORT}: already held by copyparty (re-run is fine)"
  else
    fail "port ${SERVER_PORT} is in use by something else:"
    printf '        %s\n' "$PORT_LINE" >&2
    hint "either stop it, or set SERVER_PORT=3923 in library.env"
  fi
else
  warn "ss not found - cannot check whether port ${SERVER_PORT} is free"
fi

# --- avahi -------------------------------------------------------------------
if unit_active avahi-daemon; then
  ok "avahi-daemon: running (needed for ${SERVER_HOSTNAME}.local)"
elif have systemctl; then
  warn "avahi-daemon not running; 10-system.sh will install avahi-utils but the"
  warn "daemon itself must be present for the .local name to work"
fi

# --- network -----------------------------------------------------------------
IP="$(primary_ipv4 || true)"
if [ -n "${IP:-}" ]; then
  ok "primary IPv4: $IP"
else
  fail "could not determine a primary IPv4 address"
fi

# --- verdict -----------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
  printf '%s==> preflight passed%s\n' "$C_GRN" "$C_RESET"
  exit 0
fi
printf '%s==> preflight failed (%d problem(s))%s\n' "$C_RED" "$FAILURES" "$C_RESET"
exit 1
