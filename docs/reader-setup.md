# 📚 Setting up the reader

Applies to the Xteink X3 / X4 / X4 Pro running CrossPoint. Requires firmware
**≥ 1.3.0** — that release fixed OPDS handling of relative paths and query
parameters specifically for copyparty. X4 Pro support landed in 1.6.0rc, so if
you have an X4 Pro you are already well past it.

## Getting to the settings

Typing URLs on the device is miserable. Don't.

1. On the reader, start **File Transfer** mode. It shows an IP address.
2. On your Mac or phone, open `http://<device-ip>/settings` — or
   `http://crosspoint.local/settings`, which works while the reader is awake and
   on the same Wi-Fi.
3. The page has cards for **Wi-Fi Networks** and **OPDS Servers**.

The on-device path is **Settings → System → OPDS Servers → Add Server** if you
prefer.

Note the device's own web server has **no authentication** and runs plain HTTP
on port 80 — fine on your LAN, but don't expose it.

## The two OPDS entries

CrossPoint stores up to **8** OPDS servers, so keep both and switch as needed.

### Home — fast, over the LAN

| field | value |
|---|---|
| Name | `Home` |
| URL | `http://biblioteca.local/books/?opds` (or your `BOOKS_ENDPOINT`) |
| Username | `reader` |
| Password | (from `library.env`) |

Plain HTTP is correct here. The firmware's model is, in its own words, *"public
servers over verified https and local servers over plain http"*.

If `.local` does not resolve on the reader, use the Pi's IP instead —
`http://192.168.x.x/books/?opds` — and set a DHCP reservation on your router so
the address stops moving.

### Away — over Tailscale Funnel

| field | value |
|---|---|
| Name | `Away` |
| URL | `https://<pi>.<tailnet>.ts.net/books/?opds` |
| Username | `reader` |
| Password | (same) |

This is the one you use with the reader on your phone's hotspot. It works
because Funnel presents a publicly-trusted Let's Encrypt certificate, and the
firmware verifies HTTPS against its bundled CA roots. A self-signed certificate
would be rejected.

Passwords are hidden after saving; leaving the field blank on a later edit keeps
the existing one.

## Sleep-screen wallpapers

The wallpapers live behind their own OPDS feed, so add a **second** OPDS server
on the reader (CrossPoint stores up to 8):

| field | value |
|---|---|
| Name | `Wallpapers` |
| URL | `http://biblioteca.local/wallpapers/?opds` (or your `WALLPAPERS_ENDPOINT`) |
| Username / Password | the same account you use for books |

Then: browse that catalogue, download an image, open it in **Browse Files**, and
set it as the sleep cover from the image viewer. It does not need to be in
`/.sleep` — the viewer can set any BMP it can open.

What to put in `/srv/wallpapers` (upload at `/manager/wallpapers/`):

- **BMP** at exactly **480×800** for the X4, **528×792** for the X3.
- **PXC**, CrossPoint's native wallpaper format — about a tenth the size of a
  24-bit BMP, which matters when you are pulling it over Funnel on a device
  with 380 KB of RAM.
- **PNG is not listed**, on purpose: the reader cannot open a standalone PNG,
  so it would only appear as an entry that fails when tapped. PNGs you store
  there stay visible and downloadable from a browser, which is handy for
  keeping the source image next to the converted one.

## Other settings worth changing

- **Background Server → Only on Charge.** Keeps the reader reachable for
  wireless transfers without eating the battery. `Always` works too but costs
  more power.

## Uploading books from your phone

Open `http://biblioteca.local/manager/books/` in the phone's browser (or the
`https://<pi>.<tailnet>.ts.net/manager/books/` URL when away), log in with your
own account, and drag the book in. **Note the path**: `/books/` is the reading
door and is read-only for everyone, you included — uploads there return 403.
`/manager/` is the one that accepts them. It appears in the OPDS feed immediately — there
is no import step, because the catalogue is just the folder.

Name files `Author - Title.epub`. The catalogue is filename-based, so the
filename *is* the entry you will be reading in the OPDS browser.

`/srv/books` subfolders become catalogue subfolders, so a little structure
(`Fiction/`, `Tech/`) goes a long way.
