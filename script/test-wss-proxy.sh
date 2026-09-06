#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-wss-proxy.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
NGINX_DIR="$TEST_DIR"
DOMAIN=node-a.example.com
CERT_FILE=/etc/v2node/proxy-certs/node-a.example.com.cer
KEY_FILE=/etc/v2node/proxy-certs/node-a.example.com.key
NGINX_FILE="$NGINX_DIR/v2node-wss-$DOMAIN.conf"
WS_PATH=/panel-a
BACKEND_PORT=10001
render_nginx_config > "$TEST_DIR/result"
mv "$TEST_DIR/result" "$NGINX_FILE"
cp "$NGINX_FILE" "$TEST_DIR/original-a"

DOMAIN=node-b.example.com
CERT_FILE=/etc/v2node/proxy-certs/node-b.example.com.cer
KEY_FILE=/etc/v2node/proxy-certs/node-b.example.com.key
NGINX_FILE="$NGINX_DIR/v2node-wss-$DOMAIN.conf"
WS_PATH=/panel-b
BACKEND_PORT=10002
port_has_other_route 10001
if port_has_other_route 10002; then exit 1; fi
render_nginx_config > "$TEST_DIR/result"
mv "$TEST_DIR/result" "$NGINX_FILE"
cmp "$TEST_DIR/original-a" "$NGINX_DIR/v2node-wss-node-a.example.com.conf"
grep -Fq 'server_name node-b.example.com;' "$NGINX_FILE"
grep -Fq 'ssl_certificate /etc/v2node/proxy-certs/node-b.example.com.cer;' "$NGINX_FILE"
grep -Fq 'proxy_pass http://127.0.0.1:10002;' "$NGINX_FILE"
grep -Fq 'proxy_set_header Host $host;' "$NGINX_FILE"

# A third route on the second domain must preserve its existing route.
WS_PATH=/panel-c
BACKEND_PORT=10003
render_nginx_config > "$TEST_DIR/result"
mv "$TEST_DIR/result" "$NGINX_FILE"
grep -Fq 'location = /panel-b {' "$NGINX_FILE"
grep -Fq 'location = /panel-c {' "$NGINX_FILE"
port_has_other_route 10002
if port_has_other_route 10003; then exit 1; fi

# Re-running one path updates only that backend, with no duplicate location.
BACKEND_PORT=10004
render_nginx_config > "$TEST_DIR/result"
mv "$TEST_DIR/result" "$NGINX_FILE"
[[ $(grep -Fc 'location = /panel-c {' "$NGINX_FILE") == 1 ]]
grep -Fq 'proxy_pass http://127.0.0.1:10002;' "$NGINX_FILE"
grep -Fq 'proxy_pass http://127.0.0.1:10004;' "$NGINX_FILE"
if grep -Fq 'proxy_pass http://127.0.0.1:10003;' "$NGINX_FILE"; then exit 1; fi
echo 'PASS: distinct domains/certificates, preserved paths, port collision checks, idempotent updates'
