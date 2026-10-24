#!/bin/bash
# Interactively choose which ports of this devbox are served over HTTPS on the
# tailnet (`tailscale serve`). Port N on https://<node>.<tailnet>.ts.net:N
# forwards to 127.0.0.1:N in the box. Needs the Tailscale sidecar to be running
# (start the box with ./bash_in_dev_container.sh first) and "HTTPS
# Certificates" enabled once in the Tailscale admin console (DNS page).
# `serve` only, never `funnel`: nothing becomes public.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ts() {
  sudo env DEV_BOX_WRAPPER=1 docker compose \
    -f docker-compose.yml -f docker-compose.tailscale.yml \
    exec -T tailscale tailscale "$@"
}

if ! ts status >/dev/null 2>&1; then
  echo "Tailscale sidecar not running for this dir. Start it with ./bash_in_dev_container.sh" >&2
  exit 1
fi

# Ports currently served over HTTPS (URLs without a port mean 443).
current=$(ts serve status 2>/dev/null \
  | sed -nE 's#^https://[^/: ]+(:([0-9]+))?.*#\2#p' | sed 's/^$/443/' | sort -un | xargs || true)

echo "Currently served over HTTPS: ${current:-none}"
echo
echo "Listening in the box (best effort):"
sudo env DEV_BOX_WRAPPER=1 docker compose -f docker-compose.yml -f docker-compose.tailscale.yml \
  exec -T tailscale netstat -ltn 2>/dev/null | awk 'NR>2 {n=split($4,a,":"); print "  " a[n] "  (" $4 ")"}' | sort -un || true
echo
read -r -p "Ports to serve over HTTPS (space-separated, empty = none) [${current}]: " -a wanted_in || true
if [ "${#wanted_in[@]}" -eq 0 ] && [ -n "$current" ]; then
  read -r -p "Keep current ports? [Y/n/none] " ans || true
  case "${ans:-y}" in
    none) wanted_in=() ;;
    n|N) echo "Aborted."; exit 0 ;;
    *) read -r -a wanted_in <<< "$current" ;;
  esac
fi

wanted=()
for p in "${wanted_in[@]}"; do
  if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
    echo "Invalid port: $p" >&2; exit 1
  fi
  wanted+=("$p")
done
wanted=($(printf '%s\n' "${wanted[@]}" | sort -un))

echo
echo "Will serve HTTPS ports: ${wanted[*]:-none}  (was: ${current:-none})"
echo "Note: an HTTPS port replaces plain HTTP on the same port number."
read -r -p "Apply? [y/N] " ok || true
[ "${ok:-n}" = "y" ] || [ "${ok:-n}" = "Y" ] || { echo "Nothing changed."; exit 0; }

ts serve reset
for p in "${wanted[@]}"; do
  ts serve --bg --https="$p" "http://127.0.0.1:$p"
done
echo
ts serve status
