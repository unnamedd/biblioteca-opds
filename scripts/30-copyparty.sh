#!/usr/bin/env bash
# 30-copyparty.sh -- install copyparty, render /etc/copyparty.conf, run it
# under systemd with Restart=always.

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

print_usage() { cat <<'USAGE'
usage: 30-copyparty.sh [--dry-run] [--update] [--no-ban]

  --update   re-download copyparty-sfx.py even if it is already present
  --no-ban   write "ban-pw: no" into the config, disabling the brute-force
             ban while you are still typing the password into the reader.
             Equivalent to BAN_PW=0 in library.env. Turn it back on after.
USAGE
}

UPDATE=0
parse_common_flags "$@"
for a in "${REMAINING_ARGS[@]:-}"; do
  case "$a" in
    --update) UPDATE=1 ;;
    --no-ban) BAN_PW_OVERRIDE=0 ;;
    "") ;;
    *) die "unknown argument: $a" ;;
  esac
done

load_env
[ -n "${BAN_PW_OVERRIDE:-}" ] && BAN_PW="$BAN_PW_OVERRIDE"
require_sudo

SFX=/usr/local/bin/copyparty-sfx.py
SFX_URL=https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py

# --- binary ------------------------------------------------------------------
step "copyparty"

if [ -x "$SFX" ] && [ "$UPDATE" = "0" ]; then
  ok "already installed: $SFX"
else
  info "downloading $SFX_URL"
  run_sh "$SUDO curl -fsSL -o '$SFX.tmp' '$SFX_URL'"
  run $SUDO install -m 0755 "$SFX.tmp" "$SFX"
  run $SUDO rm -f "$SFX.tmp"
  ok "installed $SFX"
fi

# --- password ----------------------------------------------------------------
step "Account"

GENERATED=0
if [ -z "${COPYPARTY_PASSWORD:-}" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    COPYPARTY_PASSWORD="<generated-at-run-time>"
  else
    # alphanumeric only: the config file is line-oriented and the password
    # also gets typed by hand into the reader
    COPYPARTY_PASSWORD="$(python3 -c '
import secrets, string
a = string.ascii_letters + string.digits
print("".join(secrets.choice(a) for _ in range(24)))')"
    GENERATED=1
  fi
fi

case "$COPYPARTY_PASSWORD" in
  *[![:alnum:]]*)
    warn "password contains non-alphanumeric characters"
    hint "that is fine for copyparty, but it is painful to type on the reader" ;;
esac

# --- config ------------------------------------------------------------------
step "Configuration"

if [ "$ENABLE_COVERS" = "1" ]; then
  THUMB_LINE="  # covers on (ENABLE_COVERS=1); needs pillow or ffmpeg"
  info "cover thumbnails: enabled (needs pillow or ffmpeg; 10-system.sh installs python3-pil)"
else
  THUMB_LINE="  no-thumb"
  info "cover thumbnails: disabled (set ENABLE_COVERS=1 to turn on)"
fi

if [ "$BAN_PW" = "1" ]; then
  BAN_PW_LINE=""
  info "brute-force ban: default (9 bad passwords/hour -> 24 h)"
else
  BAN_PW_LINE="  # bring-up only: re-enable by setting BAN_PW=1 and re-running
  ban-pw: no"
  warn "brute-force ban DISABLED - set BAN_PW=1 in library.env once this works"
fi

if [ "$DRY_RUN" = "1" ]; then
  info "[dry-run] would render /etc/copyparty.conf"
else
  TMP_CONF="$(mktemp)"
  trap 'rm -f "$TMP_CONF"' EXIT
  COPYPARTY_PASSWORD="$COPYPARTY_PASSWORD" \
  COPYPARTY_ACCOUNT="$COPYPARTY_ACCOUNT" \
  COPYPARTY_PORT="$COPYPARTY_PORT" \
  BOOKS_DIR="$BOOKS_DIR" \
  BAN_PW_LINE="$BAN_PW_LINE" \
  THUMB_LINE="$THUMB_LINE" \
  python3 - "$CONFIG_DIR/copyparty.conf.template" "$TMP_CONF" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
for key, env in (
    ("__PORT__",         "COPYPARTY_PORT"),
    ("__ACCOUNT__",      "COPYPARTY_ACCOUNT"),
    ("__PASSWORD__",     "COPYPARTY_PASSWORD"),
    ("__BOOKS_DIR__",    "BOOKS_DIR"),
    ("__BAN_PW_LINE__",  "BAN_PW_LINE"),
    ("__THUMB_LINE__",   "THUMB_LINE"),
):
    text = text.replace(key, os.environ[env])
# an empty placeholder leaves a run of blank lines behind; tidy it up
text = re.sub(r"\n{3,}", "\n\n", text)
open(dst, "w").write(text)
PY
  $SUDO install -m 0640 -o root -g "$SERVICE_USER" "$TMP_CONF" /etc/copyparty.conf
  ok "wrote /etc/copyparty.conf (0640 root:$SERVICE_USER)"
fi

# --- unit --------------------------------------------------------------------
step "systemd unit"

if [ "$DRY_RUN" = "1" ]; then
  info "[dry-run] would install /etc/systemd/system/copyparty.service"
else
  TMP_UNIT="$(mktemp)"
  sed "s|__SERVICE_USER__|${SERVICE_USER}|g" "$CONFIG_DIR/copyparty.service" > "$TMP_UNIT"
  if cmp -s "$TMP_UNIT" /etc/systemd/system/copyparty.service 2>/dev/null; then
    ok "copyparty.service already current"
  else
    $SUDO install -m 0644 "$TMP_UNIT" /etc/systemd/system/copyparty.service
    $SUDO systemctl daemon-reload
    ok "installed copyparty.service (Restart=always, RestartSec=5)"
  fi
  rm -f "$TMP_UNIT"
fi

run $SUDO systemctl enable copyparty
run $SUDO systemctl restart copyparty

if [ "$DRY_RUN" != "1" ]; then
  sleep 3
  if unit_active copyparty; then
    ok "copyparty is active on port ${COPYPARTY_PORT}"
  else
    $SUDO journalctl -u copyparty -n 30 --no-pager | sed 's/^/    /' || true
    die "copyparty failed to start"
  fi
fi

# --- report ------------------------------------------------------------------
if [ "$GENERATED" = "1" ]; then
  save_env COPYPARTY_PASSWORD "$COPYPARTY_PASSWORD"
  echo
  printf '%s┌─ generated password (saved to library.env) ─────────────%s\n' "$C_YEL" "$C_RESET"
  printf '%s│%s  user: %s\n' "$C_YEL" "$C_RESET" "$COPYPARTY_ACCOUNT"
  printf '%s│%s  pass: %s%s%s\n' "$C_YEL" "$C_RESET" "$C_BOLD" "$COPYPARTY_PASSWORD" "$C_RESET"
  printf '%s└────────────────────────────────────────────────────────%s\n' "$C_YEL" "$C_RESET"
fi

echo
printf '%s==> copyparty running at %s/books/%s\n' "$C_GRN" "$(lan_url)" "$C_RESET"
