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

# --- passwords ---------------------------------------------------------------
step "Accounts"

# alphanumeric only: the config file is line-oriented, and these get typed by
# hand into the reader and read out loud to friends
gen_password() {
  python3 -c '
import secrets, string
a = string.ascii_letters + string.digits
print("".join(secrets.choice(a) for _ in range(24)))'
}

if [ -n "${GUEST_ACCOUNT:-}" ] && [ "$GUEST_ACCOUNT" = "$MANAGER_ACCOUNT" ]; then
  die "GUEST_ACCOUNT and MANAGER_ACCOUNT are both '$GUEST_ACCOUNT'; they must differ"
fi

GENERATED=0
if [ -z "${MANAGER_PASSWORD:-}" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    MANAGER_PASSWORD="<generated-at-run-time>"
  else
    MANAGER_PASSWORD="$(gen_password)"; GENERATED=1
  fi
fi

GUEST_GENERATED=0
if [ -n "${GUEST_ACCOUNT:-}" ] && [ -z "${GUEST_PASSWORD:-}" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    GUEST_PASSWORD="<generated-at-run-time>"
  else
    GUEST_PASSWORD="$(gen_password)"; GUEST_GENERATED=1
  fi
fi

for _pw in "$MANAGER_PASSWORD" "${GUEST_PASSWORD:-}"; do
  case "$_pw" in
    "") ;;
    *[![:alnum:]]*)
      warn "a password contains non-alphanumeric characters"
      hint "fine for copyparty, but painful to type on the reader" ;;
  esac
done

# --- config ------------------------------------------------------------------
step "Configuration"

ACCOUNTS_LINES="  ${MANAGER_ACCOUNT}: ${MANAGER_PASSWORD}"

# The reading door is read-only for EVERYONE -- you included. Browsing it,
# your account reports perms ["read","get"], exactly what a guest sees, so
# copyparty renders the same stripped-down UI. Management lives behind
# MANAGER_ENDPOINT. Same folder on disk either way; nothing is duplicated.
BOOKS_ACCS="    r: ${MANAGER_ACCOUNT}"

if [ -n "${GUEST_ACCOUNT:-}" ]; then
  ACCOUNTS_LINES="${ACCOUNTS_LINES}
  ${GUEST_ACCOUNT}: ${GUEST_PASSWORD}"
  # "r" is list + download: enough for the web UI and for OPDS, and it grants
  # no upload, rename or delete
  BOOKS_ACCS="    r: ${GUEST_ACCOUNT}
${BOOKS_ACCS}"
  info "accounts: ${MANAGER_ACCOUNT} (full) + ${GUEST_ACCOUNT} (read-only)"
else
  info "accounts: ${MANAGER_ACCOUNT} only (set GUEST_ACCOUNT to add a read-only one)"
fi

VOLUMES="[/]
  ${LANDING_DIR}
  accs:
    # h = serve index.html to anyone; the folder itself stays unlistable.
    # Deliberately NOT writable by anyone: this volume catches every URL that
    # matches no other door, so a mistyped upload path would otherwise land a
    # file in a folder that is served publicly. The installer writes
    # index.html straight to disk, so nothing needs HTTP write here.
    h: *
  flags:
    hist: /var/lib/copyparty/hist/landing

[/${BOOKS_ENDPOINT}]
  ${BOOKS_DIR}
  accs:
${BOOKS_ACCS}
  flags:
    opds
    opds_exts: ${BOOKS_EXTS}
    hist: /var/lib/copyparty/hist/books

[/${MANAGER_ENDPOINT}]
  ${MANAGER_ROOT_DIR}
  accs:
    # Listing only, over an always-empty directory: this door exists so that
    # /${MANAGER_ENDPOINT}/ shows its children instead of 403-ing. Read-only,
    # so a mistyped upload cannot land here instead of in books/ or
    # wallpapers/.
    r: ${MANAGER_ACCOUNT}
  flags:
    hist: /var/lib/copyparty/hist/manager-root

[/${MANAGER_ENDPOINT}/books]
  ${BOOKS_DIR}
  accs:
    # r=read w=upload m=move/rename d=delete
    rwmd: ${MANAGER_ACCOUNT}
  flags:
    hist: /var/lib/copyparty/hist/manager-books"

DOORS="/ (landing) - /${BOOKS_ENDPOINT} (reading) - /${MANAGER_ENDPOINT} (management)"

if [ "$WALLPAPERS_ENABLED" = "1" ]; then
  # Sleep-screen images get their own directory and their own format list, so
  # they never reach the book catalogue. The writable mount sits under the
  # manager door, keeping one place to administer everything.
  WALL_ACCS="    r: ${MANAGER_ACCOUNT}"
  [ -n "${GUEST_ACCOUNT:-}" ] && WALL_ACCS="    r: ${GUEST_ACCOUNT}
${WALL_ACCS}"
  VOLUMES="${VOLUMES}

[/${WALLPAPERS_ENDPOINT}]
  ${WALLPAPERS_DIR}
  accs:
${WALL_ACCS}
  flags:
    opds
    opds_exts: ${WALLPAPERS_EXTS}
    hist: /var/lib/copyparty/hist/wallpapers

