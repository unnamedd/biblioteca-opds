# 📚 Troubleshooting

## `biblioteca.local` does not resolve

**From the Mac.** Check the record is being published at all:

```bash
dns-sd -G v4 biblioteca.local     # ctrl-C to stop
```

**On the Pi:**

```bash
systemctl status avahi-alias@biblioteca
journalctl -u avahi-alias@biblioteca -n 50
getent hosts biblioteca.local
```

The wrapper logs the IP it published. If it exited with *"no primary IPv4 yet"*
it started before the network was up; `Restart=always` should have recovered it,
so check whether it is flapping.

If the Pi's IP changed since boot, restart the unit — it re-resolves at start:

```bash
sudo systemctl restart avahi-alias@biblioteca
```

A DHCP reservation on the router prevents this permanently.

**From the reader.** lwIP resolves `.local` through one-shot mDNS queries, and
`CONFIG_LWIP_DNS_SUPPORT_MDNS_QUERIES` defaults to on in ESP-IDF and is enabled
in arduino-esp32 (which CrossPoint builds against). So it should work — but if
it doesn't, this is the fallback: change the Home entry to the Pi's raw IP,
`http://192.168.x.x/books/?opds`. Nothing else in the setup depends on the name.

Some routers with AP isolation or aggressive IGMP snooping block multicast
between wireless clients, which breaks mDNS for everyone on the LAN.

## copyparty will not start

```bash
systemctl status copyparty --no-pager
journalctl -u copyparty -n 50
```

- **`Permission denied` binding port 80** — the unit lost
  `AmbientCapabilities=CAP_NET_BIND_SERVICE`, or something else already owns
  the port: `sudo ss -ltnp 'sport = :80'`.
- **Config parse errors** — `/etc/copyparty.conf` is line-oriented and
  indentation-sensitive. Nested keys under `accs:` / `flags:` need to stay
  indented deeper than their parent.
- **Cannot read the config** — it is `0640 root:copyparty`; if you changed
  `SERVICE_USER` the group no longer matches.

## The reader shows an empty catalogue

- Is there anything in `/srv/books`? `ls -la /srv/books`
- `--opds-exts` defaults to `epub,cbz,pdf`. A `.mobi` or `.azw3` will not be
  listed until you add it: `opds-exts: epub,cbz,pdf,mobi,azw3` in `[global]`.
- Files must be readable by the `copyparty` user:
  `sudo chown -R copyparty:copyparty /srv/books`
- Check the feed by hand:
  `curl -u reader:PASS 'http://biblioteca.local/books/?opds'`

## Deleting (or renaming) a file fails

The web UI shows an error and WebDAV returns `403 'delete' not allowed for user
<name>`. The account is missing the permission — copyparty's letters are
granted explicitly:

| letter | grants |
| ------ | ------ |
| `r` | list folders, download files |
| `w` | upload files |
| `m` | move / rename |
| `d` | delete permanently |
| `A` | shorthand for `rwmda.` — the above plus admin and dotfiles |

`rw` alone can upload but never remove, which is easy to miss because uploading
works fine. Fix it in `/etc/copyparty.conf`:

```ini
[/books]
  /srv/books
  accs:
    rwmd: <your account>
```

then `sudo systemctl reload copyparty` (the unit reloads on `SIGUSR1`, so no
restart is needed). Re-running `scripts/30-copyparty.sh` does the same thing
from the template and keeps the Pi reproducible.

## Which door am I supposed to use?

Biblioteca serves one folder through three URLs, so that reading never shows
you administrative controls:

| path | login | what you get |
| ---- | ----- | ------------ |
| `/` | none | the landing page |
| `/<BOOKS_ENDPOINT>` | you or a guest | browse, download, OPDS — **read-only for everyone** |
| `/<MANAGER_ENDPOINT>` | you only | upload, rename, delete |

`BOOKS_ENDPOINT` and `MANAGER_ENDPOINT` live in `library.env` and default to `books`
and `manager`. Change them: Biblioteca is open source, so the stock layout is
public knowledge, and picking your own names means someone scanning for a known
project finds nothing at the obvious URLs. It is obscurity layered on top of the
passwords, not a replacement for them.

