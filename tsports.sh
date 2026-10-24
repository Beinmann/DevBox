#!/bin/bash
# Interactively choose which ports of this devbox are served over HTTPS on the
# tailnet (`tailscale serve`). A mapping HTTPS=TARGET, e.g. 8443=3000, makes
# https://<node>.<tailnet>.ts.net:8443 forward to 127.0.0.1:3000 in the box.
# Needs the Tailscale sidecar to be running (start the box with
# ./bash_in_dev_container.sh first) and "HTTPS Certificates" enabled once in
# the Tailscale admin console (DNS page). `serve` only, never `funnel`:
# nothing becomes public (only Funnel, never used here, is limited to the
# HTTPS ports 443, 8443 and 10000).
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
    if [[ "$m" =~ ^([0-9]+)=([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -ge 1 ] && [ "${BASH_REMATCH[1]}" -le 65535 ] \
       && [ "${BASH_REMATCH[2]}" -ge 1 ] && [ "${BASH_REMATCH[2]}" -le 65535 ] \
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

save_current() {
  # Record the mappings now served (the merged result) in $PORTS_FILE.
  ts tailscale serve status 2>/dev/null | awk '
    /^https:\/\// { p = 443; if (match($1, /:[0-9]+$/)) p = substr($1, RSTART + 1) }
    /^\|-- \/ proxy http:\/\/127\.0\.0\.1:[0-9]+/ { sub(/.*:/, "", $4); print p "=" $4 }
  ' | sort -n > "$PORTS_FILE" || true
}

usage() {
  echo "Usage: $0            add/change mappings (others stay as they are)" >&2
  echo "       $0 --clear [HTTPS_PORT]   remove one mapping, or all of them" >&2
  exit 1
}

clear_port=""
mode=set
case "${1:-}" in
  "") ;;
  --clear)
    mode=clear
    clear_port="${2:-}"
    [ "$#" -le 2 ] || usage
    if [ -n "$clear_port" ]; then
      [[ "$clear_port" =~ ^[0-9]+$ ]] && [ "$clear_port" -ge 1 ] && [ "$clear_port" -le 65535 ] || { echo "Invalid HTTPS port: $clear_port" >&2; exit 1; }
    fi ;;
  *) usage ;;
esac

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
if [ "$mode" = clear ]; then
  echo
  if [ -n "$clear_port" ]; then
    echo "This will stop serving HTTPS port $clear_port."
  else
    echo "This will stop serving ALL HTTPS mappings (was: ${current:-none})."
  fi
  read -r -p "Type 'clear' to confirm: " ok || true
  [ "${ok:-}" = "clear" ] || { echo "Nothing changed."; exit 0; }
  if [ -n "$clear_port" ]; then
    ts tailscale serve --https="$clear_port" off
  else
    ts tailscale serve reset
  fi
  save_current
  echo
  ts tailscale serve status
  exit 0
fi

echo "Example: 443=4321 8443=8000"
echo "Mappings you enter replace the target of the same HTTPS port; all others stay."
echo "To remove mappings use: $0 --clear [HTTPS_PORT]"
read -r -p "Mappings (empty = change nothing): " -a wanted_in || true

if [ "${#wanted_in[@]}" -eq 0 ]; then
  echo "Nothing changed."; exit 0
fi

declare -A cur seen
for m in $current; do cur[${m%=*}]=${m#*=}; done
changes=()
report=()
for m in "${wanted_in[@]}"; do
  if ! [[ "$m" =~ ^([0-9]+)=([0-9]+)$ ]]; then
    echo "Invalid mapping: $m (use HTTPS=TARGET)" >&2; exit 1
  fi
  h=${BASH_REMATCH[1]}; t=${BASH_REMATCH[2]}
  [ "$h" -ge 1 ] && [ "$h" -le 65535 ] || { echo "Invalid HTTPS port: $m" >&2; exit 1; }
  [ "$t" -ge 1 ] && [ "$t" -le 65535 ] || { echo "Invalid target port: $m" >&2; exit 1; }
  [ -z "${seen[$h]:-}" ] || { echo "HTTPS port $h given twice" >&2; exit 1; }
  seen[$h]=1
  if [ -z "${cur[$h]:-}" ]; then
    report+=("  added    $h=$t"); changes+=("$h=$t")
  elif [ "${cur[$h]}" != "$t" ]; then
    report+=("  changed  $h=$t (was $h=${cur[$h]})"); changes+=("$h=$t")
  else
    report+=("  kept     $h=$t")
  fi
done
for h in $(printf '%s\n' "${!cur[@]}" | sort -n); do
  [ -n "${seen[$h]:-}" ] || report+=("  kept     $h=${cur[$h]}")
done

echo
echo "Resulting state:"
printf '%s\n' "${report[@]}"
if [ "${#changes[@]}" -eq 0 ]; then
  echo "Nothing to change."; exit 0
fi
read -r -p "Apply? [y/N] " ok || true
[ "${ok:-n}" = "y" ] || [ "${ok:-n}" = "Y" ] || { echo "Nothing changed."; exit 0; }

for m in "${changes[@]}"; do
  ts tailscale serve --bg --https="${m%=*}" "http://127.0.0.1:${m#*=}"
done
save_current
echo
ts tailscale serve status
