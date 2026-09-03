#!/usr/bin/env bash
# 50-verify.sh -- prove the whole chain works, then print the two rows to
# type into the reader. Every check is an assertion; failures are summarised
# at the end with a pointer into docs/troubleshooting.md.

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

print_usage() { cat <<'USAGE'
usage: 50-verify.sh [--dry-run] [--no-restart-test]

  --no-restart-test   skip the kill -9 test (which briefly stops the server)
USAGE
}

RESTART_TEST=1
parse_common_flags "$@"
for a in "${REMAINING_ARGS[@]:-}"; do
  case "$a" in
    --no-restart-test) RESTART_TEST=0 ;;
    "") ;;
    *) die "unknown argument: $a" ;;
  esac
done

load_env
require_sudo

PASS=0; FAIL=0; SKIP=0
check_ok()   { ok   "$*"; PASS=$((PASS+1)); }
check_fail() { warn "$*"; FAIL=$((FAIL+1)); }
check_skip() { hint "skipped: $*"; SKIP=$((SKIP+1)); }

LAN="$(lan_url)"
BOOKS_URL="$(books_url)"
OPDS_URL="$(opds_url)"
MANAGER_URL="$(manager_url)"
MANAGER_BOOKS_URL="$(manager_books_url)"
WALLPAPERS_URL="$(wallpapers_url)"
WALLPAPERS_OPDS_URL="$(wallpapers_opds_url)"
WALLPAPERS_MGR_URL="$(wallpapers_mgr_url)"

# ---------------------------------------------------------------------------
step "1. services are running"

for u in copyparty avahi-daemon "avahi-alias@${SERVER_HOSTNAME}.service"; do
  if unit_active "$u"; then check_ok "$u active"; else check_fail "$u NOT active"; fi
done
if [ "$TAILSCALE_ENABLED" = "1" ]; then
  if unit_active tailscaled; then check_ok "tailscaled active"; else check_fail "tailscaled NOT active"; fi
else
  check_skip "tailscaled (TAILSCALE_ENABLED=0)"
fi
if [ "$CLOUDFLARE_ENABLED" = "1" ]; then
  if unit_active cloudflared; then check_ok "cloudflared active"; else check_fail "cloudflared NOT active"; fi
  if unit_enabled cloudflared; then check_ok "cloudflared enabled at boot"; else check_fail "cloudflared NOT enabled at boot"; fi
else
  check_skip "cloudflared (CLOUDFLARE_ENABLED=0)"
fi

for u in copyparty "avahi-alias@${SERVER_HOSTNAME}.service"; do
  if unit_enabled "$u"; then
    check_ok "$u enabled at boot"
  else
    check_fail "$u NOT enabled at boot"
  fi
done

# ---------------------------------------------------------------------------
step "2. restarts after a crash"

if [ "$RESTART_TEST" = "0" ] || [ "$DRY_RUN" = "1" ]; then
  check_skip "restart test"
else
  PID="$(systemctl show -p MainPID --value copyparty)"
  if [ -z "$PID" ] || [ "$PID" = "0" ]; then
    check_fail "could not find copyparty MainPID"
  else
    info "killing pid $PID with SIGKILL..."
    $SUDO kill -9 "$PID" 2>/dev/null || true
    RECOVERED=0
    for _ in $(seq 1 20); do
      sleep 1
      NEW="$(systemctl show -p MainPID --value copyparty)"
      if unit_active copyparty && [ -n "$NEW" ] && [ "$NEW" != "0" ] && [ "$NEW" != "$PID" ]; then
        RECOVERED=1; break
      fi
    done
    if [ "$RECOVERED" = "1" ]; then
      check_ok "systemd restarted copyparty (new pid $(systemctl show -p MainPID --value copyparty))"
    else
      check_fail "copyparty did not come back within 20s - is Restart=always set?"
    fi
  fi
fi

# ---------------------------------------------------------------------------
step "3. mDNS name resolves"

