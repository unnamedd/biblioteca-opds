#!/usr/bin/env bash
# install.sh -- run the whole thing. Execute this ON THE PI.
#
#   ./install.sh              full install
#   ./install.sh --dry-run    print what would happen, change nothing
#
# Every step is idempotent, so re-running after a failure is safe.

. "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/common.sh"

print_usage() { cat <<'USAGE'
usage: ./install.sh [--dry-run] [--no-ban]

Runs, in order:
  scripts/00-preflight.sh    check every assumption
  scripts/10-system.sh       packages, zram, service user, /srv/books
  scripts/20-mdns.sh         publish <alias>.local
  scripts/30-copyparty.sh    OPDS + upload server under systemd
  scripts/40-tailscale.sh    Funnel (interactive on first run; TAILSCALE_ENABLED)
  scripts/45-cloudflare.sh   short address on your domain (CLOUDFLARE_ENABLED)

Then run scripts/50-verify.sh separately.
USAGE
}

PASS_THROUGH=()
parse_common_flags "$@"
for a in "${REMAINING_ARGS[@]:-}"; do
  case "$a" in
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
info "remote  : tailscale=$([ "$TAILSCALE_ENABLED" = 1 ] && echo on || echo off)  cloudflare=$([ "$CLOUDFLARE_ENABLED" = 1 ] && echo "on (${PUBLIC_HOSTNAME})" || echo off)"
[ "$DRY_RUN" = "1" ] && warn "DRY RUN - nothing will be changed"

bash "$REPO_ROOT/scripts/00-preflight.sh"  "${DRY_FLAG[@]}"
bash "$REPO_ROOT/scripts/10-system.sh"     "${DRY_FLAG[@]}"
bash "$REPO_ROOT/scripts/20-mdns.sh"       "${DRY_FLAG[@]}"
bash "$REPO_ROOT/scripts/30-copyparty.sh"  "${DRY_FLAG[@]}" "${PASS_THROUGH[@]:-}"

# each of these no-ops when its toggle in library.env is 0
bash "$REPO_ROOT/scripts/40-tailscale.sh"  "${DRY_FLAG[@]}"
bash "$REPO_ROOT/scripts/45-cloudflare.sh" "${DRY_FLAG[@]}"

echo
printf '%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_GRN" "$C_RESET"
printf '%s║  done - now run:  ./scripts/50-verify.sh                 ║%s\n' "$C_GRN" "$C_RESET"
printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$C_GRN" "$C_RESET"
