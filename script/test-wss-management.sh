#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/caidatserver.sh"

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
    cat > "$WSS_NGINX_DIR/v2node-wss-$domain.conf" <<EOF
$WSS_MARKER
server {
    listen 443 ssl;
    server_name $domain;
    ssl_certificate $CERT_DIR/$domain.cer;
    ssl_certificate_key $CERT_DIR/$domain.key;
    location = $path {
        proxy_pass http://127.0.0.1:$port;
    }
    location / { return 404; }
}
EOF
    printf cert > "$CERT_DIR/$domain.cer"
    printf key > "$CERT_DIR/$domain.key"
}

reset_calls() {
    rm -f "$TEST_NGINX_COUNT" "$TEST_RELOAD_COUNT"
    TEST_NGINX_FAIL_AT=""
    TEST_RELOAD_FAIL_AT=""
    export TEST_NGINX_FAIL_AT TEST_RELOAD_FAIL_AT
}

make_config a.example.com /a 10001
make_config b.example.com /b 10002
list_output="$(list_wss_configs)"
[[ "$list_output" == *"a.example.com"* ]]
[[ "$list_output" == *"path /a -> 127.0.0.1:10001"* ]]
[[ "$list_output" == *"b.example.com"* ]]
[[ "$list_output" == *"path /b -> 127.0.0.1:10002"* ]]
cp "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf" "$TEST_ROOT/original-a"
cp "$WSS_NGINX_DIR/v2node-wss-b.example.com.conf" "$TEST_ROOT/original-b"
printf '1\nXOA a.example.com\n' | delete_wss_config >/dev/null
[[ ! -e "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf" ]]
cmp -s "$TEST_ROOT/original-b" "$WSS_NGINX_DIR/v2node-wss-b.example.com.conf"
[[ -f "$CERT_DIR/a.example.com.cer" && -f "$CERT_DIR/a.example.com.key" ]]
first_backup="$(find "$WSS_BACKUP_ROOT" -type f -name 'v2node-wss-a.example.com.conf' -print -quit)"
[[ -n "$first_backup" ]]
cmp -s "$TEST_ROOT/original-a" "$first_backup"

make_config a.example.com /a 10001
printf '1\nno\n' | delete_wss_config >/dev/null
[[ -f "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf" ]]

printf '%s\nserver { server_name unmanaged.example.com; }' "$WSS_MARKER" > "$WSS_NGINX_DIR/v2node-wss-wrong.example.com.conf"
printf '%s\nserver { server_name multi.example.com other.example.com; }' "$WSS_MARKER" > "$WSS_NGINX_DIR/v2node-wss-multi.example.com.conf"
ln -s "$WSS_NGINX_DIR/v2node-wss-b.example.com.conf" "$WSS_NGINX_DIR/v2node-wss-link.example.com.conf"
wss_collect_configs
[[ " ${WSS_DOMAINS[*]} " != *" wrong.example.com "* ]]
[[ " ${WSS_DOMAINS[*]} " != *" multi.example.com "* ]]
[[ " ${WSS_DOMAINS[*]} " != *" link.example.com "* ]]

reset_calls
TEST_NGINX_FAIL_AT=1
export TEST_NGINX_FAIL_AT
printf '1\nXOA a.example.com\n' | delete_wss_config >/dev/null 2>&1 && exit 1
cmp -s "$TEST_ROOT/original-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"
[[ ! -f "$TEST_RELOAD_COUNT" ]]

reset_calls
TEST_NGINX_FAIL_AT=2
export TEST_NGINX_FAIL_AT
printf '1\nXOA a.example.com\n' | delete_wss_config >/dev/null 2>&1 && exit 1
cmp -s "$TEST_ROOT/original-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"
cmp -s "$TEST_ROOT/original-b" "$WSS_NGINX_DIR/v2node-wss-b.example.com.conf"
[[ "$(cat "$TEST_RELOAD_COUNT")" == 1 ]]

reset_calls
TEST_RELOAD_FAIL_AT=1
export TEST_RELOAD_FAIL_AT
printf '1\nXOA a.example.com\n' | delete_wss_config >/dev/null 2>&1 && exit 1
cmp -s "$TEST_ROOT/original-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"
cmp -s "$TEST_ROOT/original-b" "$WSS_NGINX_DIR/v2node-wss-b.example.com.conf"
[[ "$(cat "$TEST_RELOAD_COUNT")" == 2 ]]

reset_calls
fixture_port=10003
for suffix in c d e f g h; do
    make_config "$suffix.example.com" "/$suffix" "$fixture_port"
    fixture_port=$((fixture_port + 1))
done
leading_zero_output="$(printf '08\nno\n' | delete_wss_config)"
[[ "$leading_zero_output" == *"Sẽ xóa toàn bộ cấu hình WSS của domain h.example.com"* ]]
[[ -f "$WSS_NGINX_DIR/v2node-wss-h.example.com.conf" ]]
printf '999999999999999999999999999999\n' | delete_wss_config >/dev/null 2>&1 && exit 1
cmp -s "$TEST_ROOT/original-a" "$WSS_NGINX_DIR/v2node-wss-a.example.com.conf"

rm -f "$WSS_NGINX_DIR"/v2node-wss-*.conf
output="$(list_wss_configs)"
[[ "$output" == *"Không có cấu hình WSS 443"* ]]

echo 'PASS: WSS list/delete safety, cancellation, rollback, isolation and empty state'
