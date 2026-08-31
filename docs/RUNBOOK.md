# Runbook — doing all of it by hand

Every section here matches the script with the same number, so section 30 is
exactly what `scripts/30-copyparty.sh` does. Use this when a script fails, when
you are rebuilding on different hardware, or when you just want to know what is
actually being changed on the machine.

Values in `<angle brackets>` come from `library.env`. The defaults are:

| variable | default |
|---|---|
| `LIBRARY_ALIAS` | `biblioteca` |
| `COPYPARTY_ACCOUNT` | `reader` |
| `COPYPARTY_PORT` | `80` |
| `BOOKS_DIR` | `/srv/books` |
| `SERVICE_USER` | `copyparty` |

Everything below runs **on the Pi**.

---

## 00 — Preflight

Nothing is installed here; you are just checking assumptions.

```bash
cat /etc/os-release            # Debian family?
uname -m                       # armv7l on your Pi Zero 2 W
systemctl --version | head -1  # systemd present
python3 --version              # copyparty needs only this
free -m                        # >= 150 MB available before starting
df -Pm /srv                    # room for books
sudo ss -ltnp 'sport = :80'    # port 80 must be free
systemctl is-active avahi-daemon
ip -4 route get 1.1.1.1        # note the "src" address - that is your LAN IP
```

If something already owns port 80, either stop it or set `COPYPARTY_PORT=3923`
in `library.env`; every URL below then gains `:3923`.

---

## 10 — System preparation

```bash
sudo apt update
sudo apt install -y python3 curl avahi-utils zram-tools
```

**zram** — compressed swap in RAM. On a 512 MB board this buys headroom without
grinding the SD card.

```bash
sudo tee /etc/default/zramswap >/dev/null <<'EOF'
ALGO=lz4
PERCENT=50
EOF
sudo systemctl restart zramswap
swapon --show
```

**Service user and directories** — copyparty runs unprivileged.

```bash
sudo useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/copyparty copyparty
sudo mkdir -p /var/lib/copyparty/hist /srv/books
sudo chown -R copyparty:copyparty /var/lib/copyparty /srv/books
sudo chmod 0755 /srv/books
```

---

## 20 — `biblioteca.local`

This publishes a **second** mDNS A record beside the Pi's existing hostname. The
machine is not renamed and nothing else on it is affected.

`avahi-publish` holds the record for as long as it runs, which makes it a
natural `Type=simple` systemd service. The wrapper resolves the current IP at
start, so a reboot onto a new DHCP lease still publishes the right address.

```bash
sudo tee /usr/local/lib/avahi-alias.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ALIAS="${1:?usage: avahi-alias.sh <name-without-.local>}"
IP="$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i+1); exit } }')"
[ -n "${IP:-}" ] || { echo "avahi-alias: no primary IPv4 yet" >&2; exit 1; }
echo "avahi-alias: publishing ${ALIAS}.local -> ${IP}"
exec /usr/bin/avahi-publish -a -R "${ALIAS}.local" "${IP}"
EOF
sudo chmod 0755 /usr/local/lib/avahi-alias.sh
```

`-a` publishes an address record; `-R` suppresses the reverse PTR record, which
would otherwise collide with the host's real hostname since both names share one
IP address.

```bash
sudo tee /etc/systemd/system/avahi-alias@.service >/dev/null <<'EOF'
[Unit]
Description=Avahi mDNS alias %i.local
After=network-online.target avahi-daemon.service
Wants=network-online.target
Requires=avahi-daemon.service
PartOf=avahi-daemon.service

[Service]
Type=simple
ExecStart=/usr/local/lib/avahi-alias.sh %i
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now avahi-alias@biblioteca
getent hosts biblioteca.local
```

`PartOf=avahi-daemon.service` re-publishes the record if the daemon bounces.

### The bulletproof alternative

If you would rather not run a helper service at all, rename the Pi. Avahi then
publishes `<hostname>.local` itself and tracks IP changes natively:

