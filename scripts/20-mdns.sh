#!/usr/bin/env bash
# 20-mdns.sh -- publish <LIBRARY_ALIAS>.local beside the Pi's real hostname.
#
# This adds a second mDNS A record; it does NOT rename the machine. The
# wrapper resolves the current primary IPv4 at start, so a reboot onto a new
# DHCP lease still publishes the right address.

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

print_usage() { cat <<'USAGE'
usage: 20-mdns.sh [--dry-run]

Installs /usr/local/lib/avahi-alias.sh and avahi-alias@.service, then enables
avahi-alias@$LIBRARY_ALIAS so http://$LIBRARY_ALIAS.local resolves on the LAN.
USAGE
}

parse_common_flags "$@"
load_env
require_sudo

UNIT="avahi-alias@${LIBRARY_ALIAS}.service"

step "mDNS alias: ${LIBRARY_ALIAS}.local"

have avahi-publish || die "avahi-publish not found - run 10-system.sh first"

if ! unit_active avahi-daemon; then
  warn "avahi-daemon is not running; enabling it"
  run $SUDO systemctl enable --now avahi-daemon
fi

# --- wrapper -----------------------------------------------------------------
if cmp -s "$CONFIG_DIR/avahi-alias.sh" /usr/local/lib/avahi-alias.sh 2>/dev/null; then
  ok "/usr/local/lib/avahi-alias.sh already current"
else
  run $SUDO install -D -m 0755 "$CONFIG_DIR/avahi-alias.sh" /usr/local/lib/avahi-alias.sh
  ok "installed /usr/local/lib/avahi-alias.sh"
fi

# --- unit --------------------------------------------------------------------
NEED_RELOAD=0
if cmp -s "$CONFIG_DIR/avahi-alias@.service" /etc/systemd/system/avahi-alias@.service 2>/dev/null; then
  ok "avahi-alias@.service already current"
else
  run $SUDO install -m 0644 "$CONFIG_DIR/avahi-alias@.service" /etc/systemd/system/avahi-alias@.service
  NEED_RELOAD=1
  ok "installed avahi-alias@.service"
fi

[ "$NEED_RELOAD" = "1" ] && run $SUDO systemctl daemon-reload

run $SUDO systemctl enable "$UNIT"
run $SUDO systemctl restart "$UNIT"

# --- verify ------------------------------------------------------------------
if [ "$DRY_RUN" != "1" ]; then
  sleep 2
  if unit_active "$UNIT"; then
    ok "$UNIT is active"
  else
    $SUDO systemctl status "$UNIT" --no-pager -l | sed 's/^/    /' || true
    die "$UNIT failed to start"
  fi

  if getent hosts "${LIBRARY_ALIAS}.local" >/dev/null 2>&1; then
    ok "resolves locally: $(getent hosts "${LIBRARY_ALIAS}.local" | head -1)"
  else
    warn "${LIBRARY_ALIAS}.local does not resolve on the Pi itself yet"
    hint "this is often just propagation; 50-verify.sh retries"
  fi
fi

echo
printf '%s==> mDNS alias published: %s.local -> %s%s\n' \
  "$C_GRN" "$LIBRARY_ALIAS" "$(primary_ipv4 || echo '?')" "$C_RESET"