[/${MANAGER_ENDPOINT}/wallpapers]
  ${WALLPAPERS_DIR}
  accs:
    rwmd: ${MANAGER_ACCOUNT}
  flags:
    hist: /var/lib/copyparty/hist/manager-wallpapers"
  DOORS="${DOORS} - /${WALLPAPERS_ENDPOINT} (wallpapers)"
else
  info "wallpapers: disabled (WALLPAPERS_ENABLED=0)"
fi

info "doors: ${DOORS}"

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
  MANAGER_PASSWORD="$MANAGER_PASSWORD" \
  MANAGER_ACCOUNT="$MANAGER_ACCOUNT" \
  SERVER_PORT="$SERVER_PORT" \
  BOOKS_DIR="$BOOKS_DIR" \
  BAN_PW_LINE="$BAN_PW_LINE" \
  THUMB_LINE="$THUMB_LINE" \
  ACCOUNTS_LINES="$ACCOUNTS_LINES" \
  VOLUMES="$VOLUMES" \
  LIBRARY_TITLE="$LIBRARY_TITLE" \
  python3 - "$CONFIG_DIR/copyparty.conf.template" "$TMP_CONF" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
for key, env in (
    ("__PORT__",           "SERVER_PORT"),
    ("__BOOKS_DIR__",      "BOOKS_DIR"),
    ("__BAN_PW_LINE__",    "BAN_PW_LINE"),
    ("__THUMB_LINE__",     "THUMB_LINE"),
    ("__ACCOUNTS_LINES__", "ACCOUNTS_LINES"),
    ("__LIBRARY_TITLE__",  "LIBRARY_TITLE"),
    ("__VOLUMES__",        "VOLUMES"),
):
    text = text.replace(key, os.environ[env])
# an empty placeholder leaves a run of blank lines behind; tidy it up
text = re.sub(r"\n{3,}", "\n\n", text)
open(dst, "w").write(text)
PY
  $SUDO install -m 0640 -o root -g "$SERVICE_USER" "$TMP_CONF" /etc/copyparty.conf
  ok "wrote /etc/copyparty.conf (0640 root:$SERVICE_USER)"
fi

# --- landing page ------------------------------------------------------------
step "Landing page"

if [ "$DRY_RUN" = "1" ]; then
  info "[dry-run] would render $LANDING_DIR/index.html"
else
  TMP_HTML="$(mktemp)"
  LIBRARY_TITLE="$LIBRARY_TITLE" BOOKS_ENDPOINT="$BOOKS_ENDPOINT" \
  python3 - "$CONFIG_DIR/landing/index.html.template" "$TMP_HTML" <<'HTMLPY'
import html, os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
# escape: these land inside HTML, and a title containing & or < would break it
for key, env in (("__LIBRARY_TITLE__",  "LIBRARY_TITLE"),
                 ("__BOOKS_ENDPOINT__", "BOOKS_ENDPOINT")):
    text = text.replace(key, html.escape(os.environ[env], quote=True))
open(dst, "w").write(text)
HTMLPY
  $SUDO install -m 0644 -o "$SERVICE_USER" -g "$SERVICE_USER" "$TMP_HTML" "$LANDING_DIR/index.html"
  rm -f "$TMP_HTML"
  ok "wrote $LANDING_DIR/index.html (title: $LIBRARY_TITLE)"
  hint "customise config/landing/index.html.template, not the copy on the Pi --"
  hint "it is overwritten on every run so the server stays reproducible"
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
    ok "copyparty is active on port ${SERVER_PORT}"
  else
    $SUDO journalctl -u copyparty -n 30 --no-pager | sed 's/^/    /' || true
    die "copyparty failed to start"
  fi
fi

# --- report ------------------------------------------------------------------
if [ "$GUEST_GENERATED" = "1" ]; then
  save_env GUEST_PASSWORD "$GUEST_PASSWORD"
  echo
  printf '%s┌─ read-only guest password (saved to library.env) ───────%s\n' "$C_YEL" "$C_RESET"
  printf '%s│%s  user: %s\n' "$C_YEL" "$C_RESET" "$GUEST_ACCOUNT"
  printf '%s│%s  pass: %s%s%s\n' "$C_YEL" "$C_RESET" "$C_BOLD" "$GUEST_PASSWORD" "$C_RESET"
  printf '%s│%s  this is the one to give your friends\n' "$C_YEL" "$C_RESET"
  printf '%s└────────────────────────────────────────────────────────%s\n' "$C_YEL" "$C_RESET"
fi

if [ "$GENERATED" = "1" ]; then
  save_env MANAGER_PASSWORD "$MANAGER_PASSWORD"
  echo
  printf '%s┌─ generated password (saved to library.env) ─────────────%s\n' "$C_YEL" "$C_RESET"
  printf '%s│%s  user: %s\n' "$C_YEL" "$C_RESET" "$MANAGER_ACCOUNT"
  printf '%s│%s  pass: %s%s%s\n' "$C_YEL" "$C_RESET" "$C_BOLD" "$MANAGER_PASSWORD" "$C_RESET"
  printf '%s└────────────────────────────────────────────────────────%s\n' "$C_YEL" "$C_RESET"
fi

echo
printf '%s==> copyparty running at %s/books/%s\n' "$C_GRN" "$(lan_url)" "$C_RESET"
