#!/bin/sh
# Runs INSIDE the Tailscale sidecar (mounted read-only by
# docker-compose.tailscale.yml). Re-registers the node when its registration
# is gone (ephemeral nodes are dropped by the control server after being
# offline for a while, e.g. PC asleep), using the auth key already in the
# sidecar's environment. Does nothing while the node is healthy, unless
# called with --force. Used by the entrypoint's watchdog loop and by
# ./tsrenew.sh on the host.
set -u

state() {
  tailscale status --json 2>/dev/null \
    | sed -n 's/^ *"BackendState": *"\([^"]*\)".*/\1/p' | head -n1
}

if [ "${1:-}" != "--force" ]; then
  case "$(state)" in
    NeedsLogin|NoState|Stopped) ;;   # registration lost -> renew
    *) exit 0 ;;                      # Running, Starting, or tailscaled not up yet
  esac
fi

[ -n "${TS_AUTHKEY:-}" ] || { echo "tailscale-renew: no TS_AUTHKEY in the sidecar" >&2; exit 1; }
echo "tailscale-renew: re-registering ${TS_HOSTNAME:-devbox}" >&2
# --reset: `up` refuses to run when it would change non-default settings
# unless they're all listed; list what containerboot sets.
exec tailscale up --reset --auth-key="$TS_AUTHKEY" --hostname="${TS_HOSTNAME:-devbox}" \
  --advertise-tags=tag:devbox --accept-dns=false
