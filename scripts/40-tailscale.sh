#!/usr/bin/env bash
# 40-tailscale.sh -- install Tailscale and publish copyparty over Funnel.
#
# Funnel (not Serve) because the reader is an ESP32-C3 and cannot join the
# tailnet, and a phone does not route hotspot-tethered clients through its
# own VPN tunnel. Funnel gives a publicly-trusted Let's Encrypt cert, which the
# firmware requires: it verifies HTTPS against the bundled CA roots.
#
# This step is interactive the first time (browser login + admin approval).

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

print_usage() { cat <<'USAGE'
usage: 40-tailscale.sh [--dry-run] [--reset]

  --reset   clear the existing funnel configuration before re-applying
USAGE
}

RESET=0
parse_common_flags "$@"
for a in "${REMAINING_ARGS[@]:-}"; do
  case "$a" in
    --reset) RESET=1 ;;
    "") ;;
    *) die "unknown argument: $a" ;;
  esac
done

load_env
require_sudo

# --- install -----------------------------------------------------------------
step "Tailscale"

if have tailscale; then
  ok "already installed: $(tailscale version | head -1)"
else
  info "installing via https://tailscale.com/install.sh"
  hint "on Raspbian bullseye armhf this selects pkgs.tailscale.com/stable/raspbian/bullseye"
  run_sh "curl -fsSL https://tailscale.com/install.sh | sh"
  have tailscale || die "tailscale install failed"
  ok "installed"
fi

run $SUDO systemctl enable --now tailscaled

# --- login -------------------------------------------------------------------
step "Tailnet membership"

backend_state() {
  $SUDO tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("BackendState",""))
except Exception: print("")' 2>/dev/null
}

if [ "$DRY_RUN" = "1" ]; then
  info "[dry-run] would run: $SUDO tailscale up"
elif [ "$(backend_state)" = "Running" ]; then
  ok "already logged in as $(tailnet_hostname)"
else
  warn "not logged in - this opens a browser login URL"
  $SUDO tailscale up
  [ "$(backend_state)" = "Running" ] || die "tailscale up did not complete"
  ok "logged in as $(tailnet_hostname)"
fi

# --- funnel ------------------------------------------------------------------
step "Funnel"

if [ "$RESET" = "1" ]; then
  run $SUDO tailscale funnel reset
  ok "cleared previous funnel configuration"
fi

if [ "$DRY_RUN" = "1" ]; then
  info "[dry-run] would run: $SUDO tailscale funnel --bg ${SERVER_PORT}"
else
  info "MagicDNS + HTTPS certificates must be enabled for the tailnet."
  info "The CLI provisions the cert and adds the 'funnel' node attribute;"
  info "approve any prompt it prints."
  echo
  # --bg persists: it resumes after reboot and after `tailscale down/up`,
  # so no extra systemd unit is needed for this.
  $SUDO tailscale funnel --bg "${SERVER_PORT}"
  echo
  $SUDO tailscale funnel status | sed 's/^/    /'
fi

# --- report ------------------------------------------------------------------
TS_HOST="$(tailnet_hostname || true)"
echo
if [ -n "${TS_HOST:-}" ]; then
  printf '%s==> away URL: https://%s/books/?opds%s\n' "$C_GRN" "$TS_HOST" "$C_RESET"
else
  printf '%s==> funnel configured%s\n' "$C_GRN" "$C_RESET"
fi
hint "Funnel is limited to ports 443, 8443 and 10000, and a port cannot be"
hint "Serve (private) and Funnel (public) at the same time."
