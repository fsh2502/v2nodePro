#!/usr/bin/env bash
# Compatibility entry point for the documented binary installer.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARGS=(install)
if [[ ${1:-} != -* && -n ${1:-} ]]; then
    ARGS+=(--version "$1")
    shift
fi
ARGS+=("$@")
if [[ -f "$SCRIPT_DIR/caidatserver.sh" ]]; then
    exec bash "$SCRIPT_DIR/caidatserver.sh" "${ARGS[@]}"
fi
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
    https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/caidatserver.sh -o "$TEMP_DIR/caidatserver.sh"
bash "$TEMP_DIR/caidatserver.sh" "${ARGS[@]}"
