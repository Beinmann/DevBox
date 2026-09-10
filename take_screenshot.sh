#!/usr/bin/env bash
# Run this on the HOST (not inside the container) — it needs real display
# access. Waits a second (so you can switch to the window you want), takes a
# screenshot, and drops it into ./home, which every devbox clone bind-mounts
# to /home/dev. Inside the container, read it from ~/ai-drop/.
#
# Copy this file into each devbox clone unchanged — it locates its own drop
# folder relative to itself, so it works the same in every project dir.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
drop_dir="$script_dir/home/ai-drop"
mkdir -p "$drop_dir"

sleep 1

out="$drop_dir/shot-$(date +%Y%m%d-%H%M%S).png"

if command -v grim >/dev/null 2>&1; then
    grim "$out"
elif command -v maim >/dev/null 2>&1; then
    maim "$out"
elif command -v scrot >/dev/null 2>&1; then
    scrot "$out"
elif command -v gnome-screenshot >/dev/null 2>&1; then
    gnome-screenshot -f "$out"
elif command -v spectacle >/dev/null 2>&1; then
    spectacle -b -n -o "$out"
elif command -v screencapture >/dev/null 2>&1; then
    screencapture -x "$out"
else
    echo "No supported screenshot tool found (tried grim, maim, scrot, gnome-screenshot, spectacle, screencapture)." >&2
    exit 1
fi

echo "Saved $out (readable inside container at ~/ai-drop/$(basename "$out"))"
