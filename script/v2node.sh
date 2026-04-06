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

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [mac dinh $2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "Ban co muon khoi dong lai v2node khong" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}Nhan Enter de quay lai menu chinh: ${plain}" && read temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    if [[ $# == 0 ]]; then
        echo && echo -n -e "Nhap phien ban chi dinh (mac dinh phien ban moi nhat): " && read version
    else
        version=$2
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/install.sh) $version
    if [[ $? == 0 ]]; then
        echo -e "${green}Cap nhat hoan tat, da tu dong khoi dong lai v2node, vui long dung v2node log de xem nhat ky${plain}"
        exit
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

config() {
    echo "v2node se tu dong thu khoi dong lai sau khi chinh sua cau hinh"
    vi /etc/v2node/config.json
    sleep 2
    restart
    check_status
    case $? in
        0)
            echo -e "Trang thai v2node: ${green}Dang chay${plain}"
            ;;
        1)
            echo -e "Phat hien ban chua khoi dong v2node hoac v2node tu dong khoi dong that bai, ban co muon xem nhat ky? [Y/n]" && echo
            read -e -rp "(Mac dinh: y):" yn
            [[ -z ${yn} ]] && yn="y"
            if [[ ${yn} == [Yy] ]]; then
               show_log
            fi
            ;;
        2)
            echo -e "Trang thai v2node: ${red}Chua cai dat${plain}"
    esac
}

uninstall() {
    confirm "Ban co chac chan muon go cai dat v2node khong?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        service v2node stop
        rc-update del v2node
        rm /etc/init.d/v2node -f
    else
        systemctl stop v2node
        systemctl disable v2node
        rm /etc/systemd/system/v2node.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi
    rm /etc/v2node/ -rf
    rm /usr/local/v2node/ -rf

    echo ""
    echo -e "Go cai dat thanh cong, neu ban muon xoa script nay, sau khi thoat hay chay ${green}rm /usr/bin/v2node -f${plain} de xoa"
    echo ""

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}v2node dang chay, khong can khoi dong lai, neu can khoi dong lai vui long chon khoi dong lai${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service v2node start
        else
            systemctl start v2node
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}v2node khoi dong thanh cong, vui long dung v2node log de xem nhat ky${plain}"
        else
            echo -e "${red}v2node co the khoi dong that bai, vui long dung v2node log de xem nhat ky sau${plain}"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    if [[ x"${release}" == x"alpine" ]]; then
        service v2node stop
    else
        systemctl stop v2node
    fi
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}v2node da dung thanh cong${plain}"
    else
        echo -e "${red}v2node dung that bai, co the do thoi gian dung vuot qua 2 giay, vui long xem nhat ky sau${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ x"${release}" == x"alpine" ]]; then
        service v2node restart
    else
        systemctl restart v2node
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}v2node khoi dong lai thanh cong, vui long dung v2node log de xem nhat ky${plain}"
    else
        echo -e "${red}v2node co the khoi dong that bai, vui long dung v2node log de xem nhat ky sau${plain}"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ x"${release}" == x"alpine" ]]; then
        service v2node status
    else
        systemctl status v2node --no-pager -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update add v2node
    else
        systemctl enable v2node
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}v2node da bat tu dong khoi dong cung he thong thanh cong${plain}"
    else
        echo -e "${red}v2node bat tu dong khoi dong cung he thong that bai${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update del v2node
    else
        systemctl disable v2node
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}v2node da tat tu dong khoi dong cung he thong thanh cong${plain}"
    else
        echo -e "${red}v2node tat tu dong khoi dong cung he thong that bai${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ x"${release}" == x"alpine" ]]; then
        echo -e "${red}He thong Alpine tam thoi chua ho tro xem nhat ky${plain}\n" && exit 1
    else
        journalctl -u v2node.service -e --no-pager -f
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

update_shell() {
    wget -O /usr/bin/v2node -N --no-check-certificate https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/v2node.sh
    if [[ $? != 0 ]]; then
        echo ""
        echo -e "${red}Tai script that bai, vui long kiem tra ket noi toi Github${plain}"
        before_show_menu
    else
        chmod +x /usr/bin/v2node
        echo -e "${green}Nang cap script thanh cong, vui long chay lai script${plain}" && exit 0
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

check_enabled() {
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(rc-update show | grep v2node)
        if [[ x"${temp}" == x"" ]]; then
            return 1
        else
            return 0
        fi
    else
        temp=$(systemctl is-enabled v2node)
        if [[ x"${temp}" == x"enabled" ]]; then
            return 0
        else
            return 1;
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        echo -e "${red}v2node da duoc cai dat, vui long khong cai dat lai${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        echo -e "${red}Vui long cai dat v2node truoc${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "Trang thai v2node: ${green}Dang chay${plain}"
            show_enable_status
            ;;
        1)
            echo -e "Trang thai v2node: ${yellow}Khong chay${plain}"
            show_enable_status
            ;;
        2)
            echo -e "Trang thai v2node: ${red}Chua cai dat${plain}"
    esac
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "Tu dong khoi dong: ${green}Co${plain}"
    else
        echo -e "Tu dong khoi dong: ${red}Khong${plain}"
    fi
}

