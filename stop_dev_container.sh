#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Tear the container down (not just `stop`) so it doesn't linger in
# `docker ps -a`. Safe here since all persistent state lives in the bind
# mounts (./home, ./Everything), not in the container itself.
sudo env DEV_BOX_WRAPPER=1 docker compose down
