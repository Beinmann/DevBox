#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE="my-dev-box:latest"

# 1. Build the image only if it doesn't exist yet (reused across every
#    copy of this directory, since the image tag is fixed).
if ! sudo docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> Image $IMAGE not found, building..."
  sudo env DEV_BOX_WRAPPER=1 docker compose build
fi

# 2. Seed ./root from the image's baked-in /root on first run only, before
#    the bind mount in docker-compose.yml would otherwise shadow it. Also
#    stamp a random 3-char instance ID (17576 combinations — not a real
#    uniqueness guarantee, just very unlikely to collide across the handful
#    of boxes this is meant to distinguish) so this box's $HOME is
#    identifiable, e.g. for a tmux session name or shell prompt.
if [ ! -d ./root ]; then
  echo "==> ./root not found, seeding it from the image's built-in /root..."
  mkdir -p ./root
  echo "==> Starting temporary container to copy from..."
  tmp_container=$(sudo docker create "$IMAGE")
  sudo docker cp "$tmp_container:/root/." ./root
  echo "==> Stopping temporary container..."
  sudo docker rm "$tmp_container" >/dev/null
  # /dev/urandom never reaches EOF, so `head -c3` exiting early sends `tr`
  # a SIGPIPE, making it exit non-zero — which pipefail (combined with -e)
  # would otherwise treat as this whole script failing. Scope pipefail off
  # just for this command substitution's subshell.
  id=$(set +o pipefail; tr -dc 'a-z' < /dev/urandom | head -c3)
  echo "$id" > ./root/.devbox_id
  echo "==> Generated ID \"$id\" for the container. Saving under /root/.devbox_id"
fi

# 3. Create ./Everything on first run if it doesn't exist yet.
if [ ! -d ./Everything ]; then
  echo "==> ./Everything not found, creating it..."
  mkdir -p ./Everything
fi

# 4. Run the dev container as before.
sudo env DEV_BOX_WRAPPER=1 docker compose run --rm my-dev-container bash
