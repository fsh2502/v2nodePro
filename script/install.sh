#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# Kiểm tra quyền root
[[ $EUID -ne 0 ]] && echo -e "${red}Lỗi:${plain} Phải chạy script này bằng quyền root!\n" && exit 1

# Kiểm tra hệ điều hành
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}Không phát hiện được phiên bản hệ thống, vui lòng liên hệ tác giả script!${plain}\n" && exit 1
fi

########################
# Phân tích tham số
########################
VERSION_ARG=""
API_HOST_ARG=""
NODE_ID_ARG=""
API_KEY_ARG=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-host)
                API_HOST_ARG="$2"; shift 2 ;;
            --node-id)
                NODE_ID_ARG="$2"; shift 2 ;;
            --api-key)
                API_KEY_ARG="$2"; shift 2 ;;
            -h|--help)
                echo "Cách dùng: $0 [phiên bản] [--api-host URL] [--node-id ID] [--api-key KEY]"
                exit 0 ;;
            --*)
                echo "Tham số không xác định: $1"; exit 1 ;;
            *)
                # Tương thích tham số vị trí đầu tiên làm phiên bản
                if [[ -z "$VERSION_ARG" ]]; then
                    VERSION_ARG="$1"; shift
                else
                    shift
                fi ;;
        esac
    done
}

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}Phát hiện kiến trúc thất bại, sử dụng kiến trúc mặc định: ${arch}${plain}"
fi

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "Phần mềm này không hỗ trợ hệ thống 32-bit (x86), vui lòng sử dụng hệ thống 64-bit (x86_64), nếu phát hiện sai vui lòng liên hệ tác giả"
    exit 2
fi

# Phiên bản hệ điều hành
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}Vui lòng sử dụng CentOS 7 hoặc phiên bản cao hơn!${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}Lưu ý: CentOS 7 không thể sử dụng giao thức hysteria1/2!${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}Vui lòng sử dụng Ubuntu 16 hoặc phiên bản cao hơn!${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}Vui lòng sử dụng Debian 8 hoặc phiên bản cao hơn!${plain}\n" && exit 1
    fi
fi

install_base() {
    # Phiên bản tối ưu: kiểm tra và cài đặt gói hàng loạt, giảm system call
    need_install_apt() {
        local packages=("$@")
        local missing=()

        # Kiểm tra hàng loạt các gói đã cài đặt
        local installed_list=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "Cài đặt các gói thiếu: ${missing[*]}"
            apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_yum() {
        local packages=("$@")
        local missing=()

        # Kiểm tra hàng loạt các gói đã cài đặt
        local installed_list=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "Cài đặt các gói thiếu: ${missing[*]}"
            yum install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_apk() {
        local packages=("$@")
        local missing=()

        # Kiểm tra hàng loạt các gói đã cài đặt
        local installed_list=$(apk info 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "Cài đặt các gói thiếu: ${missing[*]}"
            apk add --no-cache "${missing[@]}" >/dev/null 2>&1
        fi
    }

    # Cài đặt tất cả các gói cần thiết một lần
    if [[ x"${release}" == x"centos" ]]; then
        # Kiểm tra và cài đặt epel-release
        if ! rpm -q epel-release >/dev/null 2>&1; then
            echo "Cài đặt nguồn EPEL..."
            yum install -y epel-release >/dev/null 2>&1
        fi
        need_install_yum wget curl unzip tar cronie socat ca-certificates pv
        update-ca-trust force-enable >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"alpine" ]]; then
        need_install_apk wget curl unzip tar socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"debian" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"ubuntu" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"arch" ]]; then
        echo "Cập nhật cơ sở dữ liệu gói..."
        pacman -Sy --noconfirm >/dev/null 2>&1
        # --needed sẽ bỏ qua các gói đã cài đặt, rất hiệu quả
        echo "Cài đặt các gói cần thiết..."
        pacman -S --noconfirm --needed wget curl unzip tar cronie socat ca-certificates pv >/dev/null 2>&1
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/v2node/v2node ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service v2node status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status v2node | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

generate_v2node_config() {
        local api_host="$1"
        local node_id="$2"
        local api_key="$3"

        mkdir -p /etc/v2node >/dev/null 2>&1
        cat > /etc/v2node/config.json <<EOF
{
    "Log": {
        "Level": "none",
        "Output": "",
        "Access": "none"
    },
    "Nodes": [
        {
            "ApiHost": "${api_host}",
            "NodeID": ${node_id},
            "ApiKey": "${api_key}",
            "Timeout": 15
        }
    ]
}
EOF
        echo -e "${green}Tạo file cấu hình V2node hoàn tất, đang khởi động lại dịch vụ${plain}"
        if [[ x"${release}" == x"alpine" ]]; then
            service v2node restart
        else
            systemctl restart v2node
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}v2node khởi động lại thành công${plain}"
        else
            echo -e "${red}v2node có thể khởi động thất bại, vui lòng dùng v2node log để xem nhật ký${plain}"
        fi
}

