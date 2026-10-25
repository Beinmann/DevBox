#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE="my-dev-box-v2"

# 1. Export the host UID/GID for docker-compose.yml's build.args to pick
#    up, in case Compose actually needs to build below (image missing, e.g.
#    first run or after ./rebuild_image_after_change.sh). We deliberately do
#    NOT force a `docker compose build` here: `--pull never` (passed below on
#    every compose invocation) already makes `up -d` build once when the
#    image is missing and just reuse the cached local image otherwise —
#    forcing a build on every start defeats that and was a mistake (see git
#    history). Rebuilding after a Dockerfile change is
#    ./rebuild_image_after_change.sh's job, not this script's.
export USER_UID="$(id -u)"
export USER_GID="$(id -g)"

# 1b. Optional host-side secrets file (KEY=VALUE lines, e.g.
#     CLAUDE_CODE_OAUTH_TOKEN=... from `claude setup-token`). Kept outside
#     the repo and ./home, passed to the container via compose's env_file.
#     Only takes effect when the container is (re)created, so run
#     ./stop_dev_container.sh first after changing it.
DEVBOX_ENV_FILE="${DEVBOX_ENV_FILE:-$HOME/.config/devbox/env}"
if [ -f "$DEVBOX_ENV_FILE" ]; then
  perms=$(stat -c %a "$DEVBOX_ENV_FILE")
  if [ "$perms" != "600" ] && [ "$perms" != "400" ]; then
    echo "==> Warning: $DEVBOX_ENV_FILE has mode $perms; run: chmod 600 $DEVBOX_ENV_FILE" >&2
  fi
else
  # No token file yet: offer to create one, unless the user opted out
  # earlier (marker file) or there's no terminal to ask on.
  NO_PROMPT_MARKER="$(dirname "$DEVBOX_ENV_FILE")/no-token-prompt"
  if [ -t 0 ] && [ ! -e "$NO_PROMPT_MARKER" ]; then
    echo "==> No token file found at $DEVBOX_ENV_FILE."
    echo "    Without it, Claude Code asks you to log in in every devbox."
    echo "    (Create a token on the host with: claude setup-token)"
    echo "    1) Enter a token now (saved to that file, mode 600)"
    echo "    2) Skip for this run"
    echo "    3) Continue and don't ask again"
    echo "    4) Cancel"
    while :; do
      read -rp "    Choice [1-4]: " choice
      case "$choice" in
        1)
          read -rsp "    Token (input hidden): " token; echo
          if [ -z "$token" ] || [[ "$token" =~ [[:space:]] ]]; then
            echo "    Empty or contains whitespace, try again." >&2
            continue
          fi
          mkdir -p "$(dirname "$DEVBOX_ENV_FILE")"
          chmod 700 "$(dirname "$DEVBOX_ENV_FILE")"
          (umask 077; printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$token" > "$DEVBOX_ENV_FILE")
          unset token
          echo "==> Saved to $DEVBOX_ENV_FILE."
          echo "    Only applies when the container is (re)created; if it's already running,"
          echo "    run ./stop_dev_container.sh and start again."
          break ;;
        2) break ;;
        3)
          mkdir -p "$(dirname "$NO_PROMPT_MARKER")"
          touch "$NO_PROMPT_MARKER"
          echo "==> Won't ask again (delete $NO_PROMPT_MARKER to re-enable)."
          break ;;
        4) echo "==> Cancelled."; exit 0 ;;
        *) echo "    Please enter 1, 2, 3 or 4." >&2 ;;
      esac
    done
  fi
  [ -f "$DEVBOX_ENV_FILE" ] || DEVBOX_ENV_FILE=/dev/null
fi
export DEVBOX_ENV_FILE

