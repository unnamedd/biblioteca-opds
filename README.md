# 📚 Biblioteca

A self-hosted OPDS library for devices running [CrossPoint Reader](https://github.com/crosspoint-reader/crosspoint-reader), hosted on a **Raspberry Pi Zero 2 W** (512 MB, 32-bit armv7, Raspbian bullseye).

- Browse and download books **on the reader**, at home and on your phone's hotspot.
- **Upload from your phone's browser** — drag an EPUB in, it is in the catalogue.
- Runs in about **100 MB of RAM**, no Docker, no database.
- Catalogue is filename-based — name files `Author - Title.epub`. Cover
  thumbnails are off by default to save CPU (`ENABLE_COVERS=1` turns them on).
- **A second, read-only account for friends** — they get their own password,
  browse and download the whole library (no copies, no separate folder), and
  cannot upload, rename or delete (`GUEST_ACCOUNT`).
- **Reading and administration are separate doors.** The reading path is
  read-only for *everyone*, you included, so your view is the same clean one
  your friends get; uploads and deletes live behind a second path.
- **Sleep-screen wallpapers on their own endpoint** — BMP and PXC for the
  reader's sleep screen, served separately so they never mix into the books.
- **Remote access is optional, per entrance.** Tailscale Funnel, a Cloudflare
  Tunnel on your own domain, both, or neither — LAN-only is a supported setup.
- **Nothing about the layout is stock.** The title, both paths and the listed
  formats are all configurable, so knowing this project doesn't tell an
  attacker where anything is.
- Starts at boot and restarts if it dies.

```
                    AT HOME                             AWAY
   reader ── WiFi ──┐                     reader ── phone hotspot ── internet
                    │                                       │
                    ▼                                       ▼
      http://biblioteca.local           https://<pi>.<tailnet>.ts.net
                    │                                       │
                    └─────────────────┬─────────────────────┘
                                      ▼
                                copyparty :80
                                      │
        ┌──────────────┬──────────────┴───────────┬──────────────────┐
        ▼              ▼                          ▼                  ▼
       /            /books/                 /wallpapers/         /manager/
  landing page  read-only: you           read-only: you          you only
  anyone,         and friends               and friends       ┌──────┴──────┐
  no login            │                          │            ▼             ▼
                      │                          │        /books/    /wallpapers/
                      │                          │            │             │
                      └──────────┬───────────────┼────────────┘             │
                                 ▼               └──────────┬───────────────┘
                           /srv/books                       ▼
                      (one folder, no copies)        /srv/wallpapers
                                                      (sleep screens)
```

## Quick start

On the Mac:

```bash
cp library.env.example library.env
$EDITOR library.env          # set PI_SSH at minimum
./deploy.sh                  # rsync to the Pi and run the installer
```

Or, straight on the Pi:

```bash
./install.sh                 # add --dry-run to see it without changing anything
./scripts/50-verify.sh       # checks everything, then prints the reader settings
```

`50-verify.sh` finishes by printing the exact rows to enter on the reader.
Then read [docs/reader-setup.md](docs/reader-setup.md).

## What is here

| path                      |                                              |
| ------------------------- | -------------------------------------------- |
| `install.sh`              | runs `00`→`40` in order, on the Pi           |
| `deploy.sh`               | Mac-side: rsync + ssh + install              |
| `scripts/00-preflight.sh` | checks every assumption, changes nothing     |
| `scripts/10-system.sh`    | packages, zram, service user, `/srv/books`   |
| `scripts/20-mdns.sh`      | publishes `biblioteca.local`                 |
| `scripts/30-copyparty.sh` | the OPDS + upload server, under systemd      |
| `scripts/40-tailscale.sh` | Funnel (interactive the first time)          |
| `scripts/45-cloudflare.sh`| short address on your own domain, optional   |
| `scripts/50-verify.sh`    | end-to-end assertions + the reader config    |
| `scripts/99-uninstall.sh` | reverses it all; keeps your books            |
| `config/`                 | the real config files, templated             |
| `config/landing/`         | the public landing page, templated           |
| `library.env.example`     | every setting, grouped by feature            |
| `docs/RUNBOOK.md`         | **every step by hand**, 1:1 with the scripts |
| `docs/reader-setup.md`    | what to enter on the device                  |
| `docs/troubleshooting.md` | symptom → cause → fix                        |

Every script is idempotent, safe to re-run, and takes `--dry-run`.

Settings live in `library.env` (copy from `library.env.example`). It holds the
password and is **gitignored**.

## Why these choices

The reader is not a small computer — it is a **microcontroller**. CrossPoint runs
on ESP32-class hardware, where RAM is measured in hundreds of kilobytes: on the
ESP32-C3 the firmware has **~380 KB** to work with. Three consequences drive the
whole design:

1. **It cannot run Tailscale.** So the common advice to use `tailscale serve`
   fails here: the reader is not in the tailnet. Putting Tailscale on the phone
   does not help either: a phone does not route its tethered hotspot clients
   through its own VPN tunnel — they get the plain cellular connection
   ([tailscale#14980](https://github.com/tailscale/tailscale/issues/14980)).
   **Tailscale Funnel** is what actually works — public HTTPS, password-protected.
   The other way to get a publicly-trusted certificate without opening a port
   is a **Cloudflare Tunnel**, which also gives you a short name on your own
   domain — at the price of Cloudflare terminating TLS and seeing the traffic,
   passwords included, where Funnel relays only ciphertext. Both are optional
   and independent (`TAILSCALE_ENABLED`, `CLOUDFLARE_ENABLED`).

2. **It verifies TLS against bundled CA roots.** From the firmware's
   `src/network/HttpDownloader.cpp`: _"the model is public servers over verified
   https and local servers over plain http"_. A self-signed certificate would be
   rejected; Funnel's Let's Encrypt certificate is fine. It also sends HTTP Basic
   auth preemptively, which is how the public URL stays private.

3. **The firmware already gets on with copyparty.** CrossPoint 1.3.0's changelog
   records an OPDS fix for _"relative paths and query parameters (fixing
   CopyParty compatibility)"_.

**copyparty** does the OPDS catalogue, the phone upload UI, and authentication
in one dependency-free Python file — which is also what makes it work on 32-bit
armv7, where Node 22 and Bun are unavailable and so `bun-opds-server` is off the
table. Calibre-Web, Kavita, Komga and Stump all want more RAM than this board
has; `kopds` idles at ~90 MB and needs a Calibre database; `dir2opds` is lovely
and tiny but has no authentication, so it cannot face the internet without a
proxy in front.

## Requirements

- Raspberry Pi running Debian/Raspbian with systemd (developed against
  bullseye/armv7; 64-bit works too)
- For access away from home, at least one of: a Tailscale account (MagicDNS
  and HTTPS certificates enabled), or a domain whose DNS is hosted at
  Cloudflare. Neither is needed for LAN-only use.
- CrossPoint firmware **≥ 1.3.0**

## Credits

Biblioteca is mostly glue. The work is done by other people's software:

| project                                                                                     | what it does here                                                                                   | licence      |
| ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ------------ |
| [copyparty](https://github.com/9001/copyparty)                                              | the whole server — OPDS catalogue, upload UI, accounts, WebDAV — in one dependency-free Python file | MIT          |
| [Tailscale](https://github.com/tailscale/tailscale)                                         | the tailnet, and Funnel for the public HTTPS path with its Let's Encrypt certificate                | BSD-3-Clause |
| [Avahi](https://github.com/avahi/avahi)                                                     | publishes the `biblioteca.local` name on the LAN                                                    | LGPL-2.1     |
| [zram-tools](https://github.com/highvoltage/zram-tools)                                     | compressed swap, so 512 MB goes further                                                             | ISC          |
| [CrossPoint Reader](https://github.com/crosspoint-reader/crosspoint-reader)                 | the e-reader firmware this serves; its OPDS client is what made copyparty the obvious choice        | MIT          |
| [Raspberry Pi OS](https://www.raspberrypi.com/software/) / [Debian](https://www.debian.org) | the host                                                                                            | various      |

Also worth naming: the [OPDS](https://specs.opds.io/) specification, which is
why a small e-ink reader and a Python file can talk to each other at all.

## Licence

MIT — see [LICENSE](LICENSE).
