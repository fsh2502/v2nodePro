CONF_FILE="/etc/nginx/sites-available/default"
V2NODE_CONFIG="/etc/v2node/config.json"

while true; do
    clear
    echo "============== MENU CHỨC NĂNG v2.2 =============="
    echo "📦 CÀI ĐẶT:"
    echo "  1.  Cài đặt NAT Proxy"
    echo "  2.  Cài đặt V2nodePro"
    echo
    echo "🔧 QUẢN LÝ DỊCH VỤ:"
    echo "  3.  Khởi động lại NAT Proxy"
    echo "  4.  Khởi động lại V2nodePro"
    echo "  5.  Gỡ cài đặt NAT Proxy"
    echo "  6.  Gỡ cài đặt V2nodePro"
    echo
    echo "⚙️ TỐI ƯU & CÔNG CỤ:"
    echo "  7.  Tối ưu hóa VPS"
    echo "  8.  Speedtest VPS"
    echo "  9.  Chặn Speedtest"
    echo " 10.  Mở Speedtest"
    echo
    echo "🌐 QUẢN LÝ PROXY PATH:"
    echo " 11.  Thêm node"
    echo " 12.  Xóa node theo ApiHost + NodeID"
    echo " 13.  Thêm path mới"
    echo " 14.  Xóa path"
    echo " 15.  Sửa path"
    echo " 16.  Xem danh sách NAT"
    echo
    echo "❌ 17. Thoát"
    echo "==============================================="
    read -p "Chọn một tùy chọn [1-17]: " choice

    case $choice in
        1)
            # — Nhập thông số trước khi cài đặt
            read -p "Nhập port dịch vụ Web 1 (port 80): " ip_port_80
            read -p "Nhập path port 80 Web 1: " path80

            (
                exec >/dev/null 2>&1

                # Cài gói cần thiết
                if [[ -f /etc/centos-release ]]; then
                    yum install -y epel-release openssl wget curl unzip tar crontabs socat nginx
                    firewall-cmd --zone=public --add-port=80/tcp --permanent
                    firewall-cmd --zone=public --add-port=443/tcp --permanent
                    firewall-cmd --reload
                else
                    apt update -y
                    apt install -y openssl wget curl unzip tar cron socat nginx
                    ufw allow 80; ufw allow 443; ufw allow 'Nginx HTTP'
                fi

                curl https://get.acme.sh | sh
                openssl req -newkey rsa:2048 -x509 -sha256 -days 365 -nodes \
                    -out /root/ssl.crt \
                    -keyout /root/ssl.key \
                    -subj "/C=JP/ST=Tokyo/L=Chiyoda-ku/O=MyOrg/CN=localhost"

                cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 100000;
error_log /var/log/nginx/error.log crit;
pid /run/nginx.pid;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    default_type application/octet-stream;
    server_tokens off;
    access_log off;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    ssl_protocols TLSv1.3 TLSv1.2;
    ssl_prefer_server_ciphers on;
    ssl_ciphers EECDH+AESGCM:EECDH+CHACHA20;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_buffer_size 4k;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    open_file_cache max=200000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;

    gzip on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript application/xml+rss text/xml application/xml font/ttf font/otf font/eot font/woff font/woff2 image/svg+xml;
    gzip_vary on;
    gzip_proxied any;

    client_max_body_size 100M;
    client_body_buffer_size 16K;
    output_buffers 2 1m;
    postpone_output 1460;

    include /etc/nginx/mime.types;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

                cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    listen 443 ssl http2;
    server_name localhost;

    ssl_certificate /root/ssl.crt;
    ssl_certificate_key /root/ssl.key;

    access_log off;
    error_log /var/log/nginx/default_error.log crit;

    location /$path80 {
        proxy_pass http://0.0.0.0:$ip_port_80;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_buffering off;
        client_max_body_size 0;
    }

}
EOF

                systemctl restart nginx
            ) &
            install_pid=$!

            for i in $(seq 1 100); do
                if ! kill -0 $install_pid 2>/dev/null; then
                    break
                fi
                printf "\r🔧 Đang cài đặt NAT Proxy... %3d%%" "$i"
                sleep 0.1
            done
            wait $install_pid
            printf "\r✅ Cài đặt NAT Proxy hoàn tất!            \n"
            ;;
        2)
            # Cài đặt V2nodePro
            wget -N https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/install.sh && bash install.sh
            ;;
        3)
            if systemctl restart nginx >/dev/null 2>&1; then
                echo "✅ NAT Proxy khởi động thành công!"
            else
                echo "❌ NAT Proxy bị lỗi!"
            fi
            ;;
        4)
            systemctl restart nginx >/dev/null 2>&1
            systemctl v2node restart >/dev/null 2>&1
            echo "✅ V2nodePro khởi động lại thành công!"
            ;;
        5)
            exec 3>&1 4>&2 >/dev/null 2>&1
            show_loading() {
                for i in $(seq 1 100); do
                    printf "\r🔧 Đang gỡ NAT Proxy... %3d%%" "$i"
                    sleep 0.02
                done
                echo
            }
            remove_nginx() {
                if [ -f /etc/debian_version ]; then
                    systemctl stop nginx
                    apt remove --purge -y nginx nginx-common
                    apt autoremove -y
                elif [ -f /etc/redhat-release ]; then
                    systemctl stop nginx
                    if command -v dnf &>/dev/null; then
                        dnf remove -y nginx
                    else
                        yum remove -y nginx
                    fi
                fi
                rm -rf /etc/nginx /var/log/nginx /var/www/html
            }
            show_loading & remove_nginx &
            wait
            exec 1>&3 2>&4
            echo "✅ Gỡ NAT Proxy hoàn tất!"
            ;;
        6)
            if command -v v2node >/dev/null 2>&1; then
                v2node uninstall
                rm -f /usr/bin/v2node
            elif systemctl list-unit-files | grep -q '^v2node\.service'; then
                systemctl stop v2node >/dev/null 2>&1
                systemctl disable v2node >/dev/null 2>&1
                rm -f /etc/systemd/system/v2node.service
                systemctl daemon-reload >/dev/null 2>&1
                rm -rf /etc/v2node /usr/local/v2node
                rm -f /usr/bin/v2node
                echo "✅ Gỡ cài đặt V2nodePro hoàn tất!"
            else
                echo "⚠️ Không tìm thấy V2nodePro trên máy."
            fi
            ;;
        7)
            # Tối ưu hóa VPS (sysctl)
            cat > /etc/sysctl.conf <<EOF
