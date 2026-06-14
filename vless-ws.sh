#!/usr/bin/env bash
#====================================================
#   sing-box VLESS + WebSocket (NO TLS) 一键安装脚本
#   路径强制为 "/"  host 自定义  端口可选随机
#   用法: bash <(curl -sSL https://raw.githubusercontent.com/qiong-0/sing-box/main/vless-ws.sh)
#====================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 请使用 root 用户运行此脚本！${PLAIN}" && exit 1
}

check_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    else
        echo -e "${RED}不支持的操作系统${PLAIN}"
        exit 1
    fi
    if [[ "$OS" != "debian" && "$OS" != "ubuntu" && "$OS" != "centos" && "$OS" != "fedora" && "$OS" != "rocky" && "$OS" != "almalinux" ]]; then
        echo -e "${RED}暂不支持的系统: $OS${PLAIN}"
        exit 1
    fi
}

install_deps() {
    echo -e "${BLUE}正在安装必要依赖...${PLAIN}"
    if [[ "$OS" == "centos" || "$OS" == "rocky" || "$OS" == "almalinux" || "$OS" == "fedora" ]]; then
        yum install -y curl wget unzip tar jq
    else
        apt update && apt install -y curl wget unzip tar jq
    fi
}

get_latest_version() {
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        LATEST_VERSION="v1.9.7"
        echo -e "${YELLOW}无法获取最新版本，将使用默认版本: ${LATEST_VERSION}${PLAIN}"
    else
        echo -e "${GREEN}最新 sing-box 版本: ${LATEST_VERSION}${PLAIN}"
    fi
}

download_singbox() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        *)       echo -e "${RED}不支持的架构: $ARCH${PLAIN}" && exit 1 ;;
    esac
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${LATEST_VERSION#v}-linux-${ARCH}.tar.gz"
    echo -e "${BLUE}下载 sing-box...${PLAIN}"
    wget -q --show-progress -O /tmp/sing-box.tar.gz "$DOWNLOAD_URL"
    mkdir -p /tmp/sing-box-tmp
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/sing-box-tmp --strip-components=1
    mv /tmp/sing-box-tmp/sing-box /usr/bin/sing-box
    chmod +x /usr/bin/sing-box
    rm -rf /tmp/sing-box.tar.gz /tmp/sing-box-tmp
    echo -e "${GREEN}sing-box 安装完成${PLAIN}"
}

input_config() {
    echo ""
    echo -e "${YELLOW}请按提示填写配置（直接回车使用默认值）${PLAIN}"

    read -p "请输入监听端口 (回车随机 10000-50000): " PORT
    if [[ -z "$PORT" ]]; then
        PORT=$(( RANDOM % 40001 + 10000 ))
        echo -e "已随机生成端口: ${GREEN}$PORT${PLAIN}"
    fi
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        echo -e "${RED}端口无效，退出${PLAIN}" && exit 1
    fi

    read -p "请输入伪装域名 (host, 必填): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}域名不能为空，退出${PLAIN}" && exit 1
    fi

    read -p "请输入节点名称 (默认: VLESS-WS): " NODE_NAME
    NODE_NAME=${NODE_NAME:-VLESS-WS}

    UUID=$(sing-box generate uuid)
    echo -e "生成的 UUID: ${GREEN}$UUID${PLAIN}"

    WSPATH="/"

    SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ipinfo.io/ip)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="your_server_ip"
        echo -e "${YELLOW}无法获取公网 IP，请稍后手动替换${PLAIN}"
    else
        echo -e "服务器公网 IP: ${GREEN}$SERVER_IP${PLAIN}"
    fi
}

gen_config() {
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$WSPATH",
        "headers": {
          "Host": "$DOMAIN"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    echo -e "${GREEN}配置文件已生成: /etc/sing-box/config.json${PLAIN}"
}

gen_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box.service >/dev/null 2>&1
    echo -e "${GREEN}系统服务已创建并设置为开机自启${PLAIN}"
}

open_firewall() {
    echo -e "${BLUE}正在配置防火墙...${PLAIN}"
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent
        firewall-cmd --reload
    elif command -v ufw &>/dev/null; then
        ufw allow ${PORT}/tcp
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    else
        echo -e "${YELLOW}未检测到防火墙，请手动放行端口 ${PORT}${PLAIN}"
    fi
    echo -e "${GREEN}防火墙已放行端口 ${PORT}${PLAIN}"
}

start_service() {
    systemctl restart sing-box
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}sing-box 已成功启动${PLAIN}"
    else
        echo -e "${RED}sing-box 启动失败，请使用 journalctl -u sing-box 查看日志${PLAIN}"
        exit 1
    fi
}

show_info() {
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=ws&host=${DOMAIN}&path=%2F#${NODE_NAME}"
    clear
    echo ""
    echo "=============================================="
    echo -e " ${GREEN}VLESS + WebSocket 节点部署成功！${PLAIN}"
    echo "=============================================="
    echo -e " ${YELLOW}协议:${PLAIN}      VLESS"
    echo -e " ${YELLOW}传输:${PLAIN}      ws (WebSocket)"
    echo -e " ${YELLOW}地址:${PLAIN}      ${SERVER_IP}"
    echo -e " ${YELLOW}端口:${PLAIN}      ${PORT}"
    echo -e " ${YELLOW}UUID:${PLAIN}     ${UUID}"
    echo -e " ${YELLOW}Host:${PLAIN}     ${DOMAIN}"
    echo -e " ${YELLOW}路径:${PLAIN}      ${WSPATH}"
    echo -e " ${YELLOW}节点名:${PLAIN}   ${NODE_NAME}"
    echo "----------------------------------------------"
    echo -e " ${GREEN}VLESS 导入链接:${PLAIN}"
    echo -e " ${BLUE}${VLESS_LINK}${PLAIN}"
    echo "=============================================="
}

main() {
    clear
    echo -e "${GREEN}############################################${PLAIN}"
    echo -e "${GREEN}#   sing-box VLESS+WS (无TLS) 一键脚本    #${PLAIN}"
    echo -e "${GREEN}#   路径:/  Host自定义  端口可选随机      #${PLAIN}"
    echo -e "${GREEN}############################################${PLAIN}"
    echo ""

    check_root
    check_system
    install_deps
    get_latest_version
    download_singbox
    input_config
    gen_config
    gen_service
    open_firewall
    start_service
    show_info
}

main "$@"
