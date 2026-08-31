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
BOOKS_URL="${LAN}/books/"
OPDS_URL="${LAN}/books/?opds"

# ---------------------------------------------------------------------------
step "1. services are running"

for u in copyparty avahi-daemon "avahi-alias@${LIBRARY_ALIAS}.service"; do
  if unit_active "$u"; then check_ok "$u active"; else check_fail "$u NOT active"; fi
done
if unit_active tailscaled; then check_ok "tailscaled active"; else check_fail "tailscaled NOT active"; fi

for u in copyparty "avahi-alias@${LIBRARY_ALIAS}.service"; do
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

if getent hosts "${LIBRARY_ALIAS}.local" >/dev/null 2>&1; then
  check_ok "${LIBRARY_ALIAS}.local -> $(getent hosts "${LIBRARY_ALIAS}.local" | awk '{print $1}' | head -1)"
else
  check_fail "${LIBRARY_ALIAS}.local does not resolve on the Pi"
fi
hint "from the Mac:  dns-sd -G v4 ${LIBRARY_ALIAS}.local     (ctrl-C to stop)"
hint "the reader resolves .local too - lwIP does one-shot mDNS queries -"
hint "but that is the one link only step 8 can actually prove."

# ---------------------------------------------------------------------------
step "4. OPDS feed is served"

if [ -z "${COPYPARTY_PASSWORD:-}" ]; then
  check_skip "no COPYPARTY_PASSWORD in library.env - cannot test authenticated fetch"
else
  BODY="$(curl -sS --max-time 20 -u "${COPYPARTY_ACCOUNT}:${COPYPARTY_PASSWORD}" "$OPDS_URL" 2>/dev/null || true)"
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
      if [ -n "$SUB" ] && curl -sS --max-time 20 -u "${COPYPARTY_ACCOUNT}:${COPYPARTY_PASSWORD}" \
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
step "5. the library is not readable without credentials"

CODE="$(curl -sS --max-time 20 -o /tmp/xl-anon.$$ -w '%{http_code}' "$OPDS_URL" 2>/dev/null || echo 000)"
ANON="$(cat /tmp/xl-anon.$$ 2>/dev/null || true)"; rm -f /tmp/xl-anon.$$
if printf '%s' "$ANON" | grep -qi '<feed'; then
  check_fail "anonymous request returned a feed (http $CODE) - the volume is public!"
else
  check_ok "anonymous request does not expose the catalogue (http $CODE)"
fi

# ---------------------------------------------------------------------------
step "6. Tailscale Funnel"

TS_HOST="$(tailnet_hostname || true)"
if [ -z "${TS_HOST:-}" ]; then
  check_skip "not logged into a tailnet - run 40-tailscale.sh"
else
  check_ok "tailnet hostname: $TS_HOST"
  if $SUDO tailscale funnel status 2>/dev/null | grep -q "${COPYPARTY_PORT}"; then
    check_ok "funnel maps to local port ${COPYPARTY_PORT}"
  else
    check_fail "funnel does not appear to point at port ${COPYPARTY_PORT}"
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
step "Reader configuration"

cat <<EOF

  Settings -> System -> OPDS Servers -> Add Server
  (easier: File Transfer mode, then http://<device-ip>/settings in a browser)

    ┌──────────┬────────────────────────────────────────────────────────────┐
    │ Name     │ Home                                                       │
    │ URL      │ ${OPDS_URL}
    │ User     │ ${COPYPARTY_ACCOUNT}
    │ Password │ ${COPYPARTY_PASSWORD:-<see library.env>}
    └──────────┴────────────────────────────────────────────────────────────┘
EOF

if [ -n "${TS_HOST:-}" ]; then
cat <<EOF
    ┌──────────┬────────────────────────────────────────────────────────────┐
    │ Name     │ Away                                                       │
    │ URL      │ https://${TS_HOST}/books/?opds
    │ User     │ ${COPYPARTY_ACCOUNT}
    │ Password │ ${COPYPARTY_PASSWORD:-<see library.env>}
    └──────────┴────────────────────────────────────────────────────────────┘
EOF
fi

cat <<EOF

  Upload books from your phone:  ${BOOKS_URL}
  Also set:  Background Server -> Only on Charge

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
