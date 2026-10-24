#!/bin/bash
# Interactively choose which ports of this devbox are served over HTTPS on the
# tailnet (`tailscale serve`). A mapping HTTPS=TARGET, e.g. 8443=3000, makes
# https://<node>.<tailnet>.ts.net:8443 forward to 127.0.0.1:3000 in the box.
# Needs the Tailscale sidecar to be running (start the box with
# ./bash_in_dev_container.sh first) and "HTTPS Certificates" enabled once in
# the Tailscale admin console (DNS page). `serve` only, never `funnel`:
# nothing becomes public. Serve allows only HTTPS ports 443, 8443 and 10000.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ts() {
  sudo env DEV_BOX_WRAPPER=1 docker compose \
    -f docker-compose.yml -f docker-compose.tailscale.yml \
    exec -T tailscale "$@"
}

if ! ts tailscale status >/dev/null 2>&1; then
  echo "Tailscale sidecar not running for this dir. Start it with ./bash_in_dev_container.sh" >&2
  exit 1
fi

# Current mappings as "HTTPS=TARGET" (an https URL without port means 443).
# Only "/" handlers pointing at 127.0.0.1 are understood.
current=$(ts tailscale serve status 2>/dev/null | awk '
  /^https:\/\// { p = 443; if (match($1, /:[0-9]+$/)) p = substr($1, RSTART + 1) }
  /^\|-- \/ proxy http:\/\/127\.0\.0\.1:[0-9]+/ { sub(/.*:/, "", $4); print p "=" $4 }
' | sort -n | xargs || true)

echo "Currently served over HTTPS (HTTPS=target): ${current:-none}"
echo
echo "Listening in the box (candidate targets, best effort):"
ts netstat -ltn 2>/dev/null \
  | awk 'NR>2 {n=split($4,a,":"); print a[n]}' | sort -un | sed 's/^/  /' || true
echo
echo "Allowed HTTPS ports: 443 8443 10000. Example: 443=4321 8443=8000"
read -r -p "Mappings (empty = keep current, 'none' = clear): " -a wanted_in || true

if [ "${#wanted_in[@]}" -eq 0 ]; then
  read -r -a wanted_in <<< "$current"
elif [ "${wanted_in[0]}" = "none" ]; then
  wanted_in=()
fi

declare -A seen
wanted=()
for m in "${wanted_in[@]}"; do
  if ! [[ "$m" =~ ^([0-9]+)=([0-9]+)$ ]]; then
    echo "Invalid mapping: $m (use HTTPS=TARGET)" >&2; exit 1
  fi
  h=${BASH_REMATCH[1]}; t=${BASH_REMATCH[2]}
  case "$h" in 443|8443|10000) ;; *) echo "HTTPS port must be 443, 8443 or 10000: $m" >&2; exit 1 ;; esac
  [ "$t" -ge 1 ] && [ "$t" -le 65535 ] || { echo "Invalid target port: $m" >&2; exit 1; }
  [ -z "${seen[$h]:-}" ] || { echo "HTTPS port $h given twice" >&2; exit 1; }
  seen[$h]=1
  wanted+=("$h=$t")
done

echo
echo "Will serve: ${wanted[*]:-none}  (was: ${current:-none})"
read -r -p "Apply? [y/N] " ok || true
[ "${ok:-n}" = "y" ] || [ "${ok:-n}" = "Y" ] || { echo "Nothing changed."; exit 0; }

ts tailscale serve reset
for m in "${wanted[@]}"; do
  ts tailscale serve --bg --https="${m%=*}" "http://127.0.0.1:${m#*=}"
done
echo
ts tailscale serve status
