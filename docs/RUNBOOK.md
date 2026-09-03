# 📚 Runbook — doing all of it by hand

Every section here matches the script with the same number, so section 30 is
exactly what `scripts/30-copyparty.sh` does. Use this when a script fails, when
you are rebuilding on different hardware, or when you just want to know what is
actually being changed on the machine.

Values in `<angle brackets>` come from `library.env`. The defaults are:

| variable | default |
|---|---|
| `LIBRARY_TITLE` | `Biblioteca` |
| `SERVER_HOSTNAME` | `biblioteca` |
| `BOOKS_ENDPOINT` | `books` |
| `MANAGER_ENDPOINT` | `manager` |
| `LANDING_DIR` | `/srv/landing` |
| `MANAGER_ACCOUNT` | `reader` |
| `GUEST_ACCOUNT` | *(unset)* |
| `SERVER_PORT` | `80` |
| `BOOKS_DIR` | `/srv/books` |
| `SERVICE_USER` | `copyparty` |
| `TAILSCALE_ENABLED` | `1` |
| `CLOUDFLARE_ENABLED` | `0` |
| `PUBLIC_HOSTNAME` | *(unset)* |
| `CLOUDFLARE_TUNNEL_TOKEN` | *(unset)* |

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

If something already owns port 80, either stop it or set `SERVER_PORT=3923`
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
# one hist per volume: copyparty refuses to start if two share a histpath,
# and /srv/books is mounted twice (reading + management)
sudo mkdir -p /var/lib/copyparty/hist/{landing,books,wallpapers,manager-root,manager-books,manager-wallpapers} \
             /var/lib/copyparty/manager-root /srv/books /srv/landing /srv/wallpapers
sudo chown -R copyparty:copyparty /var/lib/copyparty /srv/books /srv/landing
sudo chmod 0755 /srv/books /srv/landing
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
  name: Biblioteca
  opds
  opds-exts: epub,xtc,xtch,txt,pdf,md,cbz,cbr,azw3,mobi,fb2
  no-thumb
  e2d

  no-robots
  no-ups-page
  no-stack
  no-rescan
  no-reload
  no-up-list
  ups-who: 0
  du-who: no
  ver-who: no
  zip-who: 1

  no-acode
  no-athumb
  no-vthumb
  no-mtag-ff
  no-logues
  no-readme

  html-head: <style>#cc,.agr,#v{display:none!important}</style>

  xff-hdr: x-forwarded-for
  xff-src: 127.0.0.1
  rproxy: -1

[accounts]
  reader: PASTE_YOUR_PASSWORD_HERE
  friends: PASTE_THEIR_PASSWORD_HERE

[/]
  /srv/landing
  accs:
    h: *
    rwmd: reader
  flags:
    hist: /var/lib/copyparty/hist/landing

[/books]
  /srv/books
  accs:
    r: friends
    r: reader
  flags:
    opds
    hist: /var/lib/copyparty/hist/books

[/manager]
  /var/lib/copyparty/manager-root      # always empty: lists its two children
  accs:
    r: reader
  flags:
    hist: /var/lib/copyparty/hist/manager-root

[/manager/books]
  /srv/books
  accs:
    rwmd: reader
  flags:
    hist: /var/lib/copyparty/hist/manager-books

[/wallpapers]
  /srv/wallpapers
  accs:
    r: friends
    r: reader
  flags:
    opds
    opds_exts: bmp,pxc
    hist: /var/lib/copyparty/hist/wallpapers

[/manager/wallpapers]
  /srv/wallpapers
  accs:
    rwmd: reader
  flags:
    hist: /var/lib/copyparty/hist/manager-wallpapers