```bash
sudo hostnamectl set-hostname biblioteca
sudo sed -i 's/\braspberrypi\b/biblioteca/g' /etc/hosts
sudo systemctl restart avahi-daemon
```

This is strictly more robust; it is not the default only because it changes the
identity of a Pi that is presumably doing other things too.

Either way, a **DHCP reservation** on your router is worth setting so the
address stops moving in the first place.

---

## 30 — copyparty

One process serves both the OPDS catalogue and the phone upload UI.

```bash
sudo curl -fsSL -o /usr/local/bin/copyparty-sfx.py \
  https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py
sudo chmod 0755 /usr/local/bin/copyparty-sfx.py
```

**Config.** Generate a password you are willing to type on the reader — keep it
alphanumeric:

```bash
python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))'
```

```bash
sudo tee /etc/copyparty.conf >/dev/null <<'EOF'
[global]
  p: 80
  opds
  no-thumb
  e2d
  hist: /var/lib/copyparty/hist
  xff-hdr: x-forwarded-for
  xff-src: 127.0.0.1
  rproxy: 1

[accounts]
  reader: PASTE_THE_PASSWORD_HERE

[/books]
  /srv/books
  accs:
    rw: reader
  flags:
    opds
EOF
sudo chown root:copyparty /etc/copyparty.conf
sudo chmod 0640 /etc/copyparty.conf
```

What each line is for:

- `p: 80` — so the URL carries no port number.
- `opds` — the OPDS feed is **off by default**; this turns it on. The feed is
  the volume URL with `?opds` appended.
- `no-thumb` — no Pillow/ffmpeg work on a 1 GHz Cortex-A53. The OPDS feed
  still emits cover links, but with an empty `href`, so the reader shows no
  covers. To get real covers: `sudo apt install python3-pil`, drop the
  `no-thumb` line, `sudo systemctl reload copyparty` — the links then become
  `...epub?dl&th=jf` and copyparty extracts the cover on demand. It costs CPU
  on every first view, which is why it is off by default
  (`ENABLE_COVERS=1` in `library.env` does this for you).
- `e2d` — the up2k index, which gives you search and deduplication cheaply.
- `hist:` — keeps the index out of the books folder itself.
- `xff-*` / `rproxy: 1` — Tailscale terminates TLS and proxies from localhost,
  setting `X-Forwarded-For` / `-Proto` / `-Host`. This trusts exactly that hop.

Two behaviours worth knowing:

- `--opds-exts` defaults to `epub,cbz,pdf`. Add `mobi,azw3` if you keep those.
- copyparty is **password-only** by default: the username field is ignored, and
  the password is accepted in *either* HTTP Basic field. CrossPoint sends a
  normal `user:pass` header, so it just works.
- `--ban-pw` defaults to *9 wrong passwords in 60 minutes → 24 hour ban*. While
  you are still typing the password into the reader by hand, add `ban-pw: no`
  to `[global]` so a typo cannot lock you out — then remove it.

**systemd.** This is upstream's hardened unit plus the `Restart=` it does not
ship with, which is the whole "come back after a crash" requirement.

```bash
sudo tee /etc/systemd/system/copyparty.service >/dev/null <<'EOF'
[Unit]
Description=copyparty file server (Biblioteca)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
SyslogIdentifier=copyparty
Environment=PYTHONUNBUFFERED=x
ExecReload=/bin/kill -s USR1 $MAINPID

User=copyparty
Group=copyparty
WorkingDirectory=/var/lib/copyparty
Environment=XDG_CONFIG_HOME=/var/lib/copyparty/.config

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

Restart=always
RestartSec=5

MemoryMax=50%
MemorySwapMax=50%

ProtectClock=true
ProtectControlGroups=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
RemoveIPC=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true

LogsDirectory=copyparty

ExecStart=/usr/bin/python3 /usr/local/bin/copyparty-sfx.py -c /etc/copyparty.conf

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now copyparty
systemctl status copyparty --no-pager
```

`AmbientCapabilities=CAP_NET_BIND_SERVICE` is what lets an unprivileged process
bind port 80 — no root, no setcap on the binary.

