#!/usr/bin/env bash
# install.sh -- run the whole thing. Execute this ON THE PI.
#
#   ./install.sh              full install
#   ./install.sh --dry-run    print what would happen, change nothing
#   ./install.sh --skip-tailscale
#
# Every step is idempotent, so re-running after a failure is safe.

. "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/common.sh"

print_usage() { cat <<'USAGE'
usage: ./install.sh [--dry-run] [--skip-tailscale] [--no-ban]

Runs, in order:
  scripts/00-preflight.sh    check every assumption
  scripts/10-system.sh       packages, zram, service user, /srv/books
  scripts/20-mdns.sh         publish <alias>.local
  scripts/30-copyparty.sh    OPDS + upload server under systemd
  scripts/40-tailscale.sh    Funnel (interactive on first run)

Then run scripts/50-verify.sh separately.
USAGE
}

SKIP_TS=0; PASS_THROUGH=()
parse_common_flags "$@"
for a in "${REMAINING_ARGS[@]:-}"; do
  case "$a" in
    --skip-tailscale) SKIP_TS=1 ;;
    --no-ban) PASS_THROUGH+=(--no-ban) ;;
    "") ;;
    *) die "unknown argument: $a" ;;
  esac
done

load_env

if [ ! -f "$ENV_FILE" ]; then
  warn "no library.env found - using defaults from library.env.example"
  hint "cp library.env.example library.env  to customise the name/account"
fi

DRY_FLAG=()
[ "$DRY_RUN" = "1" ] && DRY_FLAG=(--dry-run)

printf '\n%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_RESET"
printf '%s║  Biblioteca installer                                    ║%s\n' "$C_BOLD" "$C_RESET"
printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$C_BOLD" "$C_RESET"
info "alias   : ${SERVER_HOSTNAME}.local"
info "account : ${MANAGER_ACCOUNT}"
info "port    : ${SERVER_PORT}"
info "books   : ${BOOKS_DIR}"
[ "$DRY_RUN" = "1" ] && warn "DRY RUN - nothing will be changed"

bash "$REPO_ROOT/scripts/00-preflight.sh"  "${DRY_FLAG[@]}"
bash "$REPO_ROOT/scripts/10-system.sh"     "${DRY_FLAG[@]}"
bash "$REPO_ROOT/scripts/20-mdns.sh"       "${DRY_FLAG[@]}"
bash "$REPO_ROOT/scripts/30-copyparty.sh"  "${DRY_FLAG[@]}" "${PASS_THROUGH[@]:-}"

if [ "$SKIP_TS" = "1" ]; then
  step "Tailscale"
  info "skipped (--skip-tailscale). The LAN URL works; remote access does not."
else
  bash "$REPO_ROOT/scripts/40-tailscale.sh" "${DRY_FLAG[@]}"
fi

echo
printf '%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_GRN" "$C_RESET"
printf '%s║  done - now run:  ./scripts/50-verify.sh                 ║%s\n' "$C_GRN" "$C_RESET"
printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$C_GRN" "$C_RESET"
