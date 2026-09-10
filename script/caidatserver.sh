#!/usr/bin/env bash

V2NODE_CONFIG="/etc/v2node/config.json"
WSS_NGINX_DIR="${WSS_NGINX_DIR:-/etc/nginx/conf.d}"
WSS_BACKUP_ROOT="${WSS_BACKUP_ROOT:-/etc/v2node/wss-backups}"
WSS_MARKER='# Managed by v2nodePro setup-wss-proxy.sh'

wss_config_domain() {
    local file="$1" base domain configured_domain count
    [[ -f "$file" && ! -L "$file" ]] || return 1
    grep -Fxq "$WSS_MARKER" "$file" || return 1

    base="${file##*/}"
    [[ "$base" == v2node-wss-*.conf ]] || return 1
    domain="${base#v2node-wss-}"
    domain="${domain%.conf}"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ && "$domain" != .* && "$domain" != *. ]] || return 1

    configured_domain="$(awk '
        $1 == "server_name" {
            if (NF != 2 || $2 !~ /;$/) { print "__INVALID__"; next }
            value=$2
            sub(/;$/, "", value)
            print value
        }
    ' "$file")"
    count="$(printf '%s\n' "$configured_domain" | awk 'NF { count++ } END { print count+0 }')"
    [[ "$count" -eq 1 && "$configured_domain" == "$domain" ]] || return 1
    printf '%s\n' "$domain"
}

wss_config_routes() {
    awk '
        $1 == "location" && $2 == "=" { path=$3; next }
        path != "" && $1 == "proxy_pass" && $2 ~ /^http:\/\/127\.0\.0\.1:[0-9]+;$/ {
            backend=$2
            sub(/^http:\/\/127\.0\.0\.1:/, "", backend)
            sub(/;$/, "", backend)
            print path "\t" backend
            path=""
        }
    ' "$1"
}

wss_validate_routes() {
    awk '
        function invalid() { bad=1; exit }
        state == "route" {
            if ($0 ~ /^    }[[:space:]]*$/) {
                if (proxy_count != 1) invalid()
                print route_path "\t" backend
                state=""
                next
            }
            if ($0 ~ /[{}]/) invalid()
            if ($1 == "proxy_pass") {
                if (NF != 2 || $2 !~ /^http:\/\/127\.0\.0\.1:[0-9]+;$/) invalid()
                backend=$2
                sub(/^http:\/\/127\.0\.0\.1:/, "", backend)
                sub(/;$/, "", backend)
                if (backend + 0 < 1 || backend + 0 > 65535) invalid()
                proxy_count++
            }
            next
        }
        state == "fallback" {
            if ($0 ~ /^    }[[:space:]]*$/) { state=""; next }
            if ($0 ~ /[{}]/) invalid()
            next
        }
        /^    location = [^[:space:]]+ \{[[:space:]]*$/ {
            if (NF != 4 || $3 !~ /^\/[A-Za-z0-9._~\/-]+$/ || $3 == "/" || seen[$3]++) invalid()
            route_path=$3
            proxy_count=0
            backend=""
            state="route"
            next
        }
        /^    location \/ \{[[:space:]]*$/ {
            fallback_count++
            if (fallback_count != 1) invalid()
            state="fallback"
            next
        }
        $1 == "location" || $1 == "proxy_pass" { invalid() }
        END {
            if (bad || state != "" || fallback_count != 1) exit 1
        }
    ' "$1"
}

wss_render_without_route() {
    local file="$1" target_path="$2"
    awk -v target="$target_path" '
        !skip && $1 == "location" && $2 == "=" && $3 == target && $4 == "{" {
            skip=1
            removed++
            next
        }
        skip {
            if ($0 ~ /^    }[[:space:]]*$/) skip=0
            next
        }
        { print }
        END { if (skip || removed != 1) exit 1 }
    ' "$file"
}

wss_collect_configs() {
    local file domain
    WSS_FILES=()
    WSS_DOMAINS=()
    shopt -s nullglob
    for file in "$WSS_NGINX_DIR"/v2node-wss-*.conf; do
        if domain="$(wss_config_domain "$file")"; then
            WSS_FILES+=("$file")
            WSS_DOMAINS+=("$domain")
        fi
    done
    shopt -u nullglob
}

