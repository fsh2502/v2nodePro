#!/usr/bin/env bash
# Bootstrap downloads a coherent manager from one immutable Git commit.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    if command -v python3 >/dev/null && [[ -f "$SCRIPT_DIR/v2node-manager.py" ]]; then
        exec python3 "$SCRIPT_DIR/v2node-manager.py" --help
    fi
    echo 'v2nodePro: menu | install | add | edit | remove | list | doctor | certificates | renew | update | backup | restore | tune | uninstall'
    echo 'Run without arguments for the interactive menu. Linux/root is required for changes.'
    exit 0
fi
[[ $EUID == 0 ]] || { echo 'Vui lòng chạy bằng quyền root.' >&2; exit 1; }
if ! command -v python3 >/dev/null || ! command -v curl >/dev/null; then
    if command -v apt-get >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3 curl ca-certificates
    elif command -v dnf >/dev/null; then
        dnf install -y python3 curl ca-certificates
    elif command -v yum >/dev/null; then
        yum install -y python3 curl ca-certificates
    elif command -v apk >/dev/null; then
        apk add --no-cache python3 curl ca-certificates
    else
        echo 'Cần cài python3, curl, ca-certificates trước.' >&2; exit 1
    fi
fi
if [[ -f "$SCRIPT_DIR/v2node-manager.py" ]]; then
    exec python3 "$SCRIPT_DIR/v2node-manager.py" "$@"
fi
DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -rf -- "$DOWNLOAD_DIR"' EXIT
REF="${V2NODE_MANAGER_REF:-main}"
[[ "$REF" =~ ^[A-Za-z0-9._/-]+$ && "$REF" != *..* ]] || exit 1
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
    "https://api.github.com/repos/fsh2502/v2nodePro/commits/$REF" -o "$DOWNLOAD_DIR/commit.json"
COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha"])' "$DOWNLOAD_DIR/commit.json")"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo 'Không xác định được commit của trình cài.'; exit 1; }
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
    "https://raw.githubusercontent.com/fsh2502/v2nodePro/$COMMIT/script/v2node-manager.py" \
    -o "$DOWNLOAD_DIR/v2node-manager.py"
echo "Trình quản lý v2nodePro: $COMMIT"
python3 "$DOWNLOAD_DIR/v2node-manager.py" "$@"
