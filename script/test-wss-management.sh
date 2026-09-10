#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/caidatserver.sh"
source "$(dirname "$0")/setup-wss-proxy.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
WSS_NGINX_DIR="$TEST_ROOT/nginx"
WSS_BACKUP_ROOT="$TEST_ROOT/backups"
BIN_DIR="$TEST_ROOT/bin"
CERT_DIR="$TEST_ROOT/certs"
mkdir -p "$WSS_NGINX_DIR" "$BIN_DIR" "$CERT_DIR"
export PATH="$BIN_DIR:$PATH"
export TEST_NGINX_COUNT="$TEST_ROOT/nginx-count"
export TEST_RELOAD_COUNT="$TEST_ROOT/reload-count"
export TEST_NGINX_FAIL_AT=""
export TEST_RELOAD_FAIL_AT=""

cat > "$BIN_DIR/nginx" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$TEST_NGINX_COUNT" ]] && read -r count < "$TEST_NGINX_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_NGINX_COUNT"
[[ "$*" == "-t" ]] || exit 90
[[ "${TEST_NGINX_FAIL_AT:-}" != "$count" ]]
EOF
cat > "$BIN_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$TEST_RELOAD_COUNT" ]] && read -r count < "$TEST_RELOAD_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_RELOAD_COUNT"
[[ "$*" == "reload nginx" ]] || exit 90
[[ "${TEST_RELOAD_FAIL_AT:-}" != "$count" ]]
EOF
chmod +x "$BIN_DIR/nginx" "$BIN_DIR/systemctl"

make_config() {
    local domain="$1" path="$2" port="$3"
    DOMAIN="$domain"
    WS_PATH="$path"
    BACKEND_PORT="$port"
    CERT_FILE="$CERT_DIR/$domain.cer"
    KEY_FILE="$CERT_DIR/$domain.key"
    NGINX_FILE="$WSS_NGINX_DIR/v2node-wss-$domain.conf"
    render_nginx_config > "$TEST_ROOT/rendered"
    mv "$TEST_ROOT/rendered" "$NGINX_FILE"
    printf cert > "$CERT_DIR/$domain.cer"
    printf key > "$CERT_DIR/$domain.key"
}

reset_calls() {
    rm -f "$TEST_NGINX_COUNT" "$TEST_RELOAD_COUNT"
    TEST_NGINX_FAIL_AT=""
    TEST_RELOAD_FAIL_AT=""
    export TEST_NGINX_FAIL_AT TEST_RELOAD_FAIL_AT
}

make_config a.example.com /ab 10002
make_config a.example.com /a 10001
make_config b.example.com /b 10003
cp "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf" "$TEST_ROOT/original-a"
cp "$WSS_NGINX_DIR/v2node-wss-b.example.com.conf" "$TEST_ROOT/original-b"
sed '/^    location = \/a {$/,/^    }$/d' "$TEST_ROOT/original-a" > "$TEST_ROOT/expected-a"

list_output="$(list_wss_configs)"
[[ "$list_output" == *"path /a -> 127.0.0.1:10001"* ]]
[[ "$list_output" == *"path /ab -> 127.0.0.1:10002"* ]]

# Exact /a removal must preserve /ab and every other byte.
printf '1\n2\nXOA /a\n' | delete_wss_config >/dev/null
cmp -s "$TEST_ROOT/expected-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"
cmp -s "$TEST_ROOT/original-b" "$WSS_NGINX_DIR/v2node-wss-b.example.com.conf"
[[ -f "$CERT_DIR/a.example.com.cer" && -f "$CERT_DIR/a.example.com.key" ]]
first_backup="$(find "$WSS_BACKUP_ROOT" -type f -name 'v2node-wss-a.example.com.conf' -print -quit)"
[[ -n "$first_backup" ]]
cmp -s "$TEST_ROOT/original-a" "$first_backup"

# Removing the final route retains TLS/fallback, and the real generator can add a route again.
last_output="$(printf '1\n1\nXOA /ab\n' | delete_wss_config)"
[[ "$last_output" == *"vẫn giữ TLS cùng fallback 404"* ]]
[[ -f "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf" ]]
grep -Fq "ssl_certificate $CERT_DIR/a.example.com.cer;" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"
grep -Fq 'location / {' "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"
[[ -z "$(wss_validate_routes "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf")" ]]
make_config a.example.com /new 10004
grep -Fq 'location = /new {' "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"

# Cancellation and invalid selections do not mutate the file.
cp "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf" "$TEST_ROOT/cancel-a"
printf '0\n' | delete_wss_config >/dev/null
printf '1\n0\n' | delete_wss_config >/dev/null
printf '1\n1\nno\n' | delete_wss_config >/dev/null
cmp -s "$TEST_ROOT/cancel-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"
printf '999999999999999999999999999999\n' | delete_wss_config >/dev/null 2>&1 && exit 1
printf '1\n999999999999999999999999999999\n' | delete_wss_config >/dev/null 2>&1 && exit 1
cmp -s "$TEST_ROOT/cancel-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"

