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
echo "Enter as many lines as you like; an empty line ends the session and applies."
echo "To remove mappings use: $0 --clear [HTTPS_PORT]"

declare -A cur=() pending=()
for m in $current; do cur[${m%=*}]=${m#*=}; done

show_state() {
  # Active mappings, with not yet applied ones marked.
  local h lines=()
  for h in $(printf '%s\n' "${!cur[@]}" "${!pending[@]}" | sort -nu); do
    if [ -n "${pending[$h]:-}" ]; then
      if [ -n "${cur[$h]:-}" ]; then
        lines+=("  $h=${pending[$h]}  (pending, was $h=${cur[$h]})")
      else
        lines+=("  $h=${pending[$h]}  (pending, new)")
      fi
    else
      lines+=("  $h=${cur[$h]}")
    fi
  done
  echo
  echo "Mappings now (HTTPS=target):"
  if [ "${#lines[@]}" -eq 0 ]; then echo "  none"; else printf '%s\n' "${lines[@]}"; fi
}

while :; do
  show_state
  wanted_in=()
  read -r -p "Mappings (empty = finish): " -a wanted_in || true
  [ "${#wanted_in[@]}" -gt 0 ] || break
  declare -A line_seen=()
  for m in "${wanted_in[@]}"; do
    if ! [[ "$m" =~ ^([0-9]+)=([0-9]+)$ ]]; then
      echo "Invalid mapping: $m (use HTTPS=TARGET), ignored" >&2; continue
    fi
    h=${BASH_REMATCH[1]}; t=${BASH_REMATCH[2]}
    if ! { [ "$h" -ge 1 ] && [ "$h" -le 65535 ]; }; then echo "Invalid HTTPS port: $m, ignored" >&2; continue; fi
    if ! { [ "$t" -ge 1 ] && [ "$t" -le 65535 ]; }; then echo "Invalid target port: $m, ignored" >&2; continue; fi
    if [ -n "${line_seen[$h]:-}" ]; then echo "HTTPS port $h given twice: $m, ignored" >&2; continue; fi
    line_seen[$h]=1
    if [ "${cur[$h]:-}" = "$t" ]; then
      unset "pending[$h]"
    else
      pending[$h]=$t
    fi
  done
done

if [ "${#pending[@]}" -eq 0 ]; then
  echo "Nothing changed."; exit 0
fi
read -r -p "Apply? [y/N] " ok || true
[ "${ok:-n}" = "y" ] || [ "${ok:-n}" = "Y" ] || { echo "Nothing changed."; exit 0; }

for h in $(printf '%s\n' "${!pending[@]}" | sort -n); do
  ts tailscale serve --bg --https="$h" "http://127.0.0.1:${pending[$h]}"
done
save_current
echo
ts tailscale serve status
