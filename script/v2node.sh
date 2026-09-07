#!/usr/bin/env bash
# Legacy command delegates to the safe manager; no firewall/NAT/global Nginx edits.
set -euo pipefail
if [[ ${1:-} == update && -n ${2:-} && ${2:-} != -* ]]; then
    VERSION="$2"
    shift 2
    set -- update --version "$VERSION" "$@"
fi
if [[ -f /usr/local/lib/v2node-manager/manager.py ]]; then
    exec python3 /usr/local/lib/v2node-manager/manager.py "$@"
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/caidatserver.sh" ]]; then
    exec bash "$SCRIPT_DIR/caidatserver.sh" "$@"
fi
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
BOOTSTRAP_URL=https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/caidatserver.sh
if command -v curl >/dev/null; then
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 "$BOOTSTRAP_URL" -o "$TEMP_DIR/caidatserver.sh"
else
    wget -q --timeout=30 --tries=3 "$BOOTSTRAP_URL" -O "$TEMP_DIR/caidatserver.sh"
fi
bash "$TEMP_DIR/caidatserver.sh" "$@"
