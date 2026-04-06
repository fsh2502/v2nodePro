#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Loi:${plain} Phai chay script nay bang quyen root!\n" && exit 1

# check os
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
    echo -e "${red}Khong phat hien duoc phien ban he thong, vui long lien he tac gia script!${plain}\n" && exit 1
fi

########################
# Phan tich tham so
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
                echo "Cach dung: $0 [phien ban] [--api-host URL] [--node-id ID] [--api-key KEY]"
                exit 0 ;;
            --*)
                echo "Tham so khong xac dinh: $1"; exit 1 ;;
            *)
                # Tuong thich tham so vi tri dau tien lam phien ban
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
    echo -e "${red}Phat hien kien truc that bai, su dung kien truc mac dinh: ${arch}${plain}"
fi

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "Phan mem nay khong ho tro he thong 32-bit (x86), vui long su dung he thong 64-bit (x86_64), neu phat hien sai vui long lien he tac gia"
    exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}Vui long su dung CentOS 7 hoac phien ban cao hon!${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}Luu y: CentOS 7 khong the su dung giao thuc hysteria1/2!${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}Vui long su dung Ubuntu 16 hoac phien ban cao hon!${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}Vui long su dung Debian 8 hoac phien ban cao hon!${plain}\n" && exit 1
    fi
fi

install_base() {
    # Phien ban toi uu: kiem tra va cai dat goi hang loat, giam system call
    need_install_apt() {
        local packages=("$@")
        local missing=()

        # Kiem tra hang loat cac goi da cai dat
        local installed_list=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "Cai dat cac goi thieu: ${missing[*]}"
            apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_yum() {
        local packages=("$@")
        local missing=()

        # Kiem tra hang loat cac goi da cai dat
        local installed_list=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "Cai dat cac goi thieu: ${missing[*]}"
            yum install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_apk() {
        local packages=("$@")
        local missing=()

        # Kiem tra hang loat cac goi da cai dat
        local installed_list=$(apk info 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "Cai dat cac goi thieu: ${missing[*]}"
            apk add --no-cache "${missing[@]}" >/dev/null 2>&1
        fi
    }

    # Cai dat tat ca cac goi can thiet mot lan
    if [[ x"${release}" == x"centos" ]]; then
        # Kiem tra va cai dat epel-release
        if ! rpm -q epel-release >/dev/null 2>&1; then
            echo "Cai dat nguon EPEL..."
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
        echo "Cap nhat co so du lieu goi..."
        pacman -Sy --noconfirm >/dev/null 2>&1
        # --needed se bo qua cac goi da cai dat, rat hieu qua
        echo "Cai dat cac goi can thiet..."
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
        "Level": "warning",
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
        echo -e "${green}Tao file cau hinh V2node hoan tat, dang khoi dong lai dich vu${plain}"
        if [[ x"${release}" == x"alpine" ]]; then
            service v2node restart
        else
            systemctl restart v2node
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}v2node khoi dong lai thanh cong${plain}"
        else
            echo -e "${red}v2node co the khoi dong that bai, vui long dung v2node log de xem nhat ky${plain}"
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
            echo -e "${red}Phat hien phien ban v2node that bai, co the do vuot gioi han Github API, vui long thu lai sau hoac chi dinh phien ban cai dat${plain}"
            exit 1
        fi
        echo -e "${green}Phat hien phien ban moi nhat: ${last_version}, bat dau cai dat...${plain}"
        url="https://github.com/fsh2502/v2nodePro/releases/download/${last_version}/v2node-linux-${arch}.zip"
        curl -sL "$url" | pv -s 30M -W -N "Tien trinh tai" > /usr/local/v2node/v2node-linux.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Tai v2node that bai, vui long dam bao server cua ban co the tai file tu Github${plain}"
            exit 1
        fi
    else
    last_version=$version_param
        url="https://github.com/fsh2502/v2nodePro/releases/download/${last_version}/v2node-linux-${arch}.zip"
        curl -sL "$url" | pv -s 30M -W -N "Tien trinh tai" > /usr/local/v2node/v2node-linux.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Tai v2node $1 that bai, vui long dam bao phien ban nay ton tai${plain}"
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
        echo -e "${green}v2node ${last_version}${plain} cai dat hoan tat, da thiet lap tu dong khoi dong cung he thong"
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
        echo -e "${green}v2node ${last_version}${plain} cai dat hoan tat, da thiet lap tu dong khoi dong cung he thong"
    fi

    if [[ ! -f /etc/v2node/config.json ]]; then
        # Neu truyen du tham so qua CLI, tao cau hinh va bo qua tuong tac
        if [[ -n "$API_HOST_ARG" && -n "$NODE_ID_ARG" && -n "$API_KEY_ARG" ]]; then
            generate_v2node_config "$API_HOST_ARG" "$NODE_ID_ARG" "$API_KEY_ARG"
            echo -e "${green}Da tao /etc/v2node/config.json tu tham so${plain}"
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
            echo -e "${green}v2node khoi dong lai thanh cong${plain}"
        else
            echo -e "${red}v2node co the khoi dong that bai, vui long dung v2node log de xem nhat ky${plain}"
        fi
        first_install=false
    fi


    curl -o /usr/bin/v2node -Ls https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/v2node.sh
    chmod +x /usr/bin/v2node

    cd $cur_dir
    rm -f install.sh
    echo "------------------------------------------"
    echo -e "Cach su dung script quan ly: "
    echo "------------------------------------------"
    echo "v2node              - Hien thi menu quan ly (nhieu chuc nang hon)"
    echo "v2node start        - Khoi dong v2node"
    echo "v2node stop         - Dung v2node"
    echo "v2node restart      - Khoi dong lai v2node"
    echo "v2node status       - Xem trang thai v2node"
    echo "v2node enable       - Bat tu dong khoi dong cung he thong"
    echo "v2node disable      - Tat tu dong khoi dong cung he thong"
    echo "v2node log          - Xem nhat ky v2node"
    echo "v2node generate     - Tao file cau hinh v2node"
    echo "v2node update       - Cap nhat v2node"
    echo "v2node update x.x.x - Cap nhat v2node phien ban chi dinh"
    echo "v2node install      - Cai dat v2node"
    echo "v2node uninstall    - Go cai dat v2node"
    echo "v2node version      - Xem phien ban v2node"
    echo "------------------------------------------"
    curl -fsS --max-time 10 "https://api.v-50.me/counter" || true

    if [[ $first_install == true ]]; then
        read -rp "Phat hien day la lan dau cai dat v2node, ban co muon tu dong tao /etc/v2node/config.json? (y/n): " if_generate
        if [[ "$if_generate" =~ ^[Yy]$ ]]; then
            # Thu thap tham so tuong tac, cung cap gia tri mac dinh mau
            read -rp "Dia chi API panel [dinh dang: https://example.com/]: " api_host
            api_host=${api_host:-https://example.com/}
            read -rp "Node ID: " node_id
            node_id=${node_id:-1}
            read -rp "Khoa giao tiep node: " api_key

            # Tao file cau hinh (ghi de template co the da sao chep tu goi)
            generate_v2node_config "$api_host" "$node_id" "$api_key"
        else
            echo "${green}Da bo qua tu dong tao cau hinh. Neu can tao sau, chay: v2node generate${plain}"
        fi
    fi
}

parse_args "$@"
echo -e "${green}Bat dau cai dat${plain}"
install_base
install_v2node "$VERSION_ARG"
