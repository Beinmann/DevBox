#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Export for docker-compose.yml's build.args (see bash_in_dev_container.sh).
export USER_UID="$(id -u)"
export USER_GID="$(id -g)"

sudo env DEV_BOX_WRAPPER=1 USER_UID="$USER_UID" USER_GID="$USER_GID" docker compose build