if getent hosts "${SERVER_HOSTNAME}.local" >/dev/null 2>&1; then
  check_ok "${SERVER_HOSTNAME}.local -> $(getent hosts "${SERVER_HOSTNAME}.local" | awk '{print $1}' | head -1)"
else
  check_fail "${SERVER_HOSTNAME}.local does not resolve on the Pi"
fi
hint "from the Mac:  dns-sd -G v4 ${SERVER_HOSTNAME}.local     (ctrl-C to stop)"
hint "the reader resolves .local too - lwIP does one-shot mDNS queries -"
hint "but that is the one link only step 8 can actually prove."

# ---------------------------------------------------------------------------
step "4. OPDS feed is served"

if [ -z "${MANAGER_PASSWORD:-}" ]; then
  check_skip "no MANAGER_PASSWORD in library.env - cannot test authenticated fetch"
else
  BODY="$(curl -sS --max-time 20 -u "${MANAGER_ACCOUNT}:${MANAGER_PASSWORD}" "$OPDS_URL" 2>/dev/null || true)"
  if printf '%s' "$BODY" | grep -qi '<feed'; then
    check_ok "authenticated GET $OPDS_URL returns an Atom feed"
    N="$(printf '%s' "$BODY" | grep -ci '<entry' || true)"
    info "entries in feed: $N"
    if printf '%s' "$BODY" | grep -qi 'application/epub+zip'; then
      check_ok "feed advertises application/epub+zip download links"
    elif [ "${N:-0}" -eq 0 ]; then
      hint "feed is empty - drop an .epub into $BOOKS_DIR and re-run"
    elif printf '%s' "$BODY" | grep -qi 'rel="subsection"'; then
      # books are one level down; follow the first subfolder and look there
      SUB="$(printf '%s' "$BODY" \
             | grep -A2 'rel="subsection"' | grep -o 'href="[^"]*"' \
             | head -1 | sed 's/href="//; s/"$//' \
             | python3 -c 'import html,sys; print(html.unescape(sys.stdin.read().strip()))')"
      if [ -n "$SUB" ] && curl -sS --max-time 20 -u "${MANAGER_ACCOUNT}:${MANAGER_PASSWORD}" \
           "${LAN}${SUB}" 2>/dev/null | grep -qi 'application/epub+zip'; then
        check_ok "epub links found in subfeed ${SUB}"
      else
        check_fail "subsections exist but no epub links below them - check opds-exts"
      fi
    else
      check_fail "feed has entries but no epub links - check opds-exts"
    fi
  else
    check_fail "no Atom feed at $OPDS_URL"
    printf '%s\n' "$BODY" | head -5 | sed 's/^/        /'
  fi
fi

# ---------------------------------------------------------------------------
step "5. the three doors"

code() { curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || echo 000; }
body() { curl -sS --max-time 20 "$@" 2>/dev/null || true; }

want() { # want <expected> <actual> <description>
  if [ "$2" = "$1" ]; then check_ok "$3 (http $2)"; else check_fail "$3 — expected $1, got $2"; fi
}

# (a) the landing page is public, the library is not
want 200 "$(code "${LAN}/")"        "anyone can see the landing page"
want 403 "$(code "$OPDS_URL")"      "a stranger cannot reach the library"
want 403 "$(code "$MANAGER_URL")"   "a stranger cannot reach the manager"

if body "${LAN}/" | grep -qi "<h1>"; then
  check_ok "landing page renders (title: ${LIBRARY_TITLE})"
else
  check_fail "landing page did not render an <h1> — is ${LANDING_DIR}/index.html present?"
fi

# (b) the reading door is read-only for EVERYONE, owner included
PROBE_R="${LAN}/${BOOKS_ENDPOINT}/.biblioteca-write-probe"
OWNER="${MANAGER_ACCOUNT}:${MANAGER_PASSWORD}"