wss_print_entry() {
    local number="$1" domain="$2" file="$3" path backend
    printf '%s%s\n' "${number:+$number. }" "$domain"
    while IFS=$'\t' read -r path backend; do
        [[ -n "$path" ]] && printf '    path %s -> 127.0.0.1:%s\n' "$path" "$backend"
    done < <(wss_config_routes "$file")
}

list_wss_configs() {
    local index
    wss_collect_configs
    echo
    echo "====== WSS 443 đã cấu hình ======"
    if (( ${#WSS_FILES[@]} == 0 )); then
        echo "Không có cấu hình WSS 443 do v2nodePro quản lý."
        return 0
    fi
    for index in "${!WSS_FILES[@]}"; do
        wss_print_entry "$((index + 1))" "${WSS_DOMAINS[$index]}" "${WSS_FILES[$index]}"
    done
}

wss_test_nginx_config() {
    nginx -t
}

wss_reload_nginx() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload nginx
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service nginx reload
    else
        nginx -s reload
    fi
}

wss_restore_after_failure() {
    local backup_file="$1" target_file="$2"
    if ! cp -p "$backup_file" "$target_file"; then
        echo "Không thể khôi phục cấu hình từ $backup_file về $target_file." >&2
        return 1
    fi
    if wss_test_nginx_config >/dev/null 2>&1 && wss_reload_nginx >/dev/null 2>&1; then
        echo "Đã khôi phục cấu hình cũ và reload Nginx."
        return 0
    fi
    echo "Đã chép lại cấu hình cũ nhưng kiểm tra hoặc reload Nginx khi khôi phục thất bại." >&2
    return 1
}

delete_wss_config() {
    local selection selection_number index selected_file selected_domain confirmed_domain confirmation backup_dir backup_file
    local routes_output action action_number selected_path selected_backend current_routes temp_file remaining_count
    local -a routes
    wss_collect_configs
    if (( ${#WSS_FILES[@]} == 0 )); then
        echo "Không có cấu hình WSS 443 do v2nodePro quản lý."
        return 0
    fi

    echo
    echo "====== Chọn domain WSS 443 cần xóa ======"
    for index in "${!WSS_FILES[@]}"; do
        wss_print_entry "$((index + 1))" "${WSS_DOMAINS[$index]}" "${WSS_FILES[$index]}"
    done
    if ! read -r -p "Nhập số thứ tự (0 để hủy): " selection; then
        echo
        return 0
    fi
    if [[ "$selection" == 0 ]]; then
        echo "Đã hủy xóa WSS 443."
        return 0
    fi
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( ${#selection} > 6 )); then
        echo "Lựa chọn không hợp lệ."
        return 1
    fi
    selection_number=$((10#$selection))
    if (( selection_number < 1 || selection_number > ${#WSS_FILES[@]} )); then
        echo "Lựa chọn không hợp lệ."
        return 1
    fi

    index=$((selection_number - 1))
    selected_file="${WSS_FILES[$index]}"
    selected_domain="${WSS_DOMAINS[$index]}"
    if ! confirmed_domain="$(wss_config_domain "$selected_file")" || [[ "$confirmed_domain" != "$selected_domain" ]]; then
        echo "Tệp đã thay đổi, là symlink hoặc không còn do v2nodePro quản lý; từ chối xóa."
        return 1
    fi

    if ! routes_output="$(wss_validate_routes "$selected_file")"; then
        echo "Cấu hình WSS không còn đúng mẫu an toàn của v2nodePro; từ chối xóa."
        return 1
    fi
    mapfile -t routes <<< "$routes_output"
    if [[ -z "$routes_output" ]]; then
        routes=()
    fi

    echo
    echo "====== Chọn path WSS cần xóa trên $selected_domain ======"
    for index in "${!routes[@]}"; do
        IFS=$'\t' read -r selected_path selected_backend <<< "${routes[$index]}"
        printf '%s. path %s -> 127.0.0.1:%s\n' "$((index + 1))" "$selected_path" "$selected_backend"
    done
    echo "A. Xóa toàn bộ cấu hình của domain $selected_domain"
    if ! read -r -p "Nhập số path, A để xóa toàn domain, hoặc 0 để hủy: " action; then
        echo
        return 0
    fi
    if [[ "$action" == 0 ]]; then
        echo "Đã hủy xóa WSS 443."
        return 0
    fi
    if [[ "$action" =~ ^[Aa]$ ]]; then
        action="all"
        echo "Sẽ xóa toàn bộ cấu hình WSS của domain $selected_domain, gồm:"
        wss_print_entry "" "$selected_domain" "$selected_file"
        if ! read -r -p "Nhập chính xác 'XOA $selected_domain' để xác nhận: " confirmation ||
            [[ "$confirmation" != "XOA $selected_domain" ]]; then
            echo "Đã hủy xóa WSS 443."
            return 0
        fi
    else
        if [[ ! "$action" =~ ^[0-9]+$ ]] || (( ${#action} > 6 )); then
            echo "Lựa chọn path không hợp lệ."
            return 1
        fi
        action_number=$((10#$action))
        if (( action_number < 1 || action_number > ${#routes[@]} )); then
            echo "Lựa chọn path không hợp lệ."
            return 1
        fi
        action="path"
        IFS=$'\t' read -r selected_path selected_backend <<< "${routes[$((action_number - 1))]}"
        echo "Sẽ xóa đúng path $selected_path -> 127.0.0.1:$selected_backend trên $selected_domain."
        if ! read -r -p "Nhập chính xác 'XOA $selected_path' để xác nhận: " confirmation ||
            [[ "$confirmation" != "XOA $selected_path" ]]; then
            echo "Đã hủy xóa WSS 443."
            return 0
        fi
    fi

    if ! wss_test_nginx_config; then
        echo "Cấu hình Nginx hiện tại không hợp lệ; chưa xóa gì."
        return 1
    fi
    if ! confirmed_domain="$(wss_config_domain "$selected_file")" || [[ "$confirmed_domain" != "$selected_domain" ]]; then
        echo "Tệp đã thay đổi, là symlink hoặc không còn do v2nodePro quản lý; từ chối xóa."
        return 1
    fi
    if ! current_routes="$(wss_validate_routes "$selected_file")" || [[ "$current_routes" != "$routes_output" ]]; then
        echo "Danh sách path đã thay đổi hoặc cấu hình không còn đúng mẫu an toàn; từ chối xóa."
        return 1
    fi
    mkdir -p "$WSS_BACKUP_ROOT" || return 1
    backup_dir="$(mktemp -d "$WSS_BACKUP_ROOT/${selected_domain}.XXXXXX")" || return 1
    backup_file="$backup_dir/${selected_file##*/}"
    if ! cp -p "$selected_file" "$backup_file" || ! cmp -s "$selected_file" "$backup_file"; then
        echo "Không thể tạo và kiểm chứng bản sao lưu; chưa xóa gì." >&2
        return 1
    fi
    echo "Đã tạo bản sao lưu: $backup_file"
    if ! confirmed_domain="$(wss_config_domain "$selected_file")" || [[ "$confirmed_domain" != "$selected_domain" ]] ||
        ! cmp -s "$selected_file" "$backup_file"; then
        echo "Tệp đã thay đổi, là symlink hoặc không còn do v2nodePro quản lý; từ chối xóa."
        return 1
    fi

    if [[ "$action" == "all" ]]; then
        if ! rm -f -- "$selected_file"; then
            echo "Không thể xóa $selected_file; bản sao lưu ở $backup_file."
            return 1
        fi
    else
        temp_file="$(mktemp "$WSS_NGINX_DIR/.${selected_file##*/}.XXXXXX")" || return 1
        if ! cp -p "$selected_file" "$temp_file" ||
            ! wss_render_without_route "$selected_file" "$selected_path" > "$temp_file" ||
            ! current_routes="$(wss_validate_routes "$temp_file")"; then
            rm -f -- "$temp_file"
            echo "Không thể tạo cấu hình mới an toàn; chưa thay đổi tệp gốc." >&2
            return 1
        fi
        remaining_count="$(printf '%s\n' "$current_routes" | awk 'NF { count++ } END { print count+0 }')"
        if grep -Fqx "$selected_path"$'\t'"$selected_backend" <<< "$current_routes" ||
            (( remaining_count != ${#routes[@]} - 1 )); then
            rm -f -- "$temp_file"
            echo "Kết quả xóa path không duy nhất; chưa thay đổi tệp gốc." >&2
            return 1
        fi
        if [[ -L "$selected_file" ]] || ! cmp -s "$selected_file" "$backup_file"; then
            rm -f -- "$temp_file"
            echo "Tệp đã thay đổi trước khi thay thế; từ chối xóa." >&2
            return 1
        fi
        if ! mv -f -- "$temp_file" "$selected_file"; then
            rm -f -- "$temp_file"
            echo "Không thể thay cấu hình; bản sao lưu ở $backup_file." >&2
            return 1
        fi
    fi
    if ! wss_test_nginx_config; then
        echo "Cấu hình Nginx lỗi sau khi xóa; đang khôi phục."
        wss_restore_after_failure "$backup_file" "$selected_file" || true
        return 1
    fi
    if ! wss_reload_nginx; then
        echo "Reload Nginx thất bại sau khi xóa; đang khôi phục."
        wss_restore_after_failure "$backup_file" "$selected_file" || true
        return 1
    fi

    if [[ "$action" == "all" ]]; then
        echo "Đã xóa toàn bộ cấu hình WSS 443 của $selected_domain và reload Nginx."
    elif (( remaining_count == 0 )); then
        echo "Đã xóa path $selected_path và reload Nginx. File domain vẫn giữ TLS cùng fallback 404 để có thể thêm path mới."
    else
        echo "Đã xóa path $selected_path trên $selected_domain và reload Nginx; các path khác vẫn được giữ nguyên."
    fi
    echo "Các tệp chứng chỉ của $selected_domain vẫn được giữ nguyên."
    echo "Bản sao lưu: $backup_file"
}

main() {
while true; do
    clear
    echo "============== MENU CHỨC NĂNG v2.2 =============="
    echo "📦 QUẢN LÝ V2NODEPRO:"
    echo "  1.  Cài đặt V2nodePro"
    echo "  2.  Khởi động lại V2nodePro"
    echo "  3.  Gỡ cài đặt V2nodePro"
    echo
    echo "⚙️ TỐI ƯU & CÔNG CỤ:"
    echo "  4.  Tối ưu hóa VPS"
    echo "  5.  Speedtest VPS"
    echo "  6.  Chặn Speedtest"
    echo "  7.  Mở Speedtest"
    echo
    echo "🌐 CẤU HÌNH NODE & WSS:"
    echo "  8.  Thêm node"
    echo "  9.  Xóa node theo ApiHost + NodeID"
    echo " 10.  Cài nhanh WSS 443 cho một domain"
    echo " 11.  Xem danh sách WSS 443 đã cấu hình"
    echo " 12.  Xóa WSS 443 theo domain hoặc path"
    echo
    echo "❌  0. Thoát"
    echo "==============================================="
    if ! read -r -p "Chọn một tùy chọn [0-12]: " choice; then
        echo
        exit 0
    fi

    case $choice in
        1)
            # Cài đặt V2nodePro
            wget -N https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/install.sh && bash install.sh
            ;;
        2)
            if systemctl restart v2node >/dev/null 2>&1; then
                echo "✅ V2nodePro khởi động lại thành công!"
            else
                echo "❌ V2nodePro khởi động lại thất bại!"
            fi
            ;;
        3)
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
        4)
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
        5)
            # Speedtest VPS
            curl -Lso- bench.sh | bash
            ;;
        6)
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
        7)
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
        8)
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
        9)
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
        10)
            proxy_setup=$(mktemp) || continue
            if curl -fsSL https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/setup-wss-proxy.sh \
                -o "$proxy_setup"; then
                bash "$proxy_setup"
            else
                echo "Không tải được script WSS; chưa thay đổi cấu hình."
            fi
            rm -f "$proxy_setup"
            ;;
        11)
            list_wss_configs
            ;;
        12)
            delete_wss_config
            ;;
        0)
            echo "👋 Thoát..."
            exit 0
            ;;
        *)
            echo "❌ Lựa chọn không hợp lệ. Vui lòng thử lại."
            ;;
    esac

    if ! read -r -p $'\nNhấn Enter để quay lại menu...' temp; then
        echo
        exit 0
    fi
done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
