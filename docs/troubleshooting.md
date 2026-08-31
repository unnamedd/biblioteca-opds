# Troubleshooting

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

## No cover images in the catalogue

Expected with the default config. `no-thumb` is set because extracting EPUB
covers costs CPU on a 1 GHz Cortex-A53, and copyparty then emits the cover links
with an empty `href`:

```xml
<link rel="http://opds-spec.org/image/thumbnail" href="" type="image/jpeg"/>
```

To turn covers on, set `ENABLE_COVERS=1` in `library.env` and re-run
`scripts/10-system.sh` and `scripts/30-copyparty.sh` — or by hand:

```bash
sudo apt install -y python3-pil
sudo sed -i '/^  no-thumb$/d' /etc/copyparty.conf
sudo systemctl reload copyparty
```

The links then become `/books/....epub?dl&th=jf` and the cover is extracted on
first request. Watch the first browse after enabling it — that is when every
cover gets generated.

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