After editing `/etc/copyparty.conf`, `sudo systemctl reload copyparty` is enough
(it sends `SIGUSR1`); a full restart is not needed.

---

## 40 — Tailscale Funnel

**Funnel, not Serve.** The reader is an ESP32-C3 and cannot join the tailnet,
and a phone does not route hotspot-tethered clients through its own VPN, so
a tailnet-only URL is unreachable from the reader when you are out. Funnel gives
a publicly-trusted Let's Encrypt certificate, which is what the firmware
requires — it verifies HTTPS against the bundled CA roots, so a self-signed
certificate would fail.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up            # opens a browser login URL
sudo tailscale funnel --bg 80
sudo tailscale funnel status
```

- MagicDNS and HTTPS certificates must be enabled for the tailnet. The CLI
  provisions the certificate and adds the `funnel` node attribute to the tailnet
  policy file for you — approve whatever it prompts for.
- `--bg` persists. It resumes after a reboot and after `tailscale down/up`, so
  no extra systemd unit is needed.
- Funnel only listens on **443, 8443 or 10000**, and one port cannot be Serve
  (private) and Funnel (public) at the same time.
- To undo: `sudo tailscale funnel reset`.

Your public hostname:

```bash
sudo tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'
```

---

## 50 — Verifying

```bash
# services up and enabled
systemctl is-active copyparty tailscaled avahi-alias@biblioteca
systemctl is-enabled copyparty avahi-alias@biblioteca

# comes back after a crash
sudo kill -9 "$(systemctl show -p MainPID --value copyparty)"
sleep 6; systemctl is-active copyparty

# the name resolves
getent hosts biblioteca.local

# the feed is real OPDS
curl -sS -u reader:PASSWORD 'http://biblioteca.local/books/?opds' | head -40

# and is not readable without credentials
curl -sS -o /dev/null -w '%{http_code}\n' 'http://biblioteca.local/books/?opds'

# public path works (bypass MagicDNS so you test the real ingress)
TS=$(sudo tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
IP=$(curl -sS -H 'accept: application/dns-json' \
      "https://cloudflare-dns.com/dns-query?name=$TS&type=A" \
      | python3 -c 'import json,sys; print(next(a["data"] for a in json.load(sys.stdin)["Answer"] if a["type"]==1))')
curl -sS -o /dev/null -w '%{http_code}\n' --resolve "$TS:443:$IP" "https://$TS/books/?opds"

# headroom
free -m
journalctl -k --since '1 hour ago' | grep -i 'oom' || echo 'no OOM kills'
```

A `401`/`403` on the unauthenticated requests is the *correct* result — it means
TLS works and the catalogue is not public.

Then the part only you can do: download a book on the reader at home, and
another with the reader on your phone's hotspot.

---

## Day-to-day

```bash
# add a book without the web UI
scp 'Le Guin - The Dispossessed.epub' pi@biblioteca.local:/tmp/
ssh pi@biblioteca.local 'sudo install -o copyparty -g copyparty -m 0644 \
    "/tmp/Le Guin - The Dispossessed.epub" /srv/books/Fiction/ && rm /tmp/*.epub'

# logs
journalctl -u copyparty -f
journalctl -u avahi-alias@biblioteca -n 50

# after editing /etc/copyparty.conf
sudo systemctl reload copyparty

# update copyparty
sudo curl -fsSL -o /usr/local/bin/copyparty-sfx.py \
  https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py
sudo systemctl restart copyparty
```

---

## 99 — Removing it

```bash
sudo tailscale funnel reset
sudo systemctl disable --now copyparty avahi-alias@biblioteca
sudo rm -f /etc/systemd/system/copyparty.service \
           /etc/systemd/system/avahi-alias@.service \
           /etc/copyparty.conf \
           /usr/local/bin/copyparty-sfx.py \
           /usr/local/lib/avahi-alias.sh
sudo systemctl daemon-reload
sudo rm -rf /var/lib/copyparty     # index + thumbs; books are in /srv/books
sudo userdel copyparty
```

Your books in `/srv/books` are untouched.
