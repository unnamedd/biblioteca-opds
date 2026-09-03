#!/usr/bin/env bash
# 45-cloudflare.sh -- publish copyparty at a short name on your own domain
# through a Cloudflare Tunnel.
#
# Why a tunnel and not a CNAME to the Funnel name: Funnel's certificate is
# only valid for *.ts.net, so any other hostname fails the TLS handshake.
# Cloudflare terminates TLS at its edge with a WILDCARD certificate for your
# domain -- which also means the subdomain never appears in Certificate
# Transparency logs, unlike the Funnel name -- and cloudflared holds an
# outbound-only connection from the Pi, so no port is opened.
#
# Trade-off, stated plainly: Cloudflare sees the traffic in the clear,
# passwords included. Funnel does not. Either, both, or neither can be on.
#
# One manual step, once, in the Cloudflare Zero Trust dashboard:
#   Networks -> Tunnels -> Create a tunnel (Cloudflared) -> copy the token
#   into library.env as CLOUDFLARE_TUNNEL_TOKEN -> Public Hostname:
#   <PUBLIC_HOSTNAME>  ->  Service: http://localhost:<SERVER_PORT>
# Cloudflare creates the DNS record itself. The tunnel's config lives at
# Cloudflare, so re-running this with the same token after a rebuild simply
# reattaches the same tunnel.
#
# Skipped entirely when CLOUDFLARE_ENABLED=0.

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

print_usage() { cat <<'USAGE'
usage: 45-cloudflare.sh [--dry-run] [--update]

  --update   re-download cloudflared even if it is already installed
USAGE
}

UPDATE=0
parse_common_flags "$@"
for a in "${REMAINING_ARGS[@]:-}"; do
  case "$a" in
    --update) UPDATE=1 ;;
    "") ;;
    *) die "unknown argument: $a" ;;
  esac
done

load_env

if [ "$CLOUDFLARE_ENABLED" != "1" ]; then
  step "Cloudflare Tunnel"
  info "skipped (CLOUDFLARE_ENABLED=0). Set PUBLIC_HOSTNAME and CLOUDFLARE_TUNNEL_TOKEN"
  info "in library.env and flip it to 1 for a short address on your own domain."
  exit 0
fi

require_sudo

# --- install -----------------------------------------------------------------
step "cloudflared"

case "$(uname -m)" in
  armv6l|armv7l) ASSET=armhf ;;   # 32-bit Raspberry Pi OS
  aarch64|arm64) ASSET=arm64 ;;   # Linux says aarch64, macOS says arm64
  x86_64)        ASSET=amd64 ;;
  *) die "no cloudflared build for $(uname -m)" ;;
esac
DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ASSET}.deb"

if have cloudflared && [ "$UPDATE" = "0" ]; then
  ok "already installed: $(cloudflared --version 2>/dev/null | head -1)"
else
  info "downloading $DEB_URL"
  run_sh "$SUDO curl -fsSL -o /tmp/cloudflared.deb '$DEB_URL'"
  run $SUDO dpkg -i /tmp/cloudflared.deb
  run $SUDO rm -f /tmp/cloudflared.deb
  [ "$DRY_RUN" = "1" ] || have cloudflared || die "cloudflared install failed"
  ok "installed"
  [ "$(uname -m)" = "armv6l" ] && hint "on armv6 the armhf build has been known to segfault; the plain 'arm' asset is the fallback"
fi
CF_BIN="$(command -v cloudflared || echo /usr/bin/cloudflared)"

# --- service user ------------------------------------------------------------
step "Service user"
if id -u cloudflared >/dev/null 2>&1; then
  ok "user 'cloudflared' already exists"
else
  run $SUDO useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/cloudflared cloudflared
  ok "created system user 'cloudflared'"
fi

# --- token -------------------------------------------------------------------
step "Tunnel token"
TOKEN_CHANGED=0
if [ "$DRY_RUN" = "1" ]; then
  info "[dry-run] would write /etc/cloudflared/tunnel.env (0600 root:root)"
else
  TMP_ENV="$(mktemp)"; trap 'rm -f "$TMP_ENV"' EXIT
  printf 'TUNNEL_TOKEN=%s\n' "$CLOUDFLARE_TUNNEL_TOKEN" > "$TMP_ENV"
  if $SUDO cmp -s "$TMP_ENV" /etc/cloudflared/tunnel.env 2>/dev/null; then
    ok "/etc/cloudflared/tunnel.env already current"
  else
    $SUDO mkdir -p /etc/cloudflared
    $SUDO install -m 0600 -o root -g root "$TMP_ENV" /etc/cloudflared/tunnel.env
    TOKEN_CHANGED=1
    ok "wrote /etc/cloudflared/tunnel.env (0600 root:root)"
  fi
fi

# --- unit --------------------------------------------------------------------
step "systemd unit"
if [ "$DRY_RUN" = "1" ]; then
  info "[dry-run] would install /etc/systemd/system/cloudflared.service"
else
  TMP_UNIT="$(mktemp)"
  sed "s|__CLOUDFLARED_BIN__|${CF_BIN}|g" "$CONFIG_DIR/cloudflared.service" > "$TMP_UNIT"
  if cmp -s "$TMP_UNIT" /etc/systemd/system/cloudflared.service 2>/dev/null; then
    ok "cloudflared.service already current"
  else
    $SUDO install -m 0644 "$TMP_UNIT" /etc/systemd/system/cloudflared.service
    $SUDO systemctl daemon-reload
    ok "installed cloudflared.service (Restart=always, unprivileged user)"
  fi
  rm -f "$TMP_UNIT"
fi

run $SUDO systemctl enable cloudflared
if [ "$TOKEN_CHANGED" = "1" ]; then
  run $SUDO systemctl restart cloudflared
else
  run $SUDO systemctl start cloudflared
fi

# --- wait for the tunnel to register -----------------------------------------
if [ "$DRY_RUN" != "1" ]; then
  REGISTERED=0
  for _ in $(seq 1 30); do
    if $SUDO journalctl -u cloudflared --since "2 min ago" --no-pager 2>/dev/null \
         | grep -q 'Registered tunnel connection'; then
      REGISTERED=1; break
    fi
    sleep 1
  done
  if [ "$REGISTERED" = "1" ]; then
    ok "tunnel registered with Cloudflare"
  else
    warn "no 'Registered tunnel connection' in the log yet"
    hint "check:  sudo journalctl -u cloudflared -n 40"
    hint "and in Zero Trust -> Networks -> Tunnels that the token matches and the"
    hint "Public Hostname ${PUBLIC_HOSTNAME} -> http://localhost:${SERVER_PORT} exists"
  fi
fi

# --- report ------------------------------------------------------------------
PUB="$(public_url)"
echo
printf '%s==> short address: %s/%s/?opds%s\n' "$C_GRN" "$PUB" "$BOOKS_ENDPOINT" "$C_RESET"
[ "$WALLPAPERS_ENABLED" = "1" ] && info "wallpapers:       ${PUB}/${WALLPAPERS_ENDPOINT}/?opds"
info "manage:           ${PUB}/${MANAGER_ENDPOINT}/"
hint "Cloudflare's free plan caps request bodies at 100 MB: use the LAN or Funnel"
hint "address for anything bigger than that."