want 200 "$(code -u "$OWNER" "$OPDS_URL")" "you can read the library"
for m in DELETE MOVE; do
  hdr=(); [ "$m" = "MOVE" ] && hdr=(-H "Destination: ${PROBE_R}-2")
  c="$(code -u "$OWNER" -X "$m" "${hdr[@]}" "$PROBE_R")"
  case "$c" in
    401|403) check_ok "even you cannot $m through /${BOOKS_ENDPOINT} (http $c)" ;;
    *)       check_fail "$m through /${BOOKS_ENDPOINT} returned http $c — the reading door is not read-only" ;;
  esac
done

# the claim the whole split rests on: same account, weaker perms on this door
if body -u "$OWNER" -H 'User-Agent: Mozilla/5.0' "$BOOKS_URL" | grep -q '"perms": \["read", "get"\]'; then
  check_ok "your reading view reports perms [read, get] — same UI your guests get"
else
  check_fail "your reading view did not report the read-only perms"
fi

# (c) the manager door: yours alone, and a container rather than a dumping ground
want 200 "$(code -u "$OWNER" "$MANAGER_URL")"       "you can reach /${MANAGER_ENDPOINT}"
want 200 "$(code -u "$OWNER" "$MANAGER_BOOKS_URL")" "...and /${MANAGER_ENDPOINT}/books"

# the container itself must not accept uploads, or a mistyped path silently
# lands a file beside books/ and wallpapers/ instead of inside one of them
c="$(code -u "$OWNER" -T /dev/null "${LAN}/${MANAGER_ENDPOINT}/.biblioteca-stray")"
case "$c" in
  401|403) check_ok "/${MANAGER_ENDPOINT} itself refuses uploads (http $c)" ;;
  *)       check_fail "/${MANAGER_ENDPOINT} accepted an upload (http $c) — it should only list its children"
           curl -sS --max-time 20 -o /dev/null -u "$OWNER" -X DELETE \
                "${LAN}/${MANAGER_ENDPOINT}/.biblioteca-stray" 2>/dev/null || true ;;
esac
if [ -n "${GUEST_ACCOUNT:-}" ] && [ -n "${GUEST_PASSWORD:-}" ]; then
  G="${GUEST_ACCOUNT}:${GUEST_PASSWORD}"
  want 200 "$(code -u "$G" "$OPDS_URL")"    "guest '${GUEST_ACCOUNT}' can read the library"
  want 403 "$(code -u "$G" "$MANAGER_URL")" "guest '${GUEST_ACCOUNT}' cannot reach the manager"
  PROBE_G="${LAN}/${BOOKS_ENDPOINT}/.biblioteca-guest-probe"
  c="$(code -u "$G" -X DELETE "$PROBE_G")"
  case "$c" in
    401|403) check_ok "guest DELETE refused (http $c)" ;;
    *)       check_fail "guest DELETE returned http $c — your friends can delete!" ;;
  esac
else
  check_skip "no guest account configured"
fi

# (d) the default paths must not answer, or the point of renaming is lost
if [ "$BOOKS_ENDPOINT" != "books" ] || [ "$MANAGER_ENDPOINT" != "manager" ]; then
  for d in books manager; do
    c="$(code -u "$OWNER" "${LAN}/${d}/")"
    case "$c" in
      404|403) check_ok "/${d} is not a door here (http $c)" ;;
      *)       check_fail "/${d} answered http $c — a stock-layout guess still works" ;;
    esac
  done
else
  check_skip "paths are still the defaults — set BOOKS_ENDPOINT/MANAGER_ENDPOINT in library.env"
fi

# (e) the administrative endpoints really are off, not merely hidden
for q in ru stack scan "reload=cfg"; do
  c="$(code -u "$OWNER" "${LAN}/?${q}")"
  case "$c" in
    200) check_fail "?${q} still answers (http 200) — the trim flags did not apply" ;;
    *)   check_ok "?${q} refused (http $c)" ;;
  esac
done

if body -u "$OWNER" "$BOOKS_URL" | grep -q 'GiB free of'; then
  check_fail "the listing still advertises disk capacity — check du-who"
