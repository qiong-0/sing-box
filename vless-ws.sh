#!/usr/bin/env bash
# sing-box 一键安装脚本 - VLESS+WS 无 TLS
# 直接下载官方二进制，绕过系统检测 bug

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}请以 root 运行${PLAIN}" && exit 1

install_singbox() {
    echo -e "${BLUE}下载 sing-box 二进制...${PLAIN}"
    local tmp=$(mktemp -d)
    cd "$tmp"
    wget -q --show-progress https://github.com/SagerNet/sing-box/releases/download/v1.13.13/sing-box-1.13.13-linux-amd64.tar.gz
    tar -xzf sing-box-1.13.13-linux-amd64.tar.gz
    cp -f sing-box-1.13.13-linux-amd64/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    cd / && rm -rf "$tmp"
    echo -e "${GREEN}sing-box 安装成功${PLAIN}"
}

get_random_port() {
    while :; do
        port=$((RANDOM % 40001 + 10000))
        ss -tuln | grep -q ":$port " || { echo "$port"; break; }
    done
}

main() {
    clear
    echo -e "${BLUE}================================${PLAIN}"
    echo -e " sing-box VLESS+WS 一键安装 (无TLS)"
    echo -e "${BLUE}================================${PLAIN}"
    read -p "请输入域名 (WS Host): " domain
    [[ -z "$domain" ]] && { echo -e "${RED}域名不能为空${PLAIN}"; exit 1; }
    read -p "请输入端口 (回车随机): " port
    [[ -z "$port" ]] && port=$(get_random_port)
    read -p "节点名称 (默认 VLESS-WS): " name
    [[ -z "$name" ]] && name="VLESS-WS"
    uuid=$(sing-box generate uuid 2>/dev/null || uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    ip=$(curl -s4m5 ip.sb)
    
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json <<EOF
{
  "inbounds": [{
    "type": "vless",
    "listen_port": $port,
    "users": [{"uuid": "$uuid"}],
    "transport": {
      "type": "ws",
      "path": "/",
      "headers": {"Host": "$domain"}
    }
  }],
  "outbounds": [{"type": "direct"}]
}
EOF

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    
    link="vless://$uuid@$ip:$port?encryption=none&security=none&type=ws&host=$domain&path=%2F#$name"
    echo -e "\n${GREEN}安装完成！${PLAIN}"
    echo -e "节点链接: ${YELLOW}$link${PLAIN}"
    echo "$link" > /etc/sing-box/link.txt
    echo -e "管理命令: ${BLUE}systemctl {start|stop|restart|status} sing-box${PLAIN}"
}

# 如果未安装 sing-box 则安装
command -v sing-box &>/dev/null || install_singbox
main
