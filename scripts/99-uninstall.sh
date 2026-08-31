#!/usr/bin/env bash
# 99-uninstall.sh -- reverse 10-40. Leaves BOOKS_DIR and its contents alone
# unless --purge-books is given.

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

print_usage() { cat <<'USAGE'
usage: 99-uninstall.sh [--dry-run] [--purge-books] [--yes]

Stops and removes copyparty and the mDNS alias, clears the Tailscale funnel,
and deletes the service user. Your books are kept unless --purge-books.
Tailscale itself is left installed.
USAGE
}

PURGE_BOOKS=0; ASSUME_YES=0
parse_common_flags "$@"
for a in "${REMAINING_ARGS[@]:-}"; do
  case "$a" in
    --purge-books) PURGE_BOOKS=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    "") ;;
    *) die "unknown argument: $a" ;;
  esac
done

load_env
require_sudo

if [ "$ASSUME_YES" = "0" ] && [ "$DRY_RUN" = "0" ]; then
  printf 'This removes copyparty, the %s.local alias and the funnel.\n' "$LIBRARY_ALIAS"
  [ "$PURGE_BOOKS" = "1" ] && printf '%sIt will also DELETE %s%s\n' "$C_RED" "$BOOKS_DIR" "$C_RESET"
  printf 'Continue? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) die "aborted" ;; esac
fi

step "Tailscale funnel"
if have tailscale; then
  run $SUDO tailscale funnel reset || true
  ok "funnel configuration cleared"
else
  info "tailscale not installed - nothing to clear"
fi

step "copyparty"
run $SUDO systemctl disable --now copyparty 2>/dev/null || true
run $SUDO rm -f /etc/systemd/system/copyparty.service /etc/copyparty.conf /usr/local/bin/copyparty-sfx.py
ok "removed service, config and binary"

step "mDNS alias"
run $SUDO systemctl disable --now "avahi-alias@${LIBRARY_ALIAS}.service" 2>/dev/null || true
run $SUDO rm -f /etc/systemd/system/avahi-alias@.service /usr/local/lib/avahi-alias.sh
ok "removed alias unit and wrapper"

run $SUDO systemctl daemon-reload

step "Data"
if [ "$PURGE_BOOKS" = "1" ]; then
  run $SUDO rm -rf "$BOOKS_DIR"
  ok "deleted $BOOKS_DIR"
else
  info "kept $BOOKS_DIR"
fi
run $SUDO rm -rf /var/lib/copyparty
ok "removed /var/lib/copyparty (index + thumbs)"

step "Service user"
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
  run $SUDO userdel "$SERVICE_USER" || warn "could not delete user $SERVICE_USER"
  ok "removed user $SERVICE_USER"
else
  info "user $SERVICE_USER does not exist"
fi

echo
printf '%s==> uninstalled%s\n' "$C_GRN" "$C_RESET"
hint "zram, avahi-utils and tailscale were left installed on purpose"