fs.file-max=1000000
fs.inotify.max_user_instances=65536
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.ipv4.ip_local_port_range=80 65535
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.lo.forwarding=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_retries1=3
net.ipv4.tcp_retries2=5
net.ipv4.tcp_orphan_retries=3
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_tw_recycle=1
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_max_tw_buckets=10000
net.ipv4.tcp_max_syn_backlog=131072
net.core.netdev_max_backlog=131072
net.core.somaxconn=32768
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_autocorking=0
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=-2
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=335544320
net.core.wmem_max=335544320
net.ipv4.tcp_rmem=8192 262144 536870912
net.ipv4.tcp_wmem=4096 16384 536870912
net.ipv4.tcp_collapse_max_bytes=6291456
net.ipv4.tcp_notsent_lowat=131072
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.tcp_mem=262144 1048576 4194304
net.ipv4.udp_mem=262144 1048576 4194304
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.ping_group_range=0 2147483647
EOF
            sysctl -p >/dev/null 2>&1
            echo "✅ Tối ưu hóa VPS hoàn tất!"
            ;;
        8)
            # Speedtest VPS
            curl -Lso- bench.sh | bash
            ;;
       9)
            # Chặn Speedtest
            for domain in \
                www.speedtest.net speedtest.vn fast.com www.speedcheck.org speedtest.vnpt.vn \
                pcmag.speedtestcustom.com www.speed.io speedtest.telstra.com www.orange.md \
                speedtest.cesnet.cz speedtest.xfinity.com www.nperf.com www.speakeasy.net \
                www.highspeedinternet.com speed.cloudflare.com proof.ovh.net; do
                echo "127.0.0.1   $domain" >> /etc/hosts
            done
            echo "✅ Đã chặn Speedtest!"
            ;;
       10)
            # Mở Speedtest
            domains=(
                "www.speedtest.net" "speedtest.vn" "fast.com" "www.speedcheck.org" "speedtest.vnpt.vn"
                "pcmag.speedtestcustom.com" "www.speed.io" "speedtest.telstra.com" "www.orange.md"
                "speedtest.cesnet.cz" "speedtest.xfinity.com" "www.nperf.com" "www.speakeasy.net"
                "www.highspeedinternet.com" "speed.cloudflare.com" "proof.ovh.net"
            )
            for domain in "${domains[@]}"; do
                sed -i "/$domain/d" /etc/hosts
            done
            echo "✅ Đã mở Speedtest!"
            ;;
       11)
            # Thêm node
            read -p "Nhập ApiHost (ví dụ: apiwebcuaban.com): " api_host
            read -p "Nhập NodeID (ví dụ: 1): " node_id
            read -p "Nhập ApiKey: " api_key
            read -p "Nhập Timeout (mặc định 15): " node_timeout

            api_host="${api_host#http://}"
            api_host="${api_host#https://}"
            api_host="${api_host%/}"

            if [[ -z "$node_timeout" ]]; then
                node_timeout=15
            fi

            if [[ -z "$api_host" || -z "$api_key" || ! "$node_id" =~ ^[0-9]+$ || ! "$node_timeout" =~ ^[0-9]+$ ]]; then
                echo "❌ Dữ liệu không hợp lệ. ApiHost/ApiKey không được để trống và NodeID/Timeout phải là số."
                continue
            fi

            api_host="https://$api_host"

            mkdir -p "$(dirname "$V2NODE_CONFIG")"

            if [[ ! -f "$V2NODE_CONFIG" ]]; then
                cat > "$V2NODE_CONFIG" <<EOF
{
    "Log": {
        "Level": "none",
        "Output": "",
        "Access": "none"
    },
    "Nodes": []
}
EOF
            fi

            if ! command -v python3 >/dev/null 2>&1; then
                echo "❌ Không tìm thấy python3 để cập nhật $V2NODE_CONFIG"
                continue
            fi

            if API_HOST="$api_host" NODE_ID="$node_id" API_KEY="$api_key" NODE_TIMEOUT="$node_timeout" CONFIG_PATH="$V2NODE_CONFIG" python3 - <<'PY'
