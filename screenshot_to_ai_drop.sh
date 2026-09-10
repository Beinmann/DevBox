#!/usr/bin/env bash
# Run this on the HOST (not inside the container). Waits a second (so you
# can switch to the window you want), takes a screenshot via your own
# `myScreenshot` command, and drops it into ./home/Main, which every devbox
# clone bind-mounts to /home/dev/Main (./home:/home/dev). Inside the
# container, read it from ~/Main/ai-drop/.
#
# `myScreenshot <output-path>` must already be defined on your host (alias,
# function, or script on PATH) — that's on you to set up, this script just
# calls it.
#
# Copy this file into each devbox clone unchanged — it locates its own drop
# folder relative to itself, so it works the same in every project dir.
set -euo pipefail

if ! command -v myScreenshot >/dev/null 2>&1; then
    echo "myScreenshot is not defined. Define it (alias/function/script on PATH) before running this." >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$script_dir/home" ]; then
    echo "$script_dir/home does not exist yet — start the container at least once first (./bash_in_dev_container.sh)." >&2
    exit 1
fi

drop_dir="$script_dir/home/Main/ai-drop"
mkdir -p "$drop_dir"

sleep 0.5

out="$drop_dir/shot-$(date +%Y%m%d-%H%M%S).png"

myScreenshot "$out"

echo "Saved $out (readable inside container at ~/Main/ai-drop/$(basename "$out"))"