`/<MANAGER_ENDPOINT>/` is a container, not a folder: it lists exactly two
children and accepts no uploads itself, so a mistyped path cannot dump a file
beside them.

| upload this | to here |
| ----------- | ------- |
| books | `/<MANAGER_ENDPOINT>/books/` |
| wallpapers | `/<MANAGER_ENDPOINT>/wallpapers/` |

If uploading suddenly returns **403**, you are on the reading door or on the
container itself. Go one level in.

## Sharing the library with friends

Give them their own read-only account rather than your password. Set in
`library.env`:

```ini
GUEST_ACCOUNT=friends
GUEST_PASSWORD=          # blank -> generated, printed once, saved back here
```

then re-run `scripts/30-copyparty.sh`. It renders:

```ini
[accounts]
  reader: <your password>
  friends: <their password>

[/books]                 # the reading door: read-only for EVERYONE
  /srv/books
  accs:
    r: friends
    r: reader
  flags:
    opds
    hist: /var/lib/copyparty/hist/books

[/manager]               # the management door: you alone
  /srv/books
  accs:
    rwmd: reader
  flags:
    hist: /var/lib/copyparty/hist/manager
```

Nothing is copied and no second folder is needed — one folder, two doors.
Verified behaviour:

| action | anonymous | `friends` | you via `/books` | you via `/manager` |
| ------ | --------- | --------- | ---------------- | ------------------ |
| browse the OPDS feed | 403 | **200** | 200 | 200 |
| download a book | 403 | **200** | 200 | 200 |
| upload | 401 | **401** | **403** | 201 |
| delete | 401 | **401** | **403** | 200 |
| rename | 401 | **401** | **403** | 201 |

That `403` column is deliberate: the reading door is read-only for you too, so
your view is identical to your friends'. Uploads and deletes go to `/manager`.

Friends can point their own OPDS apps at the same URL. To revoke, clear
`GUEST_ACCOUNT` and re-run the script; your own login is unaffected.

`scripts/50-verify.sh` checks all three identities, so a mistake that hands your
friends write access fails the run instead of going unnoticed.

**If you ever want no password at all** for readers, `r: *` in place of
`r: friends` opens the library to everyone. Think twice with Funnel on: that
means the public internet, and Funnel hostnames are published to Certificate
Transparency logs, so the address is discoverable rather than secret.

## A wallpaper does not show up on the reader

Wallpapers are a separate feed. Check, in order:

1. **Is it in the right place?** They live in `WALLPAPERS_DIR`
   (`/srv/wallpapers`), not in the books folder. Upload at
   `/<MANAGER_ENDPOINT>/wallpapers/`.
2. **Is the format listed?** `WALLPAPERS_EXTS` defaults to `bmp,pxc`. A `.png`
   is stored but deliberately not listed — the reader cannot open a standalone
   PNG, so an entry for it would only fail when tapped. Convert it first.
3. **Did you add the second OPDS server?** The books feed will never show
   wallpapers; that is the point. The reader needs its own entry pointing at
   `/<WALLPAPERS_ENDPOINT>/?opds`.
4. **Are the dimensions right?** 480×800 on the X4, 528×792 on the X3. A
   wrong-sized BMP may open but look wrong as a sleep screen.
5. **Is the feature on?** `WALLPAPERS_ENABLED=0` renders neither volume, and
   `/<WALLPAPERS_ENDPOINT>/` returns 404.

To set one: open it in **Browse Files** on the reader and choose "set as sleep
screen" from the image viewer. It does not have to be in `/.sleep`.

## No cover images in the catalogue

Expected with the default config, and it is the `no-thumb` flag rather than a
missing package: with the thumbnailer off, copyparty still emits the cover links
but leaves the `href` empty:

```xml
<link rel="http://opds-spec.org/image/thumbnail" href="" type="image/jpeg"/>
```

Covers need **one** thumbnail backend, not specifically pillow: copyparty
lists `epub` under both `--th-r-pil` (pillow) and `--th-r-ffi` (ffmpeg). Check
what you already have before installing anything —

```bash
command -v ffmpeg && echo "already covered"
```

— and read copyparty's own verdict in the log:

