#!/bin/bash
# Print this devbox's full Tailscale DNS name (node name plus tailnet part, no
# https://, no trailing dot), e.g. devbox-general.tapir-perch.ts.net, so URLs
# can be built with $(./tsname.sh). Needs the Tailscale sidecar to be running
# (start the box with ./bash_in_dev_container.sh first).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ts() {
  sudo env DEV_BOX_WRAPPER=1 docker compose \
    -f docker-compose.yml -f docker-compose.tailscale.yml \
    exec -T tailscale "$@"
}

# --peers=false: only Self, so the first DNSName is this node's.
name=$(ts tailscale status --json --peers=false 2>/dev/null \
  | sed -n 's/^ *"DNSName": *"\([^"]*\)".*/\1/p' | head -n1 || true)
name=${name%.}

if [ -z "$name" ]; then
  echo "Tailscale not enabled or sidecar not running for this dir. Start it with ./bash_in_dev_container.sh" >&2
  exit 1
fi
echo "$name"