# 1c. Optional Tailscale sidecar (see README, "Reaching servers over
#     Tailscale"). The OAuth client secret lives in a host-global file
#     outside the repo and ./home, so it is asked for once for all boxes and
#     clones; a marker file records "no, don't ask again". Without a file the
#     box starts exactly as before. Only takes effect when the container is
#     (re)created.
TS_ENV_FILE="${TAILSCALE_ENV_FILE:-$HOME/.config/devbox/tailscale.env}"
TS_NO_PROMPT_MARKER="$(dirname "$TS_ENV_FILE")/no-tailscale-prompt"
if [ ! -f "$TS_ENV_FILE" ] && [ -t 0 ] && [ ! -e "$TS_NO_PROMPT_MARKER" ]; then
  echo "==> Tailscale is not set up (no $TS_ENV_FILE)."
  echo "    With it, each devbox joins your tailnet as devbox-<name> and its"
  echo "    ports (even localhost-only ones) are reachable from your other devices."
  echo "    Needs a one-time tailnet setup first, see README."
  echo "    1) Enter the OAuth client secret now (saved to that file, mode 600)"
  echo "    2) Skip for this run"
  echo "    3) Continue and don't ask again"
  echo "    4) Cancel"
  while :; do
    read -rp "    Choice [1-4]: " choice
    case "$choice" in
      1)
        read -rsp "    OAuth client secret (input hidden): " secret; echo
        if [ -z "$secret" ] || [[ "$secret" =~ [[:space:]?] ]]; then
          echo "    Empty or contains whitespace/'?', try again (paste the bare secret)." >&2
          continue
        fi
        if [[ "$secret" != tskey-client-* ]]; then
          echo "    Not an OAuth client secret (should start with tskey-client-), try again." >&2
          continue
        fi
        mkdir -p "$(dirname "$TS_ENV_FILE")"
        chmod 700 "$(dirname "$TS_ENV_FILE")"
        (umask 077; printf 'TS_AUTHKEY=%s?ephemeral=true&preauthorized=true\n' "$secret" > "$TS_ENV_FILE")
        unset secret
        echo "==> Saved to $TS_ENV_FILE."
        break ;;
      2) break ;;
      3)
        mkdir -p "$(dirname "$TS_NO_PROMPT_MARKER")"
        touch "$TS_NO_PROMPT_MARKER"
        echo "==> Won't ask again (delete $TS_NO_PROMPT_MARKER to re-enable)."
        break ;;
      4) echo "==> Cancelled."; exit 0 ;;
      *) echo "    Please enter 1, 2, 3 or 4." >&2 ;;
    esac
  done
fi
COMPOSE_FILES=(-f docker-compose.yml)
TS_ENABLED=""
TS_HOSTNAME=""
if [ -f "$TS_ENV_FILE" ]; then
  perms=$(stat -c %a "$TS_ENV_FILE")
  if [ "$perms" != "600" ] && [ "$perms" != "400" ]; then
    echo "==> Warning: $TS_ENV_FILE has mode $perms; run: chmod 600 $TS_ENV_FILE" >&2
  fi
  COMPOSE_FILES+=(-f docker-compose.tailscale.yml)
  TS_ENABLED=1
  # Node name: devbox-<short name>. The short name is asked for once per
  # devbox dir and kept in ./.devbox-tailscale-name (delete it to be asked
  # again).
  mkdir -p -m 700 ./tailscale-state
  # lowercase a-z0-9-, runs of other chars become one hyphen, trimmed, max 40
  ts_sanitize() {
    printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' \
      | cut -c1-40 | sed 's/-$//'
  }
  ts_short=$(ts_sanitize "$(basename "$PWD")")
  [ "$ts_short" != devbox ] || ts_short=$(ts_sanitize "$(basename "$(dirname "$PWD")")")
  [ -n "$ts_short" ] || ts_short=box
  ts_saved=$(ts_sanitize "$(cat ./.devbox-tailscale-name 2>/dev/null || true)")
  if [ -n "$ts_saved" ]; then
    ts_short=$ts_saved
  elif [ -t 0 ]; then
    while :; do
      echo "==> Node name will be: devbox-${ts_short}"
      read -rp "    Enter to accept, or type another short name: " ts_input
      [ -n "$ts_input" ] || break
      ts_new=$(ts_sanitize "$ts_input")
      if [ -z "$ts_new" ]; then
        echo "    Use letters, digits and hyphens." >&2
        continue
      fi
      ts_short=$ts_new
    done
    echo "$ts_short" > ./.devbox-tailscale-name
    echo "    Saved in ./.devbox-tailscale-name (delete it to be asked again; renaming"
    echo "    recreates the sidecar and the box)."
  fi
  TS_HOSTNAME="devbox-${ts_short}"
  echo "==> Tailscale enabled, node name: $TS_HOSTNAME"
