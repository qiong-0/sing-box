#!/usr/bin/env bash
#
# sing-box VLESS + WebSocket (NO TLS) 一键安装脚本
# 参考风格: https://github.com/233boy/sing-box
# 路径强制为 "/" , host 可自定义, 端口可指定或随机 10000-50000
#

set -e

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# ---------- 系统检测 ----------
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1
}

check_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        echo -e "${RED}不支持的操作系统${PLAIN}" && exit 1
    fi
    if [[ "$OS" != "debian" && "$OS" != "ubuntu" && "$OS" != "centos" && "$OS" != "fedora" && "$OS" != "rocky" && "$OS" != "almalinux" ]]; then
        echo -e "${RED}暂不支持该系统: $OS${PLAIN}"
        exit 1
    fi
}

# ---------- 依赖安装 ----------
install_deps() {
    echo -e "${BLUE}正在安装必要依赖...${PLAIN}"
    if [[ "$OS" == "centos" || "$OS" == "rocky" || "$OS" == "almalinux" || "$OS" == "fedora" ]]; then
        yum install -y curl wget unzip tar jq
    else
        apt update && apt install -y curl wget unzip tar jq
    fi
}

# ---------- 获取 sing-box 最新版本 ----------
get_latest_version() {
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        LATEST_VERSION="v1.9.7"  # fallback
        echo -e "${YELLOW}无法获取最新版本，将使用默认版本: ${LATEST_VERSION}${PLAIN}"
    else
        echo -e "${GREEN}最新 sing-box 版本: ${LATEST_VERSION}${PLAIN}"
    fi
}

# ---------- 架构检测与下载 ----------
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

# ---------- 配置参数交互 ----------
input_config() {
    echo -e "${YELLOW}请按提示填写配置参数（直接回车使用默认值）${PLAIN}"

    # 端口
    read -p "请输入监听端口 (随机 10000-50000): " PORT
    if [[ -z "$PORT" ]]; then
        PORT=$(( RANDOM % 40001 + 10000 ))
        echo -e "已随机生成端口: ${GREEN}$PORT${PLAIN}"
    fi
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        echo -e "${RED}端口无效，退出${PLAIN}" && exit 1
    fi

    # 域名 (Host)
    read -p "请输入伪装域名 (host): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}域名不能为空，退出${PLAIN}" && exit 1
    fi

    # 节点名称
    read -p "请输入节点名称 (默认: VLESS-WS): " NODE_NAME
    NODE_NAME=${NODE_NAME:-VLESS-WS}

    # UUID 自动生成
    UUID=$(sing-box generate uuid)
    echo -e "生成的 UUID: ${GREEN}$UUID${PLAIN}"

    # 路径强制为 /
    WSPATH="/"

    # 获取服务器公网 IP
    SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ipinfo.io/ip)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="your_server_ip"
        echo -e "${YELLOW}无法获取公网 IP，请手动替换为实际 IP${PLAIN}"
    else
        echo -e "服务器 IP: ${GREEN}$SERVER_IP${PLAIN}"
    fi
}

# ---------- 生成配置文件 ----------
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

# ---------- 创建 systemd 服务 ----------
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
    systemctl enable sing-box.service
    echo -e "${GREEN}sing-box 服务已注册并设置为开机自启${PLAIN}"
}

# ---------- 防火墙设置 ----------
open_firewall() {
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent
        firewall-cmd --reload
    elif command -v ufw &>/dev/null; then
        ufw allow ${PORT}/tcp
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
        # 保存规则（尝试多种路径）
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        fi
    fi
    echo -e "${GREEN}防火墙已放行端口 ${PORT}${PLAIN}"
}

# ---------- 启动服务 ----------
start_service() {
    systemctl restart sing-box.service
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}sing-box 已成功启动${PLAIN}"
    else
        echo -e "${RED}sing-box 启动失败，请检查日志: journalctl -u sing-box${PLAIN}"
        exit 1
    fi
}

# ---------- 输出分享信息 ----------
show_info() {
    # VLESS 链接格式: vless://uuid@ip:port?type=ws&host=domain&path=%2F#nodeName
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=ws&host=${DOMAIN}&path=%2F#${NODE_NAME}"
    echo ""
    echo "=============================================="
    echo -e " ${GREEN}VLESS + WebSocket 节点部署成功${PLAIN}"
    echo "=============================================="
    echo -e " ${YELLOW}协议:${PLAIN}      VLESS"
    echo -e " ${YELLOW}传输:${PLAIN}      ws (WebSocket)"
    echo -e " ${YELLOW}IP 地址:${PLAIN}   ${SERVER_IP}"
    echo -e " ${YELLOW}端口:${PLAIN}      ${PORT}"
    echo -e " ${YELLOW}UUID:${PLAIN}     ${UUID}"
    echo -e " ${YELLOW}Host:${PLAIN}     ${DOMAIN}"
    echo -e " ${YELLOW}路径:${PLAIN}      ${WSPATH}"
    echo -e " ${YELLOW}节点名称:${PLAIN} ${NODE_NAME}"
    echo "----------------------------------------------"
    echo -e " ${GREEN}VLESS 链接 (导入客户端):${PLAIN}"
    echo -e " ${BLUE}${VLESS_LINK}${PLAIN}"
    echo "=============================================="
}

# ---------- 主流程 ----------
main() {
    clear
    echo -e "${GREEN}############################################${PLAIN}"
    echo -e "${GREEN}#   sing-box VLESS+WS (No TLS) 一键安装    #${PLAIN}"
    echo -e "${GREEN}#   路径: /   Host: 自定义  端口: 自定义  #${PLAIN}"
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
