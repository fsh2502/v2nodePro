#!/usr/bin/env bash

set -euo pipefail

# Kept sourceable so regression tests exercise the actual config generator.
render_ws_location() {
    cat <<EOF
    location = $WS_PATH {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }
EOF
}

render_nginx_config() {
    if [[ -f "$NGINX_FILE" ]]; then
        if ! grep -q '^# Managed by v2nodePro setup-wss-proxy.sh' "$NGINX_FILE" ||
            [[ $(grep -c '^    location / {$' "$NGINX_FILE") != 1 ]]; then
            echo "File không còn đúng mẫu của script; cần kiểm tra thủ công: $NGINX_FILE" >&2
            return 1
        fi
        # Replace only the chosen exact path; preserve all other routes and TLS settings.
        awk -v target="$WS_PATH" -v replacement="$(render_ws_location)" '
            $1 == "location" && $2 == "=" && $3 == target { skip=1 }
            skip { if ($0 ~ /^    }[[:space:]]*$/) skip=0; next }
            /^    location \/ {$/ { print replacement; print "" }
            { print }
        ' "$NGINX_FILE"
        return
    fi
    cat <<EOF
# Managed by v2nodePro setup-wss-proxy.sh
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:V2NODE_WSS:10m;
    ssl_session_timeout 1d;

$(render_ws_location)

    location / {
        return 404;
    }
}
EOF
}

port_has_other_route() {
    local file
    for file in "$NGINX_DIR"/v2node-wss-*.conf; do
        [[ -f "$file" ]] || continue
        if awk -v selected="$NGINX_FILE" -v target="$WS_PATH" -v port="$1" '
            $1 == "location" && $2 == "=" { path=$3 }
            $1 == "proxy_pass" && $2 == "http://127.0.0.1:" port ";" {
                if (FILENAME != selected || path != target) found=1
            }
            END { exit !found }
        ' "$file"; then
            return 0
        fi
    done
    return 1
}

