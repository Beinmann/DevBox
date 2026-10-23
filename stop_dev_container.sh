#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Tear the container down (not just `stop`) so it doesn't linger in
# `docker ps -a`. Safe here since all persistent state lives in the bind
# mounts (./home, ./Everything), not in the container itself.
# The Tailscale override is always included (with its /dev/null / "devbox"
# fallbacks) and --remove-orphans is set, so the sidecar and the default
# network go away too, whether or not Tailscale is currently enabled.
sudo env DEV_BOX_WRAPPER=1 docker compose \
  -f docker-compose.yml -f docker-compose.tailscale.yml down --remove-orphans