import json
import os

config_path = os.environ["CONFIG_PATH"]
api_host = os.environ["API_HOST"].strip()
node_id = int(os.environ["NODE_ID"])
api_key = os.environ["API_KEY"].strip()
node_timeout = int(os.environ["NODE_TIMEOUT"])

def normalize_api_host(value: str) -> str:
    value = value.strip().rstrip("/")
    if value.startswith("https://"):
        value = value[len("https://"):]
    elif value.startswith("http://"):
        value = value[len("http://"):]
    return value

with open(config_path, "r", encoding="utf-8") as f:
    data = json.load(f)

if not isinstance(data, dict):
    raise ValueError("Config không đúng định dạng JSON object")

data.setdefault("Log", {
    "Level": "none",
    "Output": "",
    "Access": "none",
})
nodes = data.setdefault("Nodes", [])
if not isinstance(nodes, list):
    raise ValueError("Trường Nodes không phải mảng")

for node in nodes:
    if (
        normalize_api_host(str(node.get("ApiHost", ""))) == normalize_api_host(api_host) and
        node.get("NodeID") == node_id
    ):
        raise SystemExit(2)

nodes.append({
    "ApiHost": api_host,
    "NodeID": node_id,
    "ApiKey": api_key,
    "Timeout": node_timeout,
})

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=4)
    f.write("\n")
