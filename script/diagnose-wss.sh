#!/usr/bin/env bash
# Read-only diagnostics. Does not print config.json, API keys or private keys.
set -u
if [[ $# != 3 ]]; then
    echo "Cách dùng: bash diagnose-wss.sh DOMAIN /PATH CONG_DICH_VU"
    exit 1
fi
DOMAIN="${1,,}"
WS_PATH="$2"
PORT="$3"
if [[ ! "$DOMAIN" =~ ^[a-z0-9][a-z0-9.-]+$ || ! "$WS_PATH" =~ ^/[A-Za-z0-9._~/-]+$ || ! "$PORT" =~ ^[0-9]{1,5}$ ]]; then
    echo "Domain/path/cổng không hợp lệ."
    exit 1
fi
PORT=$((10#$PORT))
(( PORT > 0 && PORT < 65536 )) || exit 1
for tool in curl nginx openssl; do
    command -v "$tool" >/dev/null || { echo "Thiếu công cụ $tool"; exit 1; }
done
printf '\nDomain=%s  Path=%s  Backend=127.0.0.1:%s\n' "$DOMAIN" "$WS_PATH" "$PORT"
nginx -t 2>&1
echo '--- Listeners ---'
if command -v ss >/dev/null; then
    ss -lntp "sport = :443 or sport = :$PORT"
fi
echo '--- Nginx mapping (không in khóa riêng) ---'
nginx -T 2>/dev/null | awk '
    /^# configuration file / || /^[[:space:]]*(listen|server_name|ssl_certificate|ssl_certificate_key|location|proxy_pass)[[:space:]]/ { print }
'
echo '--- Backend WS trực tiếp ---'
curl --noproxy '*' -sS --connect-timeout 2 --max-time 3 -D - -o /dev/null \
    -H "Host: $DOMAIN" -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "http://127.0.0.1:$PORT$WS_PATH"
echo '--- Qua Nginx, xác minh chứng chỉ domain tại VPS ---'
CERT_FILE="/etc/v2node/proxy-certs/$DOMAIN.cer"
if [[ -s "$CERT_FILE" ]]; then
    openssl x509 -in "$CERT_FILE" -noout -subject -dates -fingerprint -sha256
    curl --noproxy '*' -sS --http1.1 --connect-timeout 2 --max-time 3 -D - -o /dev/null \
        --cacert "$CERT_FILE" --resolve "$DOMAIN:443:127.0.0.1" \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        "https://$DOMAIN$WS_PATH"
else
    echo "Không tìm thấy chứng chỉ do script tạo: $CERT_FILE"
fi
cat <<'EOF'
--- Cách đọc ---
101 ở cả hai bước: đường truyền WS nội bộ và Nginx hoạt động.
curl timeout sau dòng 101 là bình thường: kết nối WebSocket đang mở.
Backend lỗi: kiểm tra v2node đã thêm ApiHost/NodeID, cổng, path và TLS tại Nginx.
Backend 101 nhưng Nginx 404: sai virtual host/path hoặc cấu hình Nginx bị trùng tên.
Nginx 502: sai upstream/cổng, listener chưa chạy hoặc quyền kết nối upstream bị chặn.
Lỗi chứng chỉ: sai SNI/chứng chỉ hoặc Nginx đang phục vụ cặp cert khác.
Nếu cả hai 101 nhưng app lỗi: kiểm tra DNS/CDN, SNI/Host và pin trong subscription,
sau đó kiểm tra tài khoản của đúng panel. Test 101 chưa xác minh đăng nhập Trojan/VLESS.
EOF