else
  check_ok "disk capacity is not disclosed"
fi

# (f) wallpapers: their own door, their own format list
if [ "$WALLPAPERS_ENABLED" != "1" ]; then
  check_skip "wallpapers disabled (WALLPAPERS_ENABLED=0)"
  # 404 or 403 depending on whether the landing volume swallows the path;
  # either way it is not a door
  c="$(code -u "$OWNER" "$WALLPAPERS_URL")"
  case "$c" in
    403|404) check_ok "/${WALLPAPERS_ENDPOINT} is not served (http $c)" ;;
    *)       check_fail "/${WALLPAPERS_ENDPOINT} answered http $c with wallpapers disabled" ;;
  esac
else
  want 403 "$(code "$WALLPAPERS_OPDS_URL")"            "a stranger cannot reach the wallpapers"
  want 200 "$(code -u "$OWNER" "$WALLPAPERS_OPDS_URL")" "you can browse the wallpapers"
  want 200 "$(code -u "$OWNER" "$WALLPAPERS_MGR_URL")"  "you can manage them at /${MANAGER_ENDPOINT}/wallpapers"

  c="$(code -u "$OWNER" -X DELETE "${LAN}/${WALLPAPERS_ENDPOINT}/.biblioteca-write-probe")"
  case "$c" in
    401|403) check_ok "the wallpapers door is read-only too (http $c)" ;;
    *)       check_fail "DELETE through /${WALLPAPERS_ENDPOINT} returned http $c" ;;
  esac

  # books and wallpapers must not list each other's formats
  if body -u "$OWNER" "$OPDS_URL" | grep -qiE '\.(bmp|pxc)<'; then
    check_fail "the book catalogue is listing images — check the per-volume opds_exts"
  else
    check_ok "no images in the book catalogue"
  fi
fi

# ---------------------------------------------------------------------------
step "6. Tailscale Funnel"

TS_HOST=""
[ "$TAILSCALE_ENABLED" = "1" ] && TS_HOST="$(tailnet_hostname || true)"
if [ "$TAILSCALE_ENABLED" != "1" ]; then
  check_skip "Tailscale is off (TAILSCALE_ENABLED=0)"
elif [ -z "${TS_HOST:-}" ]; then
  check_skip "not logged into a tailnet - run 40-tailscale.sh"
else
  check_ok "tailnet hostname: $TS_HOST"
  if $SUDO tailscale funnel status 2>/dev/null | grep -q "${SERVER_PORT}"; then
    check_ok "funnel maps to local port ${SERVER_PORT}"
  else
    check_fail "funnel does not appear to point at port ${SERVER_PORT}"
    $SUDO tailscale funnel status 2>/dev/null | sed 's/^/        /' || true
  fi

  # Resolve the PUBLIC A record via DoH so we bypass MagicDNS (which would
  # send us over the tailnet and prove nothing about public reachability),
  # then force curl at that address.
  PUB_IP="$(curl -sS --max-time 15 -H 'accept: application/dns-json' \
      "https://cloudflare-dns.com/dns-query?name=${TS_HOST}&type=A" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(next(a["data"] for a in d.get("Answer",[]) if a.get("type")==1))
except Exception:
    pass' 2>/dev/null || true)"

  if [ -n "${PUB_IP:-}" ]; then
    CODE="$(curl -sS --max-time 25 -o /dev/null -w '%{http_code}' \
        --resolve "${TS_HOST}:443:${PUB_IP}" \
        "https://${TS_HOST}/books/?opds" 2>/dev/null || echo 000)"
    if [ "$CODE" = "000" ]; then
      check_fail "public HTTPS to ${TS_HOST} (${PUB_IP}) failed - TLS or funnel problem"
    else
      check_ok "public HTTPS reachable at ${TS_HOST} (${PUB_IP}) - http $CODE"
      hint "a 401/403 here is correct: it proves TLS works and auth is enforced"
    fi
  else
    check_skip "could not resolve the public A record for ${TS_HOST}"
  fi