EOF
sudo chown root:copyparty /etc/copyparty.conf
sudo chmod 0640 /etc/copyparty.conf
```

What each line is for:

- `p: 80` — so the URL carries no port number.
- `opds` — the OPDS feed is **off by default**; this turns it on. The feed is
  the volume URL with `?opds` appended.
- `no-thumb` — disables the thumbnailer. The OPDS feed still emits cover
  links, but with an empty `href`, so the reader shows no covers. To get real
  covers you need one backend installed — copyparty lists `epub` under both
  `--th-r-pil` (pillow) and `--th-r-ffi` (ffmpeg), so either works, and Pi OS
  Lite ships neither. `python3-pil` is much the smaller. Then drop the
  `no-thumb` line and `sudo systemctl reload copyparty`; the links become
  `...epub?dl&th=jf`. Each cover is decoded once and cached under `hist`, so
  the cost is one decode per book rather than per view
  (`ENABLE_COVERS=1` in `library.env` does all of this for you).
- `e2d` — the up2k index, which gives you search and deduplication cheaply.
- `hist:` — keeps the index out of the books folder itself.
- `xff-*` / `rproxy: -1` — Funnel and Cloudflare Tunnel both terminate TLS and
  proxy from localhost, setting `X-Forwarded-For`; `xff-src` trusts exactly
  that hop. `-1` attributes a request to the *rightmost* entry — the one the
  nearest proxy appended, i.e. the real client. This matters for `ban-pw`:
  with `1` (leftmost) a client can seed the header and dodge a ban by changing
  the seed, and with a header *name* that does not match what the proxy sends,
  every request looks like `127.0.0.1` and one wrong password bans everyone.
  Verified against copyparty; `-1` is correct for both tunnels.

Two behaviours worth knowing:

- `rwmd` is read + write + move + delete. `rw` alone is not enough: the web UI
  and WebDAV both answer `403 'delete' not allowed` and renaming fails too.
  `A` is the shorthand for `rwmda.`, which also grants admin and dotfiles.
- **Three doors, one folder.** `/srv/books` is mounted twice, at different URL
  paths with different permissions. Nothing is duplicated on disk.

  | path | who | what |
  |---|---|---|
  | `/` | everyone (`h: *`) | the landing page; the folder itself is not listable |
  | `/books` | `r: friends`, `r: reader` | reading + OPDS, read-only for *everyone* |
  | `/manager` | `rwmd: reader` | upload, rename, delete |

  The reading door being read-only *for you too* is the point: browsing it your
  account reports `perms: ["read","get"]` — exactly what a guest sees — so
  copyparty renders the same stripped-down UI. Go to `/manager` to change
  anything. `BOOKS_ENDPOINT` and `MANAGER_ENDPOINT` in `library.env` set those two
  names; pick your own so a stock install is not guessable.
- **Each volume needs its own `hist:`.** Mounting one folder twice with a shared
  histpath makes copyparty refuse to start:
  `invalid config; multiple volumes share the same histpath`.
- `GUEST_ACCOUNT=friends` generates a separate password if `GUEST_PASSWORD` is
  blank. Because it is its own account you can change or drop it without
  touching your own login, and the library is never open to anyone without one.
- **The trim flags disable endpoints, they do not merely hide links.** `?ru`
  answers *"listing of recent uploads is disabled in server config"*, and
  `?stack` / `?scan` / `?reload=cfg` return 403. `du-who: no` stops the listing
  header advertising `N GiB free of M GiB`. The `html-head` CSS is cosmetic
  only — it hides the dead links copyparty still renders under a heading called
  "other stuff:", but the markup remains in the page source.
- **`opds_exts` is per-volume, not global.** That is what keeps the two
  catalogues apart: the books volume lists book formats, the wallpapers volume
  lists `bmp,pxc`, and neither can show the other's files. A `.png` dropped in
  `/srv/wallpapers` is stored and downloadable from a browser but never
  reaches the reader — which is deliberate, because the device cannot open a
  standalone PNG.
- `opds_exts` picks which formats the catalogue lists. The reader itself opens
  only `epub`, `xtc`/`xtch` and `txt`; `pdf`, `md`, `cbz`, `azw3`, `mobi` and
  `fb2` list and download fine but are for reading on a phone or computer.
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

Skipped entirely when `TAILSCALE_ENABLED=0` in `library.env`: nothing installed,
nothing exposed, and an existing Tailscale setup is left alone. Everything below
is what happens when it is `1`.

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

## 45 — Cloudflare Tunnel (a short address on your own domain)

Skipped entirely when `CLOUDFLARE_ENABLED=0`. Funnel cannot serve a custom
domain — its certificate is only valid for `*.ts.net` — so a short name needs a
tunnel that brings its own certificate. Cloudflare's is a *wildcard* for your
domain, which means the subdomain never appears in Certificate Transparency
logs (Funnel's name does). The trade-off: Cloudflare terminates TLS at its edge
and sees the traffic in the clear, passwords included. Funnel does not. Both,
either, or neither can be on.

**Once, in the Cloudflare Zero Trust dashboard** (the domain's DNS must be hosted
at Cloudflare; the free plan is enough):

1. *Networks → Tunnels → Create a tunnel → Cloudflared*, give it a name.
2. Copy the token it shows into `library.env` as `CLOUDFLARE_TUNNEL_TOKEN`.
3. *Public Hostname*: subdomain `your-shelf` (or yours), your domain, path empty;
   *Service*: `HTTP`, `localhost:80` (your `SERVER_PORT`). Cloudflare creates the
   DNS record.

The tunnel's configuration lives at Cloudflare, so after an SD-card rebuild the
same token simply reattaches the same tunnel.

If the zone already has a **Redirect Rule** matching *All incoming requests* —
a bare domain sent to some other site, say — it will catch the new hostname too,
since redirect rules run at the edge before the tunnel. Scope it to the names it
was meant for with a custom filter expression:
`(http.host eq "<domain>") or (http.host eq "www.<domain>")`.

**On the Pi:**

```bash
# the .deb from GitHub; armhf = 32-bit Raspberry Pi OS, arm64 = 64-bit
curl -fsSL -o /tmp/cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-armhf.deb
sudo dpkg -i /tmp/cloudflared.deb && rm /tmp/cloudflared.deb

