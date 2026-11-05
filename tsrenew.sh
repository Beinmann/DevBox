#!/bin/bash
# Re-register this devbox's Tailscale node after the registration ran out
# (long-running box, PC sleep) without restarting the box. The sidecar also
# does this by itself every ~30 s; use this to do it right now. Re-applies the
# saved HTTPS ports afterwards. Needs the sidecar to be running.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if ! sudo env DEV_BOX_WRAPPER=1 docker compose \
    -f docker-compose.yml -f docker-compose.tailscale.yml \
    exec -T tailscale /usr/local/bin/tailscale-renew.sh --force; then
  echo "Renewal failed. Tailscale not enabled or sidecar not running for this dir? Restart with ./stop_dev_container.sh and ./bash_in_dev_container.sh" >&2
  exit 1
fi
[ -s ./https-ports ] && ./tsports.sh --apply || true
./tsname.sh