fi

# ---------------------------------------------------------------------------
step "7. resource headroom"

free -m | sed 's/^/    /'
if journalctl -k --since "1 hour ago" 2>/dev/null | grep -qi 'out of memory\|oom-killer'; then
  check_fail "the kernel log shows OOM kills in the last hour"
else
  check_ok "no OOM kills in the last hour"
fi
RSS="$(ps -o rss= -C python3 2>/dev/null | awk '{s+=$1} END {print int(s/1024)}')"
[ -n "${RSS:-}" ] && info "copyparty (python3) RSS: ${RSS} MB"

# ---------------------------------------------------------------------------
step "8. short address (Cloudflare Tunnel)"

PUB=""
if [ "$CLOUDFLARE_ENABLED" != "1" ]; then
  check_skip "Cloudflare is off (CLOUDFLARE_ENABLED=0)"
  if [ "$TAILSCALE_ENABLED" != "1" ]; then
    hint "both remote entrances are off: the reader works at home only."
    hint "set TAILSCALE_ENABLED=1 or CLOUDFLARE_ENABLED=1 for access away from home"
  fi
else
  PUB="$(public_url)"
  DOMAIN="${PUBLIC_HOSTNAME#*.}"
  if $SUDO journalctl -u cloudflared --since "1 hour ago" --no-pager 2>/dev/null \
       | grep -q 'Registered tunnel connection'; then
    check_ok "tunnel registered with Cloudflare"
  else
    check_fail "no 'Registered tunnel connection' in cloudflared's log — token, or the dashboard hostname?"
  fi
  c="$(code "${PUB}/")"
  case "$c" in
    200) check_ok "landing page answers at ${PUBLIC_HOSTNAME}" ;;
    301|302|307|308)
      # A zone-wide Redirect Rule ("All incoming requests" -> some other site)
      # runs at Cloudflare's edge before anything reaches the tunnel, and it
      # catches every hostname in the zone - this one too.
      check_fail "${PUBLIC_HOSTNAME} redirects (http $c) to $(curl -sS --max-time 10 -o /dev/null -w '%{redirect_url}' "${PUB}/" 2>/dev/null)"
      hint "a Redirect Rule matching 'All incoming requests' catches this hostname too."
      hint "scope it with a custom filter expression, e.g."
      hint "  (http.host eq \"${DOMAIN}\") or (http.host eq \"www.${DOMAIN}\")" ;;
    *)   check_fail "landing page at ${PUBLIC_HOSTNAME} returned http $c" ;;
  esac
  want 403 "$(code "${PUB}/${BOOKS_ENDPOINT}/?opds")"              "a stranger cannot read through the short address"
  want 200 "$(code -u "$OWNER" "${PUB}/${BOOKS_ENDPOINT}/?opds")"  "you can read through the short address"

  # the "not in CT logs" property, checked rather than assumed: the served
  # certificate must be the wildcard for your domain, not one naming this host
  if have openssl; then
    SAN="$(openssl s_client -connect "${PUBLIC_HOSTNAME}:443" -servername "${PUBLIC_HOSTNAME}" </dev/null 2>/dev/null \
           | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)"
    if printf '%s' "$SAN" | grep -q "\*\.${DOMAIN}"; then
      check_ok "certificate is the wildcard *.${DOMAIN} — this name is not in CT logs"
    elif [ -n "$SAN" ]; then
      check_fail "certificate names the host explicitly — it will appear in CT logs"
    else
      check_skip "could not read the certificate (is the tunnel up?)"
    fi
  else
    check_skip "openssl not installed - cannot inspect the certificate"
  fi
fi

# ---------------------------------------------------------------------------
step "Reader configuration"

