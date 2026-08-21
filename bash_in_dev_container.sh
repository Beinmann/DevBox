#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE="my-dev-box:latest"

# 1. Build the image only if it doesn't exist yet (reused across every
#    copy of this directory, since the image tag is fixed).
if ! sudo docker image inspect "$IMAGE" >/dev/null 2>&1; then
  sudo env DEV_BOX_WRAPPER=1 docker compose build
fi

# 2. Seed ./root from the image's baked-in /root on first run only, before
#    the bind mount in docker-compose.yml would otherwise shadow it. Also
#    stamp a random 3-char instance ID (~46k combinations — not a real
#    uniqueness guarantee, just very unlikely to collide across the handful
#    of boxes this is meant to distinguish) so this box's $HOME is
#    identifiable, e.g. for a tmux session name or shell prompt.
if [ ! -d ./root ]; then
  mkdir -p ./root
  tmp_container=$(sudo docker create "$IMAGE")
  sudo docker cp "$tmp_container:/root/." ./root
  sudo docker rm "$tmp_container" >/dev/null
  { tr -dc 'a-z0-9' < /dev/urandom | head -c3; echo; } > ./root/.devbox_id
fi

# 3. Create ./Everything on first run if it doesn't exist yet.
mkdir -p ./Everything

# 4. Run the dev container as before.
sudo env DEV_BOX_WRAPPER=1 docker compose run --rm my-dev-container bash