```bash
journalctl -u copyparty | grep optional-dependencies
```

Pi OS Lite ships neither backend; `python3-pil` is much the smaller of the two.

To turn covers on, set `ENABLE_COVERS=1` in `library.env` and re-run
`scripts/10-system.sh` and `scripts/30-copyparty.sh` — or by hand:

```bash
sudo apt install -y python3-pil      # skip if ffmpeg is already present
sudo sed -i '/^  no-thumb$/d' /etc/copyparty.conf
sudo systemctl reload copyparty
```

The links then become `/books/....epub?dl&th=jf`. copyparty unpacks the EPUB and
thumbnails the cover it finds (`--au-unpk` maps `epub=jpg.epub`); PNG and JPEG
covers both work. Each result is cached under `hist`, so a book is decoded once,
not on every view — the first browse after enabling is the slow one.

## The reader says the password is wrong, then nothing works at all

copyparty bans an IP after **9 wrong passwords in 60 minutes, for 24 hours**.
Typing a long password on the reader makes this easy to trigger.

While setting up, disable it — add to `[global]` in `/etc/copyparty.conf`:

```
  ban-pw: no
```

then `sudo systemctl reload copyparty`. Put it back once everything works;
the URL is publicly reachable through Funnel, so the ban is real protection.

copyparty's own documentation notes that some e-reader clients omit credentials
when fetching OPDS cover images, which can trip the ban even when your password
is correct.

## Funnel: works at home, fails on the hotspot

First, confirm you are actually testing the public path. On the Pi, MagicDNS
resolves the `ts.net` name to the tailnet address, so a `curl` from the Pi does
**not** prove public reachability. Force the public address:

```bash
TS=$(sudo tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
IP=$(curl -sS -H 'accept: application/dns-json' \
      "https://cloudflare-dns.com/dns-query?name=$TS&type=A" \
      | python3 -c 'import json,sys; print(next(a["data"] for a in json.load(sys.stdin)["Answer"] if a["type"]==1))')
curl -v --resolve "$TS:443:$IP" "https://$TS/books/?opds"
```

Then:

```bash
sudo tailscale funnel status
sudo tailscale status
```

- Funnel needs **HTTPS certificates enabled** for the tailnet and a `funnel`
  node attribute in the policy file. The CLI normally adds both; check the
  admin console if `funnel status` is empty.
- Funnel only listens on **443, 8443, 10000**.
- A port cannot be Serve and Funnel simultaneously — whichever command ran last
  wins. `sudo tailscale funnel reset` and re-apply if the state is confused.
- Re-issuing certificates too often hits Let's Encrypt rate limits, which means
  a ~34 hour wait. Don't loop on `tailscale cert`.

## A big EPUB fails over Funnel but downloads fine at home

This is the memory ceiling on the reader, not a server problem. The ESP32-C3 has
~380 KB of usable RAM, and the firmware explicitly frees ~65 KB of EPUB heap
before a TLS handshake, because handshakes on large books used to run the
device out of memory.

Workaround: download that book over the LAN entry instead, or from your phone
and sideload it via the reader's own upload UI.

## The reader cannot reach the Pi at all on the hotspot