else
  TS_ENV_FILE=/dev/null
fi
export TS_ENV_FILE TS_HOSTNAME

# 2. Seed ./home from the image's baked-in /home/dev on first run only,
#    before the bind mount in docker-compose.yml would otherwise shadow it.
#    Also stamp a random 3-char instance ID (17576 combinations — not a real
#    uniqueness guarantee, just very unlikely to collide across the handful
#    of boxes this is meant to distinguish) so this box's $HOME is
#    identifiable, e.g. for a tmux session name or shell prompt.
if [ ! -d ./home ]; then
  echo "==> ./home not found, seeding it from the image's built-in /home/dev..."
  mkdir -p ./home
  # `docker create` below is a plain Docker CLI call, not `docker compose`,
  # so it has no notion of `--pull never` and would otherwise try (and fail)
  # to pull "$IMAGE" from a registry on a fresh clone with no local image
  # yet. Build it through Compose first — `docker compose build` never
  # touches a registry for the target image, only (as normal) for base
  # images named in the Dockerfile's FROM.
  if ! sudo docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Image not found locally, building it..."
    sudo env DEV_BOX_WRAPPER=1 docker compose build
  fi
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

# 4. Ensure ./home/Main exists and is owned by you, not root. Compose
#    bind-mounts ./Everything onto /home/dev/Main/Everything; if the
#    intermediate ./home/Main didn't already exist (e.g. a devbox set up
#    before Main/Everything was nested under a `Main` dir, so seeding in
#    step 2 never ran again to pick it up), Docker auto-creates missing
#    bind-mount path components itself — the daemon runs as root, so the
#    directory ends up root:root instead of owned by the `dev` user.
sudo mkdir -p ./home/Main
sudo chown "$(id -u):$(id -g)" ./home/Main

# 5. Bring the container up (creates + starts if missing, starts if
#    stopped, no-op if already running) and attach to a tmux session inside
#    it. `tmux new-session -A -s main` attaches to the "main" session if it
#    already exists (so background work, split panes, etc. survive across
#    reattaches) or creates it if this is the first attach. Re-running this
#    script while the container is already up just reattaches — no
#    duplicate containers, no error.
# The compose file attaches the box to the shared, external `devbox-net`
# network (so devbox-proxy can reach it); Compose won't create it, we do.
sudo docker network inspect devbox-net >/dev/null 2>&1 || sudo docker network create devbox-net >/dev/null
compose() {
  sudo env DEV_BOX_WRAPPER=1 DEVBOX_ENV_FILE="$DEVBOX_ENV_FILE" \
    TS_ENV_FILE="$TS_ENV_FILE" TS_HOSTNAME="$TS_HOSTNAME" \
    docker compose "${COMPOSE_FILES[@]}" "$@"
}
# The sidecar has no build section and `up` runs with --pull never, so fetch
# its (pinned, see docker-compose.tailscale.yml) image first if it's missing.
if [ -n "$TS_ENABLED" ] && ! compose pull --quiet --policy missing tailscale; then
  echo "==> Could not pull the Tailscale sidecar image (see the 'image:' line in docker-compose.tailscale.yml)." >&2
  echo "    Check your network and retry, or move $TS_ENV_FILE away to start without Tailscale." >&2
  exit 1
fi
# --remove-orphans: drops the sidecar if Tailscale was turned off since the
# last start.
compose up --pull never -d --remove-orphans
# Restore the HTTPS port mappings saved by ./tsports.sh (no-op without a
# saved ./https-ports; never fails the start).
if [ -n "$TS_ENABLED" ] && [ -s ./https-ports ]; then
  ./tsports.sh --apply || true
fi
compose exec my-dev-container tmux new-session -A -s main
