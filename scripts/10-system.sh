#!/usr/bin/env bash
# 10-system.sh -- packages, zram, service user and the books directory.
# Idempotent: safe to re-run.

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

print_usage() { cat <<'USAGE'
usage: 10-system.sh [--dry-run]

Installs python3, curl, avahi-utils and (optionally) zram-tools, creates the
unprivileged copyparty service user, and prepares BOOKS_DIR.
USAGE
}

parse_common_flags "$@"
load_env
require_sudo

# --- packages ----------------------------------------------------------------
step "Packages"

PKGS=(python3 curl avahi-utils)
[ "$ENABLE_ZRAM" = "1" ] && PKGS+=(zram-tools)
# EPUB cover extraction for the OPDS catalogue
[ "$ENABLE_COVERS" = "1" ] && PKGS+=(python3-pil)

MISSING=()
for p in "${PKGS[@]}"; do
  pkg_installed "$p" || MISSING+=("$p")
done

if [ "${#MISSING[@]}" -eq 0 ]; then
  ok "already installed: ${PKGS[*]}"
else
  info "installing: ${MISSING[*]}"
  run $SUDO apt-get update -qq
  run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING[@]}"
  ok "installed"
fi

# --- zram --------------------------------------------------------------------
if [ "$ENABLE_ZRAM" = "1" ]; then
  step "zram swap"
  if cmp -s "$CONFIG_DIR/zramswap" /etc/default/zramswap 2>/dev/null; then
    ok "/etc/default/zramswap already current"
  else
    run $SUDO install -m 0644 "$CONFIG_DIR/zramswap" /etc/default/zramswap
    run $SUDO systemctl restart zramswap
    ok "zram configured (lz4, 50% of RAM)"
  fi
  [ "$DRY_RUN" = "1" ] || { swapon --show 2>/dev/null | sed 's/^/    /' || true; }
else
  step "zram swap"
  info "skipped (ENABLE_ZRAM=0)"
fi

# --- service user ------------------------------------------------------------
step "Service user"
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
  ok "user '$SERVICE_USER' already exists"
else
  run $SUDO useradd --system --shell /usr/sbin/nologin \
      --home-dir /var/lib/copyparty "$SERVICE_USER"
  ok "created system user '$SERVICE_USER'"
fi

# --- directories -------------------------------------------------------------
step "Directories"
for d in /var/lib/copyparty /var/lib/copyparty/hist "$BOOKS_DIR"; do
  if [ -d "$d" ]; then
    ok "exists: $d"
  else
    run $SUDO mkdir -p "$d"
    ok "created: $d"
  fi
done
run $SUDO chown -R "$SERVICE_USER:$SERVICE_USER" /var/lib/copyparty "$BOOKS_DIR"
# you will drop books in here over ssh/scp too, so make it group-traversable
run $SUDO chmod 0755 "$BOOKS_DIR"
ok "ownership set to $SERVICE_USER"

echo
printf '%s==> system prepared%s\n' "$C_GRN" "$C_RESET"