PY
            then
                echo "✅ Đã thêm node NodeID=$node_id vào $V2NODE_CONFIG"
                if systemctl list-unit-files | grep -q '^v2node\.service'; then
                    systemctl restart v2node >/dev/null 2>&1
                    echo "✅ Đã khởi động lại V2nodePro để áp dụng cấu hình mới"
                fi
            else
                status=$?
                if [[ $status -eq 2 ]]; then
                    echo "⚠️ Node có ApiHost=$api_host và NodeID=$node_id đã tồn tại trong $V2NODE_CONFIG"
                else
                    echo "❌ Không thể cập nhật $V2NODE_CONFIG. Vui lòng kiểm tra lại dữ liệu nhập."
                fi
            fi
            ;;
       12)
            # Xóa node theo ApiHost + NodeID
            if [[ ! -f "$V2NODE_CONFIG" ]]; then
                echo "⚠️ Không tìm thấy $V2NODE_CONFIG"
                continue
            fi

            read -p "Nhập ApiHost của node cần xóa: " delete_api_host
            read -p "Nhập NodeID cần xóa: " delete_node_id
            delete_api_host="${delete_api_host#http://}"
            delete_api_host="${delete_api_host#https://}"
            delete_api_host="${delete_api_host%/}"
            if [[ -z "$delete_api_host" || ! "$delete_node_id" =~ ^[0-9]+$ ]]; then
                echo "❌ ApiHost không được để trống và NodeID phải là số."
                continue
            fi

            if ! command -v python3 >/dev/null 2>&1; then
                echo "❌ Không tìm thấy python3 để cập nhật $V2NODE_CONFIG"
                continue
            fi

            if API_HOST="$delete_api_host" NODE_ID="$delete_node_id" CONFIG_PATH="$V2NODE_CONFIG" python3 - <<'PY'
import json
import os

config_path = os.environ["CONFIG_PATH"]
api_host = os.environ["API_HOST"].strip()
node_id = int(os.environ["NODE_ID"])

def normalize_api_host(value: str) -> str:
    value = value.strip().rstrip("/")
    if value.startswith("https://"):
        value = value[len("https://"):]
    elif value.startswith("http://"):
        value = value[len("http://"):]
    return value

with open(config_path, "r", encoding="utf-8") as f:
    data = json.load(f)

if not isinstance(data, dict):
    raise ValueError("Config không đúng định dạng JSON object")

nodes = data.get("Nodes", [])
if not isinstance(nodes, list):
    raise ValueError("Trường Nodes không phải mảng")

new_nodes = [
    node for node in nodes
    if not (
        normalize_api_host(str(node.get("ApiHost", ""))) == normalize_api_host(api_host) and
        node.get("NodeID") == node_id
    )
]
removed = len(nodes) - len(new_nodes)
if removed == 0:
    raise SystemExit(2)

data["Nodes"] = new_nodes

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=4)
    f.write("\n")