install_v2node() {
    local version_param="$1"
    if [[ -e /usr/local/v2node/ ]]; then
        rm -rf /usr/local/v2node/
    fi

    mkdir /usr/local/v2node/ -p
    cd /usr/local/v2node/

    if  [[ -z "$version_param" ]] ; then
        last_version=$(curl -Ls "https://api.github.com/repos/fsh2502/v2nodePro/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}Phát hiện phiên bản v2node thất bại, có thể do vượt giới hạn Github API, vui lòng thử lại sau hoặc chỉ định phiên bản cài đặt${plain}"
            exit 1
        fi
        echo -e "${green}Phát hiện phiên bản mới nhất: ${last_version}, bắt đầu cài đặt...${plain}"
        url="https://github.com/fsh2502/v2nodePro/releases/download/${last_version}/v2node-linux-${arch}.zip"
        curl -sL "$url" | pv -s 30M -W -N "Tiến trình tải" > /usr/local/v2node/v2node-linux.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Tải v2node thất bại, vui lòng đảm bảo server của bạn có thể tải file từ Github${plain}"
            exit 1
        fi
    else
    last_version=$version_param
        url="https://github.com/fsh2502/v2nodePro/releases/download/${last_version}/v2node-linux-${arch}.zip"
        curl -sL "$url" | pv -s 30M -W -N "Tiến trình tải" > /usr/local/v2node/v2node-linux.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Tải v2node $1 thất bại, vui lòng đảm bảo phiên bản này tồn tại${plain}"
            exit 1
        fi
    fi

    unzip v2node-linux.zip
    rm v2node-linux.zip -f
    chmod +x v2node
    mkdir /etc/v2node/ -p
    cp geoip.dat /etc/v2node/
    cp geosite.dat /etc/v2node/
    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/v2node -f
        cat <<EOF > /etc/init.d/v2node
#!/sbin/openrc-run

name="v2node"
description="v2node"

command="/usr/local/v2node/v2node"
command_args="server"
command_user="root"

pidfile="/run/v2node.pid"
command_background="yes"

depend() {
        need net
}
EOF
        chmod +x /etc/init.d/v2node
        rc-update add v2node default
        echo -e "${green}v2node ${last_version}${plain} cài đặt hoàn tất, đã thiết lập tự động khởi động cùng hệ thống"
    else
        rm /etc/systemd/system/v2node.service -f
        cat <<EOF > /etc/systemd/system/v2node.service
[Unit]
Description=v2node Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/v2node/
ExecStart=/usr/local/v2node/v2node server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop v2node
        systemctl enable v2node
        echo -e "${green}v2node ${last_version}${plain} cài đặt hoàn tất, đã thiết lập tự động khởi động cùng hệ thống"
    fi

    if [[ ! -f /etc/v2node/config.json ]]; then
        # Nếu truyền đủ tham số qua CLI, tạo cấu hình và bỏ qua tương tác
        if [[ -n "$API_HOST_ARG" && -n "$NODE_ID_ARG" && -n "$API_KEY_ARG" ]]; then
            generate_v2node_config "$API_HOST_ARG" "$NODE_ID_ARG" "$API_KEY_ARG"
            echo -e "${green}Đã tạo /etc/v2node/config.json từ tham số${plain}"
            first_install=false
        else
            cp config.json /etc/v2node/
            first_install=true
        fi
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service v2node start
        else
            systemctl start v2node
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}v2node khởi động lại thành công${plain}"
        else
            echo -e "${red}v2node có thể khởi động thất bại, vui lòng dùng v2node log để xem nhật ký${plain}"
        fi
        first_install=false
    fi


    curl -o /usr/bin/v2node -Ls https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/v2node.sh
    chmod +x /usr/bin/v2node

    cd $cur_dir
    rm -f install.sh
    echo "------------------------------------------"
    echo -e "Cách sử dụng script quản lý: "
    echo "------------------------------------------"
    echo "v2node              - Hiển thị menu quản lý (nhiều chức năng hơn)"
    echo "v2node start        - Khởi động v2node"
    echo "v2node stop         - Dừng v2node"
    echo "v2node restart      - Khởi động lại v2node"
    echo "v2node status       - Xem trạng thái v2node"
    echo "v2node enable       - Bật tự động khởi động cùng hệ thống"
    echo "v2node disable      - Tắt tự động khởi động cùng hệ thống"
    echo "v2node log          - Xem nhật ký v2node"
    echo "v2node generate     - Tạo file cấu hình v2node"
    echo "v2node update       - Cập nhật v2node"
    echo "v2node update x.x.x - Cập nhật v2node phiên bản chỉ định"
    echo "v2node install      - Cài đặt v2node"
    echo "v2node uninstall    - Gỡ cài đặt v2node"
    echo "v2node version      - Xem phiên bản v2node"
    echo "------------------------------------------"
    curl -fsS --max-time 10 "https://api.v-50.me/counter" || true

    if [[ $first_install == true ]]; then
        read -rp "Phát hiện đây là lần đầu cài đặt v2node, bạn có muốn tự động tạo /etc/v2node/config.json? (y/n): " if_generate
        if [[ "$if_generate" =~ ^[Yy]$ ]]; then
            # Thu thập tham số tương tác, cung cấp giá trị mặc định mẫu
            read -rp "Địa chỉ API panel [định dạng: https://example.com/]: " api_host
            api_host=${api_host:-https://example.com/}
            read -rp "Node ID: " node_id
            node_id=${node_id:-1}
            read -rp "Khóa giao tiếp node: " api_key

            # Tạo file cấu hình (ghi đè template có thể đã sao chép từ gói)
            generate_v2node_config "$api_host" "$node_id" "$api_key"
        else
            echo "${green}Đã bỏ qua tự động tạo cấu hình. Nếu cần tạo sau, chạy: v2node generate${plain}"
        fi
    fi
}

parse_args "$@"
echo -e "${green}Bắt đầu cài đặt${plain}"
install_base
install_v2node "$VERSION_ARG"