# Managed-file discovery keeps rejecting mismatched domains and symlinks.
printf '%s\nserver { server_name unmanaged.example.com; }' "$WSS_MARKER" > "$WSS_NGINX_DIR/v2node-wss-wrong.example.com.conf"
printf '%s\nserver { server_name multi.example.com other.example.com; }' "$WSS_MARKER" > "$WSS_NGINX_DIR/v2node-wss-multi.example.com.conf"
ln -s "$WSS_NGINX_DIR/v2node-wss-b.example.com.conf" "$WSS_NGINX_DIR/v2node-wss-link.example.com.conf"
wss_collect_configs
[[ " ${WSS_DOMAINS[*]} " != *" wrong.example.com "* ]]
[[ " ${WSS_DOMAINS[*]} " != *" multi.example.com "* ]]
[[ " ${WSS_DOMAINS[*]} " != *" link.example.com "* ]]
rm -f "$WSS_NGINX_DIR/v2node-wss-wrong.example.com.conf" "$WSS_NGINX_DIR/v2node-wss-multi.example.com.conf" "$WSS_NGINX_DIR/v2node-wss-link.example.com.conf"

# Duplicate, malformed, and nested route blocks are rejected before nginx -t or backup.
for kind in duplicate malformed nested; do
    rm -f "$WSS_NGINX_DIR/v2node-wss-c.example.com.conf"
    make_config c.example.com /c 10005
    case "$kind" in
        duplicate)
            sed -n '/^    location = \/c {$/,/^    }$/p' "$WSS_NGINX_DIR/v2node-wss-c.example.com.conf" > "$TEST_ROOT/duplicate-block"
            sed -i "/^    location \/ {/r $TEST_ROOT/duplicate-block" "$WSS_NGINX_DIR/v2node-wss-c.example.com.conf"
            ;;
        malformed) sed -i 's#proxy_pass http://127.0.0.1:10005;#proxy_pass http://example.com;#' "$WSS_NGINX_DIR/v2node-wss-c.example.com.conf" ;;
        nested) sed -i '/proxy_http_version/a\        if ($host) {' "$WSS_NGINX_DIR/v2node-wss-c.example.com.conf" ;;
    esac
    cp "$WSS_NGINX_DIR/v2node-wss-c.example.com.conf" "$TEST_ROOT/bad-$kind"
    reset_calls
    printf '3\n' | delete_wss_config >/dev/null 2>&1 && exit 1
    cmp -s "$TEST_ROOT/bad-$kind" "$WSS_NGINX_DIR/v2node-wss-c.example.com.conf"
    [[ ! -f "$TEST_NGINX_COUNT" ]]
done
rm -f "$WSS_NGINX_DIR/v2node-wss-c.example.com.conf"

# Baseline failure changes nothing.
reset_calls
TEST_NGINX_FAIL_AT=1
export TEST_NGINX_FAIL_AT
printf '1\n1\nXOA /new\n' | delete_wss_config >/dev/null 2>&1 && exit 1
cmp -s "$TEST_ROOT/cancel-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"
[[ ! -f "$TEST_RELOAD_COUNT" ]]

# Post-edit nginx and reload failures both restore the verified backup.
reset_calls
TEST_NGINX_FAIL_AT=2
export TEST_NGINX_FAIL_AT
printf '1\n1\nXOA /new\n' | delete_wss_config >/dev/null 2>&1 && exit 1
cmp -s "$TEST_ROOT/cancel-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"
[[ "$(cat "$TEST_RELOAD_COUNT")" == 1 ]]

reset_calls
TEST_RELOAD_FAIL_AT=1
export TEST_RELOAD_FAIL_AT
printf '1\n1\nXOA /new\n' | delete_wss_config >/dev/null 2>&1 && exit 1
cmp -s "$TEST_ROOT/cancel-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"
[[ "$(cat "$TEST_RELOAD_COUNT")" == 2 ]]

# The explicit all-domain option retains the previous verified delete behavior.
reset_calls
printf '1\nA\nXOA a.example.com\n' | delete_wss_config >/dev/null
[[ ! -e "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf" ]]
[[ -f "$CERT_DIR/a.example.com.cer" && -f "$CERT_DIR/a.example.com.key" ]]
cmp -s "$TEST_ROOT/original-b" "$WSS_NGINX_DIR/v2node-wss-b.example.com.conf"

make_config a.example.com /a 10001
cp "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf" "$TEST_ROOT/all-a"
reset_calls
TEST_NGINX_FAIL_AT=2
export TEST_NGINX_FAIL_AT
printf '1\nA\nXOA a.example.com\n' | delete_wss_config >/dev/null 2>&1 && exit 1
cmp -s "$TEST_ROOT/all-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"

rm -f "$WSS_NGINX_DIR"/v2node-wss-*.conf
output="$(list_wss_configs)"
[[ "$output" == *"Không có cấu hình WSS 443"* ]]

echo 'PASS: exact WSS path/all-domain deletion, parser safety, rollback, certificates and empty state'