PY
            then
                echo "✅ Đã xóa node ApiHost=$delete_api_host, NodeID=$delete_node_id khỏi $V2NODE_CONFIG"
                if systemctl list-unit-files | grep -q '^v2node\.service'; then
                    systemctl restart v2node >/dev/null 2>&1
                    echo "✅ Đã khởi động lại V2nodePro để áp dụng cấu hình mới"
                fi
            else
                status=$?
                if [[ $status -eq 2 ]]; then
                    echo "⚠️ Không tìm thấy node có ApiHost=$delete_api_host và NodeID=$delete_node_id trong $V2NODE_CONFIG"
                else
                    echo "❌ Không thể cập nhật $V2NODE_CONFIG. Vui lòng kiểm tra lại file cấu hình."
                fi
            fi
            ;;
       13)
            # Thêm path mới
            read -p "Nhập đường dẫn (ví dụ: myapp): " new_path
            read -p "Nhập port backend (ví dụ: 8080): " new_port

            proxy_block=$(cat <<EOF
    # — Proxy thêm bởi menu
    location /$new_path {
        proxy_pass http://0.0.0.0:$new_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_buffering off;
        client_max_body_size 0;
    }

EOF
)
            tmp_file=$(mktemp)
            awk -v block="$proxy_block" '
                BEGIN { inserted=0 }
                {
                    if ($0 ~ /^}/ && !inserted) {
                        print block;
                        inserted = 1;
                    }
                    print;
                }
            ' "$CONF_FILE" > "$tmp_file" && mv "$tmp_file" "$CONF_FILE"
            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx
                echo "✅ Đã thêm proxy /$new_path → port $new_port"
            else
                echo "❌ Lỗi cấu hình Nginx! Khôi phục file cũ..."
            fi
            ;;
       14)
            # Xóa path
            read -p "Nhập đường dẫn cần xóa (ví dụ: myapp): " del_path
            if grep -q "location /$del_path" "$CONF_FILE"; then
                sed -i "/location \/$del_path {/,/}/d" "$CONF_FILE"
                if nginx -t >/dev/null 2>&1; then
                    systemctl reload nginx
                    echo "✅ Đã xóa proxy /$del_path"
                else
                    echo "❌ Lỗi cấu hình Nginx sau khi xóa, kiểm tra lại!"
                fi
            else
                echo "⚠️ Không tìm thấy proxy /$del_path trong cấu hình."
            fi
            ;;
       15)
            # Sửa path
            read -p "Nhập đường dẫn cũ cần sửa (ví dụ: myapp): " edit_path
            if grep -q "location /$edit_path" "$CONF_FILE"; then
                cp "$CONF_FILE" "$CONF_FILE.bak"
                sed -i "/location \/$edit_path {/,/}/d" "$CONF_FILE"
                read -p "Nhập đường dẫn mới (ví dụ: newapp): " new_path2
                read -p "Nhập port backend mới (ví dụ: 9090): " new_port2
                proxy_block=$(cat <<EOF
    # — Proxy sửa bởi menu
    location /$new_path2 {
        proxy_pass http://0.0.0.0:$new_port2;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_buffering off;
        client_max_body_size 0;
    }

EOF
)
                tmp_file=$(mktemp)
                awk -v block="$proxy_block" '
                    BEGIN { inserted=0 }
                    {
                        if ($0 ~ /^}/ && !inserted) {
                            print block;
                            inserted = 1;
                        }
                        print;
                    }
                ' "$CONF_FILE" > "$tmp_file" && mv "$tmp_file" "$CONF_FILE"
                if nginx -t >/dev/null 2>&1; then
                    systemctl reload nginx
                    echo "✅ Đã cập nhật proxy /$edit_path → /$new_path2 port $new_port2"
                else
                    echo "❌ Lỗi cấu hình Nginx sau khi sửa. Khôi phục file cũ."
                    mv "$CONF_FILE.bak" "$CONF_FILE"
                    nginx -t && systemctl reload nginx
                fi
            else
                echo "⚠️ Không tìm thấy proxy /$edit_path trong cấu hình."
            fi
            ;;
       16)
            # Xem danh sách NAT
            echo
            echo "====== Danh sách proxy path ======"
            current_path=""
            while IFS= read -r line; do
                if [[ $line =~ ^[[:space:]]*location[[:space:]]+(/[^[:space:]]+)[[:space:]]*\{ ]]; then
                    current_path="${BASH_REMATCH[1]}"
                elif [[ $line =~ proxy_pass[[:space:]]+http://[^:]+:([0-9]+)\; ]]; then
                    port="${BASH_REMATCH[1]}"
                    echo "• $current_path → port $port"
                    current_path=""
                fi
            done < "$CONF_FILE"
            if ! grep -q "^[[:space:]]*location /" "$CONF_FILE"; then
                echo "⚠️  Không tìm thấy proxy nào trong $CONF_FILE."
            fi
            ;;
       17)
            echo "👋 Thoát..."
            exit 0
            ;;
        *)
            echo "❌ Lựa chọn không hợp lệ. Vui lòng thử lại."
            ;;
    esac

    read -p $'\nNhấn Enter để quay lại menu...' temp
done