sudo useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/cloudflared cloudflared

# the token, readable by root only; systemd reads it before dropping privileges
sudo mkdir -p /etc/cloudflared
printf 'TUNNEL_TOKEN=%s\n' 'PASTE_THE_TOKEN_HERE' | sudo tee /etc/cloudflared/tunnel.env >/dev/null
sudo chmod 0600 /etc/cloudflared/tunnel.env
```

Do **not** use `cloudflared service install <token>`: it writes the token into the
unit's `ExecStart`, and unit files are world-readable. This unit keeps it in the
0600 file above:

```bash
sudo tee /etc/systemd/system/cloudflared.service >/dev/null <<'EOF'
[Unit]
Description=Cloudflare Tunnel (Biblioteca)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cloudflared
Group=cloudflared
EnvironmentFile=/etc/cloudflared/tunnel.env
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
Restart=always
RestartSec=5
StateDirectory=cloudflared
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
MemoryMax=25%

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared
sudo journalctl -u cloudflared -n 20      # look for "Registered tunnel connection"
curl -sI https://your-shelf.YOUR-DOMAIN/ | head -1
```

Cloudflare's free plan caps request bodies at 100 MB — use the LAN or Funnel
address for anything bigger. Downloads are unlimited.

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

# the reading door is read-only even for you (expect 403)
curl -sS -o /dev/null -w '%{http_code}\n' -u reader:PASSWORD \
  -X DELETE 'http://biblioteca.local/books/.probe'

# ...and the manager door is not (expect 404: allowed, file just absent)
curl -sS -o /dev/null -w '%{http_code}\n' -u reader:PASSWORD \
  -X DELETE 'http://biblioteca.local/manager/.probe'

# the landing page is public
curl -sS 'http://biblioteca.local/' | head -5

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
sudo systemctl disable --now cloudflared; sudo rm -rf /etc/cloudflared /etc/systemd/system/cloudflared.service
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
