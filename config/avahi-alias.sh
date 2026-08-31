#!/usr/bin/env bash
# Publish <name>.local as an mDNS A record pointing at this host's current
# primary IPv4. Resolving the address at start (rather than hardcoding it)
# means a reboot onto a new DHCP lease still publishes the right thing.
#
# avahi-publish stays in the foreground for as long as the record should
# exist, which is exactly what systemd Type=simple wants.

set -euo pipefail

ALIAS="${1:?usage: avahi-alias.sh <name-without-.local>}"

ip_of_default_route() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i+1); exit } }'
}

IP="$(ip_of_default_route || true)"

if [ -z "${IP:-}" ]; then
  echo "avahi-alias: no primary IPv4 yet; is the network up?" >&2
  exit 1
fi

echo "avahi-alias: publishing ${ALIAS}.local -> ${IP}"

# -a = publish an address (A) record
# -R = do not publish the reverse PTR record, which would collide with the
#      host's real hostname since both names share one IP
exec /usr/bin/avahi-publish -a -R "${ALIAS}.local" "${IP}"
