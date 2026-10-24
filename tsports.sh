#!/bin/bash
# Interactively choose which ports of this devbox are served over HTTPS on the
# tailnet (`tailscale serve`). A mapping HTTPS=TARGET, e.g. 8443=3000, makes
# https://<node>.<tailnet>.ts.net:8443 forward to 127.0.0.1:3000 in the box.
# Needs the Tailscale sidecar to be running (start the box with
# ./bash_in_dev_container.sh first) and "HTTPS Certificates" enabled once in
# the Tailscale admin console (DNS page). `serve` only, never `funnel`:
# nothing becomes public. Serve allows only HTTPS ports 443, 8443 and 10000.
#
# The applied mappings are saved to ./https-ports (one HTTPS=TARGET per line,
# gitignored). `./tsports.sh --apply` re-applies that file without prompting;
# bash_in_dev_container.sh calls it after the box is up. Invalid entries are
# reported and skipped.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PORTS_FILE=./https-ports

ts() {
  sudo env DEV_BOX_WRAPPER=1 docker compose \
    -f docker-compose.yml -f docker-compose.tailscale.yml \
    exec -T tailscale "$@"
}

if [ "${1:-}" = "--apply" ]; then
  # Non-interactive restore of the saved mappings. Never fails the caller.
  [ -s "$PORTS_FILE" ] || exit 0
  for _ in $(seq 30); do
    ts tailscale status >/dev/null 2>&1 && break
    sleep 1
  done
  ts tailscale status >/dev/null 2>&1 || { echo "==> HTTPS ports not restored: Tailscale sidecar not ready." >&2; exit 0; }
  declare -A seen
  valid=()
  while read -r m _; do
    case "${m:-}" in ""|"#"*) continue ;; esac
    if [[ "$m" =~ ^(443|8443|10000)=([0-9]+)$ ]] && [ "${BASH_REMATCH[2]}" -ge 1 ] && [ "${BASH_REMATCH[2]}" -le 65535 ] \
       && [ -z "${seen[${BASH_REMATCH[1]}]:-}" ]; then
      seen[${BASH_REMATCH[1]}]=1
      valid+=("$m")
    else
      echo "==> Ignoring invalid entry in $PORTS_FILE: $m" >&2
    fi
  done < "$PORTS_FILE"
  [ "${#valid[@]}" -gt 0 ] || exit 0
  ts tailscale serve reset >/dev/null 2>&1 || true
  for m in "${valid[@]}"; do
    ts tailscale serve --bg --https="${m%=*}" "http://127.0.0.1:${m#*=}" >/dev/null 2>&1 \
      || echo "==> Could not serve $m" >&2
  done
  echo "==> HTTPS ports restored: ${valid[*]}"
  exit 0
fi

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
{ [ "${#wanted[@]}" -eq 0 ] || printf '%s\n' "${wanted[@]}"; } > "$PORTS_FILE"
echo
ts tailscale serve status