cat <<EOF

  Settings -> System -> OPDS Servers -> Add Server
  (easier: File Transfer mode, then http://<device-ip>/settings in a browser)

    ┌──────────┬────────────────────────────────────────────────────────────┐
    │ Name     │ Home                                                       │
    │ URL      │ ${OPDS_URL}
    │ User     │ ${MANAGER_ACCOUNT}
    │ Password │ ${MANAGER_PASSWORD:-<see library.env>}
    └──────────┴────────────────────────────────────────────────────────────┘
EOF

if [ -n "${PUB:-}" ]; then
cat <<EOF
    ┌──────────┬────────────────────────────────────────────────────────────┐
    │ Name     │ Away                                                       │
    │ URL      │ ${PUB}/${BOOKS_ENDPOINT}/?opds
    │ User     │ ${MANAGER_ACCOUNT}
    │ Password │ ${MANAGER_PASSWORD:-<see library.env>}
    └──────────┴────────────────────────────────────────────────────────────┘
EOF
  [ -n "${TS_HOST:-}" ] && printf '    fallback via Tailscale: https://%s/%s/?opds\n' "$TS_HOST" "$BOOKS_ENDPOINT"
elif [ -n "${TS_HOST:-}" ]; then
cat <<EOF
    ┌──────────┬────────────────────────────────────────────────────────────┐
    │ Name     │ Away                                                       │
    │ URL      │ https://${TS_HOST}/${BOOKS_ENDPOINT}/?opds
    │ User     │ ${MANAGER_ACCOUNT}
    │ Password │ ${MANAGER_PASSWORD:-<see library.env>}
    └──────────┴────────────────────────────────────────────────────────────┘
EOF
else
cat <<EOF

  No "Away" entry: LAN only by configuration. The reader works at home; set
  TAILSCALE_ENABLED=1 or CLOUDFLARE_ENABLED=1 in library.env for access away
  from home.
EOF
fi

if [ -n "${GUEST_ACCOUNT:-}" ]; then
cat <<EOF

  Give your friends these — read-only, they cannot change anything:
    ┌──────────┬────────────────────────────────────────────────────────────┐
    │ URL      │ ${BOOKS_URL}
    │ OPDS     │ ${OPDS_URL}
    │ User     │ ${GUEST_ACCOUNT}
    │ Password │ ${GUEST_PASSWORD:-<see library.env>}
    └──────────┴────────────────────────────────────────────────────────────┘
EOF
fi

cat <<EOF

  Your doors:
    landing (everyone) ${LAN}/
    reading (you+guest) ${BOOKS_URL}
    manage  (you only)  ${MANAGER_URL}
                        ${MANAGER_BOOKS_URL}      <- upload books here
                        ${WALLPAPERS_MGR_URL}  <- upload wallpapers here

  Wallpapers (add as a SECOND OPDS server on the reader):
    browse  ${WALLPAPERS_URL}
    OPDS    ${WALLPAPERS_OPDS_URL}
${PUB:+    away    ${PUB}/${WALLPAPERS_ENDPOINT}/?opds
}    Sleep screens are BMP at 480x800 (X4) or 528x792 (X3), or PXC.
    Open one in Browse Files on the reader and set it as the sleep cover.

  Note: /${BOOKS_ENDPOINT} is read-only for you too. That is deliberate — it is
  what makes your reading view identical to your guests'. Go to
  /${MANAGER_ENDPOINT}/books to add, rename or delete books.

  Also set on the reader:  Background Server -> Only on Charge

  Still manual, because only you can do them:
    8.  reader on home wifi  -> browse "Home" -> download a book
    9.  reader on the phone hotspot -> browse "Away" -> download a book
EOF

# ---------------------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then
  printf '%s==> %d passed, %d skipped, 0 failed%s\n' "$C_GRN" "$PASS" "$SKIP" "$C_RESET"
  [ "$BAN_PW" = "0" ] && warn "BAN_PW=0 is still set - put it back to 1 and re-run 30-copyparty.sh"
  exit 0
fi
printf '%s==> %d passed, %d skipped, %d FAILED%s\n' "$C_RED" "$PASS" "$SKIP" "$FAIL" "$C_RESET"
hint "see docs/troubleshooting.md"
exit 1
