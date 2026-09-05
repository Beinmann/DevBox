#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE="my-dev-box:latest"

# 1. Build the image only if it doesn't exist yet (reused across every
#    copy of this directory, since the image tag is fixed). Pass the actual
#    host UID/GID so the `dev` user inside the container matches the host
#    user, and files created in the container end up owned by you on the
#    host instead of some arbitrary container UID.
if ! sudo docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> Image $IMAGE not found, building..."
  sudo env DEV_BOX_WRAPPER=1 docker compose build \
    --build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)"
fi

# 2. Seed ./home from the image's baked-in /home/dev on first run only,
#    before the bind mount in docker-compose.yml would otherwise shadow it.
#    Also stamp a random 3-char instance ID (17576 combinations — not a real
#    uniqueness guarantee, just very unlikely to collide across the handful
#    of boxes this is meant to distinguish) so this box's $HOME is
#    identifiable, e.g. for a tmux session name or shell prompt.
if [ ! -d ./home ]; then
  echo "==> ./home not found, seeding it from the image's built-in /home/dev..."
  mkdir -p ./home
  echo "==> Starting temporary container to copy from..."
  tmp_container=$(sudo docker create "$IMAGE")
  sudo docker cp "$tmp_container:/home/dev/." ./home
  echo "==> Stopping temporary container..."
  sudo docker rm "$tmp_container" >/dev/null
  # docker cp preserves numeric ownership from the container, which should
  # already match the host user since the image was built with the host's
  # UID/GID (step 1) — but fall back to an explicit chown in case it doesn't
  # (e.g. an image built earlier with different build args was reused).
  sudo chown -R "$(id -u):$(id -g)" ./home
  # /dev/urandom never reaches EOF, so `head -c3` exiting early sends `tr`
  # a SIGPIPE, making it exit non-zero — which pipefail (combined with -e)
  # would otherwise treat as this whole script failing. Scope pipefail off
  # just for this command substitution's subshell.
  id=$(set +o pipefail; tr -dc 'a-z' < /dev/urandom | head -c3)
  echo "$id" > ./home/.devbox_id
  echo "==> Generated ID \"$id\" for the container. Saving under /home/dev/.devbox_id"
fi

# 3. Create ./Everything on first run if it doesn't exist yet.
if [ ! -d ./Everything ]; then
  echo "==> ./Everything not found, creating it..."
  mkdir -p ./Everything
fi

# 4. Bring the container up (creates + starts if missing, starts if
#    stopped, no-op if already running) and attach an interactive shell.
#    Re-running this script while the container is already up just
#    reattaches — no duplicate containers, no error.
sudo env DEV_BOX_WRAPPER=1 docker compose up -d
sudo env DEV_BOX_WRAPPER=1 docker compose exec my-dev-container bash