show_v2node_version() {
    echo -n "Phien ban v2node: "
    /usr/local/v2node/v2node version
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
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


generate_config_file() {
    # Thu thap tham so tuong tac, cung cap gia tri mac dinh mau
    read -rp "Dia chi API panel [dinh dang: https://example.com/]: " api_host
    api_host=${api_host:-https://example.com/}
    read -rp "Node ID: " node_id
    node_id=${node_id:-1}
    read -rp "Khoa giao tiep node: " api_key

    # Tao file cau hinh (ghi de template co the da sao chep tu goi)
    generate_v2node_config "$api_host" "$node_id" "$api_key"
}

# Mo cong firewall
open_ports() {
    systemctl stop firewalld.service 2>/dev/null
    systemctl disable firewalld.service 2>/dev/null
    setenforce 0 2>/dev/null
    ufw disable 2>/dev/null
    iptables -P INPUT ACCEPT 2>/dev/null
    iptables -P FORWARD ACCEPT 2>/dev/null
    iptables -P OUTPUT ACCEPT 2>/dev/null
    iptables -t nat -F 2>/dev/null
    iptables -t mangle -F 2>/dev/null
    iptables -F 2>/dev/null
    iptables -X 2>/dev/null
    netfilter-persistent save 2>/dev/null
    echo -e "${green}Mo cong firewall thanh cong!${plain}"
}

show_usage() {
    echo "Cach su dung script quan ly v2node: "
    echo "------------------------------------------"
    echo "v2node              - Hien thi menu quan ly (nhieu chuc nang hon)"
    echo "v2node start        - Khoi dong v2node"
    echo "v2node stop         - Dung v2node"
    echo "v2node restart      - Khoi dong lai v2node"
    echo "v2node status       - Xem trang thai v2node"
    echo "v2node enable       - Bat tu dong khoi dong cung he thong"
    echo "v2node disable      - Tat tu dong khoi dong cung he thong"
    echo "v2node log          - Xem nhat ky v2node"
    echo "v2node x25519       - Tao khoa x25519"
    echo "v2node generate     - Tao file cau hinh v2node"
    echo "v2node update       - Cap nhat v2node"
    echo "v2node update x.x.x - Cai dat v2node phien ban chi dinh"
    echo "v2node install      - Cai dat v2node"
    echo "v2node uninstall    - Go cai dat v2node"
    echo "v2node version      - Xem phien ban v2node"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}Script quan ly v2node backend,${plain}${red} khong ap dung cho docker${plain}
--- https://github.com/fsh2502/v2nodePro ---
  ${green}0.${plain} Chinh sua cau hinh
————————————————
  ${green}1.${plain} Cai dat v2node
  ${green}2.${plain} Cap nhat v2node
  ${green}3.${plain} Go cai dat v2node
————————————————
  ${green}4.${plain} Khoi dong v2node
  ${green}5.${plain} Dung v2node
  ${green}6.${plain} Khoi dong lai v2node
  ${green}7.${plain} Xem trang thai v2node
  ${green}8.${plain} Xem nhat ky v2node
————————————————
  ${green}9.${plain} Bat tu dong khoi dong cung he thong
  ${green}10.${plain} Tat tu dong khoi dong cung he thong
————————————————
  ${green}11.${plain} Xem phien ban v2node
  ${green}12.${plain} Nang cap script quan ly v2node
  ${green}13.${plain} Tao file cau hinh v2node
  ${green}14.${plain} Mo tat ca cong mang cua VPS
  ${green}15.${plain} Thoat script
 "
 #co the them chuc nang o tren
    show_status
    echo && read -rp "Vui long nhap lua chon [0-15]: " num

    case "${num}" in
        0) config ;;
        1) check_uninstall && install ;;
        2) check_install && update ;;
        3) check_install && uninstall ;;
        4) check_install && start ;;
        5) check_install && stop ;;
        6) check_install && restart ;;
        7) check_install && status ;;
        8) check_install && show_log ;;
        9) check_install && enable ;;
        10) check_install && disable ;;
        11) check_install && show_v2node_version ;;
        12) update_shell ;;
        13) generate_config_file ;;
        14) open_ports ;;
        15) exit ;;
        *) echo -e "${red}Vui long nhap so dung [0-15]${plain}" ;;
    esac
}


if [[ $# > 0 ]]; then
    case $1 in
        "start") check_install 0 && start 0 ;;
        "stop") check_install 0 && stop 0 ;;
        "restart") check_install 0 && restart 0 ;;
        "status") check_install 0 && status 0 ;;
        "enable") check_install 0 && enable 0 ;;
        "disable") check_install 0 && disable 0 ;;
        "log") check_install 0 && show_log 0 ;;
        "update") check_install 0 && update 0 $2 ;;
        "config") config $* ;;
        "generate") generate_config_file ;;
        "install") check_uninstall 0 && install 0 ;;
        "uninstall") check_install 0 && uninstall 0 ;;
        "version") check_install 0 && show_v2node_version 0 ;;
        "update_shell") update_shell ;;
        *) show_usage
    esac
else
    show_menu
fi