Expected, if you were relying on Tailscale on the phone. A phone does **not**
route its tethered hotspot clients through its own VPN tunnel
([tailscale#14980](https://github.com/tailscale/tailscale/issues/14980)), so a
tailnet-only URL is unreachable from the reader. That is the entire reason this
setup uses Funnel rather than `tailscale serve`.

It is also expected when **both** `TAILSCALE_ENABLED` and `CLOUDFLARE_ENABLED`
are `0`: that is LAN-only by configuration. Turn one on and re-run the
installer; `scripts/50-verify.sh` says which Away URL applies.

## The short address (Cloudflare) does not answer

Work down the chain:

- **Cloudflare error 1033 / "tunnel not found"** — the connector is not
  registered. `sudo journalctl -u cloudflared -n 40`: no *Registered tunnel
  connection* means the token is wrong or the service is down. The token is in
  `/etc/cloudflared/tunnel.env`; re-run `scripts/45-cloudflare.sh` after fixing
  `library.env`.
- **It redirects somewhere else entirely** — a *Redirect Rule* matching
  **All incoming requests** runs at Cloudflare's edge before anything reaches
  the tunnel, and it applies to every hostname in the zone, the new one
  included; a rule sending the bare domain to some other site is the usual
  culprit. Edit the rule and switch it to a *Custom filter expression* scoped
  to the names it was meant for:
  `(http.host eq "<domain>") or (http.host eq "www.<domain>")`.
  `50-verify.sh` reports this case explicitly.
  After fixing it, a browser that visited the name *before* the fix may keep
  redirecting: it cached the **301**, which means "permanent". `curl -I` will
  show the truth. Confirm in a private window, then clear that site's data in
  the browser.
- **502 Bad Gateway from Cloudflare** — the tunnel is up but nothing answers on
  the Pi. `systemctl status copyparty`, and in the dashboard check the Public
  Hostname's *Service* is `http://localhost:<SERVER_PORT>` (not https, not the
  LAN IP).
- **The reader rejects the certificate** — it verifies against bundled CA
  roots. Cloudflare's chain (Google Trust Services / Let's Encrypt) is in
  ESP-IDF's bundle, but confirm what is actually served:
  `openssl s_client -connect your-shelf.<domain>:443 -servername your-shelf.<domain>
  </dev/null | openssl x509 -noout -ext subjectAltName`. Expect `*.<domain>`
  — that wildcard is also why the name is not in CT logs.
- **An upload fails only through the short address** — Cloudflare's free plan
  caps request bodies at 100 MB. Use the LAN or Funnel address for that file.

Funnel keeps working independently, so a Cloudflare outage never locks you
out — that is why the plan keeps both.

## Browser login says "rejected by cors-check", but only through one tunnel

copyparty's CSRF check compares the browser's `Origin` with the scheme and host
it believes it is serving. Behind a proxy it derives those from
`X-Forwarded-Proto` and `Host` — **but only when the proxy's own address is in
`xff-src`**. From any other peer the forwarded headers are ignored, the request
looks like plain `http://`, and every browser login fails. Non-browser clients
send no `Origin`, so the reader and `curl` keep working — which is why OPDS
works while the login page does not.

The usual cause: the tunnel service is `localhost:80`, `localhost` resolves to
`::1` as well as `127.0.0.1`, and `xff-src` names only `127.0.0.1`. Confirm in
the log:

```bash
sudo journalctl -u copyparty | grep -m1 'untrusted source'
#  ... untrusted source "::1" claiming the true client ip is "..."
```

Fix: `xff-src: 127.0.0.0/8, ::1/128` in `/etc/copyparty.conf` (the template's
current value), then `sudo systemctl reload copyparty`. The same misconfiguration
also makes `ban-pw` ban the loopback address — everyone through that tunnel at
once — so this is worth fixing even if you never use the login page.

## Everyone is banned at the same time

copyparty's `ban-pw` bans by client IP. Behind a tunnel every request reaches
copyparty from `127.0.0.1`, so the real IP has to come from a header. If the
header *name* copyparty reads (`xff-hdr`) does not match what the proxy sends,
every visitor looks like `127.0.0.1`, and one wrong password bans all of them —
you included. Both Funnel and Cloudflare send `X-Forwarded-For`, so
`xff-hdr: x-forwarded-for` is correct for both; do not change it to
`cf-connecting-ip`.

`rproxy: -1` matters too: Cloudflare *appends* the real client to that header,
so the rightmost entry is the true one. With `rproxy: 1` an attacker seeding the
header could dodge the ban by changing the seed.

Bans live in memory: `sudo systemctl restart copyparty` clears them.

## Out of memory / the Pi grinds

```bash
free -m
journalctl -k --since '1 hour ago' | grep -i oom
systemctl status copyparty
```

Expected steady state is roughly OS ~70 MB + tailscaled ~40 MB + copyparty
~60 MB out of 426 MB. If copyparty is much larger, an indexing run is probably
in progress; `e2d` alone is cheap, but `-e2ts` (metadata scanning) is not — do
not enable it.

`MemoryMax=50%` in the unit caps copyparty at ~213 MB so a runaway upload cannot
take the whole machine down with it.