main() {
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Vui lòng chạy script bằng quyền root."
    exit 1
fi

prompt_value() {
    local variable_name="$1"
    local prompt="$2"
    local default_value="${3:-}"
    local current_value="${!variable_name:-}"
    if [[ -n "$current_value" ]]; then
        return
    fi
    if [[ -n "$default_value" ]]; then
        read -r -p "$prompt [$default_value]: " current_value
        current_value="${current_value:-$default_value}"
    else
        read -r -p "$prompt: " current_value
    fi
    printf -v "$variable_name" '%s' "$current_value"
}

DOMAIN="${DOMAIN:-${1:-}}"
WS_PATH="${WS_PATH:-${2:-}}"
BACKEND_PORT="${BACKEND_PORT:-${3:-}}"

prompt_value DOMAIN "Domain node, ví dụ node-a.example.com"
prompt_value WS_PATH "WebSocket path, ví dụ /shop-a"

DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"
DOMAIN="${DOMAIN,,}"
[[ "$WS_PATH" == /* ]] || WS_PATH="/$WS_PATH"
[[ "$WS_PATH" != "/" ]] || { echo "WebSocket path không được là /."; exit 1; }

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$DOMAIN" == .* ]] || [[ "$DOMAIN" == *. ]]; then
    echo "Domain không hợp lệ."
    exit 1
fi
if [[ ! "$WS_PATH" =~ ^/[A-Za-z0-9._~/-]+$ ]]; then
    echo "WebSocket path chỉ được chứa chữ, số và các ký tự . _ ~ / -."
    exit 1
fi
SAFE_DOMAIN="$DOMAIN"
CERT_DIR="/etc/v2node/proxy-certs"
CERT_FILE="$CERT_DIR/$SAFE_DOMAIN.cer"
KEY_FILE="$CERT_DIR/$SAFE_DOMAIN.key"
NGINX_DIR="/etc/nginx/conf.d"
NGINX_FILE="$NGINX_DIR/v2node-wss-$SAFE_DOMAIN.conf"
SUGGESTED_PORT=10001
while port_has_other_route "$SUGGESTED_PORT" ||
    { command -v ss >/dev/null 2>&1 && ss -H -lnt "sport = :$SUGGESTED_PORT" | grep -q .; }; do
    SUGGESTED_PORT=$((SUGGESTED_PORT + 1))
    (( SUGGESTED_PORT <= 65535 )) || { echo "Không tìm thấy cổng trống."; exit 1; }
done
prompt_value BACKEND_PORT "Cổng dịch vụ nội bộ (riêng cho node này)" "$SUGGESTED_PORT"
if [[ ! "$BACKEND_PORT" =~ ^[0-9]{1,5}$ ]]; then
    echo "Cổng nội bộ không hợp lệ."
    exit 1
fi
BACKEND_PORT=$((10#$BACKEND_PORT))
if (( BACKEND_PORT < 1 || BACKEND_PORT > 65535 || BACKEND_PORT == 443 )); then
    echo "Cổng nội bộ phải nằm trong 1-65535 và khác 443."
    exit 1
fi
if port_has_other_route "$BACKEND_PORT"; then
    echo "Cổng $BACKEND_PORT đã được path/domain khác sử dụng. Chọn cổng dịch vụ riêng."
    exit 1
fi

install_packages() {
    if command -v nginx >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
        return
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y nginx openssl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nginx openssl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nginx openssl ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache nginx openssl ca-certificates
    else
        echo "Không tìm thấy trình quản lý gói được hỗ trợ."
        exit 1
    fi
}

install_packages

mkdir -p "$CERT_DIR" "$NGINX_DIR"
if [[ -e "$CERT_FILE" || -e "$KEY_FILE" ]]; then
    if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
        echo "Chỉ có một phần của cặp chứng chỉ tồn tại. Không ghi đè: $CERT_FILE / $KEY_FILE"
        exit 1
    fi
else
    OPENSSL_CONFIG="$(mktemp)"
    TEMP_CERT="$(mktemp "$CERT_DIR/.${SAFE_DOMAIN}.cer.XXXXXX")"
    TEMP_KEY="$(mktemp "$CERT_DIR/.${SAFE_DOMAIN}.key.XXXXXX")"
    cleanup_certificate_temp() {
        rm -f "$OPENSSL_CONFIG" "$TEMP_CERT" "$TEMP_KEY"
    }
    trap cleanup_certificate_temp EXIT
    cat > "$OPENSSL_CONFIG" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $DOMAIN

[v3_req]
subjectAltName = DNS:$DOMAIN
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
    openssl req -newkey rsa:2048 -x509 -sha256 -days 10950 -nodes \
        -keyout "$TEMP_KEY" \
        -out "$TEMP_CERT" \
        -config "$OPENSSL_CONFIG"
    chmod 0644 "$TEMP_CERT"
    chmod 0600 "$TEMP_KEY"
    mv -f "$TEMP_CERT" "$CERT_FILE"
    mv -f "$TEMP_KEY" "$KEY_FILE"
    rm -f "$OPENSSL_CONFIG"
    trap - EXIT
fi
chmod 0644 "$CERT_FILE"
chmod 0600 "$KEY_FILE"

BACKUP_FILE=""
if [[ -f "$NGINX_FILE" ]]; then
    BACKUP_FILE="$NGINX_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$NGINX_FILE" "$BACKUP_FILE"
fi

TEMP_NGINX="$(mktemp "$NGINX_DIR/.v2node-wss.XXXXXX")"
if ! render_nginx_config > "$TEMP_NGINX"; then
    rm -f "$TEMP_NGINX"
    exit 1
fi
chmod 0644 "$TEMP_NGINX"
mv -f "$TEMP_NGINX" "$NGINX_FILE"

NGINX_CHECK="$(nginx -t 2>&1)" && NGINX_STATUS=0 || NGINX_STATUS=$?
printf '%s\n' "$NGINX_CHECK"
if (( NGINX_STATUS == 0 )) && ! nginx -T 2>/dev/null | grep -F "# configuration file $NGINX_FILE:" >/dev/null; then
    echo "Nginx chưa include $NGINX_FILE. Kiểm tra nginx.conf của bản Nginx đang chạy."
    NGINX_STATUS=1
fi
if (( NGINX_STATUS != 0 )) || [[ "$NGINX_CHECK" == *"conflicting server name"* ]]; then
    if [[ -n "$BACKUP_FILE" ]]; then
        cp -a "$BACKUP_FILE" "$NGINX_FILE"
    else
        rm -f "$NGINX_FILE"
    fi
    echo "Cấu hình Nginx không hợp lệ; đã khôi phục bản trước."
    exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
elif command -v rc-service >/dev/null 2>&1; then
    rc-update add nginx default >/dev/null 2>&1 || true
    rc-service nginx reload 2>/dev/null || rc-service nginx restart
else
    nginx -s reload 2>/dev/null || nginx
fi

cat <<EOF

Đã cấu hình WSS nhanh cho $DOMAIN.

Nhập đúng các giá trị sau trong node v2Pro:
  Host:                         $DOMAIN
  Server Name (SNI):             $DOMAIN
  Disable SNI:                  Tắt
  Cổng kết nối:                 443
  Listen IP:                    127.0.0.1
  Cổng dịch vụ:                 $BACKEND_PORT
  TLS:                          Bật
  TLS tại Nginx:                Bật
  Chế độ chứng chỉ:             Tự ký
  Cert File:                    $CERT_FILE
  Key File:                     $KEY_FILE
  Giao thức truyền tải:         WebSocket
  WebSocket path:               $WS_PATH
  WebSocket Host:               $DOMAIN
  Accept Proxy Protocol:        Tắt
  Ghim chứng chỉ tự động:       Bật

Sau khi lưu node:
  systemctl restart v2node
  nginx -t && systemctl reload nginx

Mỗi website phải có ApiHost + NodeID riêng trong /etc/v2node/config.json.
Dùng menu Node + WSS trong caidatserver.sh cho cài đặt mới; menu cũ đã được thay thế.
Domain ở trên là domain kết nối node, không phải địa chỉ API panel.
Nếu dùng chung domain cho nhiều panel, dùng cùng SNI/Host/cert nhưng path và cổng khác nhau.
Trỏ DNS domain node về VPS này. Ghim chứng chỉ này yêu cầu kết nối trực tiếp tới Nginx.
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
