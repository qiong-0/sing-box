#!/usr/bin/env bash
#===============================================================
#   Description: VLESS + WebSocket (no TLS) one-click installer
#   Author: Customized from 233boy/sing-box
#   Supported OS: Debian/Ubuntu, CentOS/RHEL, Alpine, Arch, LXC
#===============================================================

set -e

# ---- Color ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---- Check root ----
[[ $EUID -ne 0 ]] && echo -e "${RED}Error: This script must be run as root!${NC}" && exit 1

# ---- Global variables ----
SING_BOX_CONFIG="/etc/sing-box/config.json"
SING_BOX_BIN="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
INIT_SCRIPT="/etc/init.d/sing-box"
LOG_FILE="/var/log/sing-box.log"

# ---- User inputs ----
echo -e "${GREEN}=============================${NC}"
echo -e "${GREEN} VLESS + WS (no TLS) setup${NC}"
echo -e "${GREEN}=============================${NC}"

# Port
read -p "Port [random 10000-50000]: " PORT
if [[ -z "$PORT" ]]; then
    PORT=$((RANDOM % 40001 + 10000))
    echo -e "${YELLOW}Random port: ${PORT}${NC}"
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 ]] || [[ "$PORT" -gt 65535 ]]; then
    echo -e "${RED}Invalid port. Using random port.${NC}"
    PORT=$((RANDOM % 40001 + 10000))
    echo -e "${YELLOW}Port set to ${PORT}${NC}"
fi

# Host (domain or IP)
while true; do
    read -p "Domain / WS Host (required, no TLS): " HOST
    if [[ -n "$HOST" ]]; then
        break
    else
        echo -e "${RED}Host cannot be empty!${NC}"
    fi
done

# Path
read -p "WebSocket path (default '/'): " WSPATH
WSPATH=${WSPATH:-/}
# Ensure leading slash
[[ "$WSPATH" != /* ]] && WSPATH="/$WSPATH"

# Node name
read -p "Node name (default: VLESS-WS): " NODE_NAME
NODE_NAME=${NODE_NAME:-VLESS-WS}

# ---- Generate UUID ----
UUID=$(cat /proc/sys/kernel/random/uuid)
echo -e "${BLUE}Generated UUID: ${UUID}${NC}"

# ---- Detect OS & architecture ----
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    OS=$(uname -s)
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ARCH="amd64";;
    aarch64|arm64) ARCH="arm64";;
    armv7l|armv7) ARCH="armv7";;
    *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1;;
esac

# ---- Install dependencies ----
install_deps() {
    echo -e "${YELLOW}Installing dependencies...${NC}"
    if command -v apt >/dev/null 2>&1; then
        apt update -y && apt install -y curl wget unzip qrencode jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget unzip qrencode jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget unzip qrencode jq
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl wget unzip qrencode jq
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm curl wget unzip qrencode jq
    else
        echo -e "${RED}Unsupported package manager, please install curl/wget/unzip manually.${NC}"
        exit 1
    fi
}
install_deps

# ---- Install sing-box ----
install_sing_box() {
    echo -e "${YELLOW}Installing sing-box...${NC}"
    # Fetch latest version tag
    LATEST=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    [[ -z "$LATEST" ]] && LATEST="v1.10.0"  # fallback
    FILENAME="sing-box-${LATEST#v}-linux-${ARCH}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST}/${FILENAME}"

    cd /tmp
    wget -q --show-progress "$URL" || curl -L -o "$FILENAME" "$URL"
    tar -xzf "$FILENAME"
    cp "sing-box-${LATEST#v}-linux-${ARCH}/sing-box" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -rf "sing-box-${LATEST#v}-linux-${ARCH}" "$FILENAME"
    echo -e "${GREEN}sing-box installed successfully.${NC}"
}

if [[ -f "$SING_BOX_BIN" ]]; then
    echo -e "${YELLOW}sing-box already installed, checking version...${NC}"
    CURRENT_VER=$("$SING_BOX_BIN" version | head -1 | awk '{print $3}')
    echo -e "Current version: ${CURRENT_VER}"
    read -p "Reinstall/update sing-box? [y/N]: " UPD
    if [[ "$UPD" =~ ^[Yy]$ ]]; then
        rm -f "$SING_BOX_BIN"
        install_sing_box
    fi
else
    install_sing_box
fi

# ---- Create config ----
mkdir -p /etc/sing-box
cat > "$SING_BOX_CONFIG" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "::",
      "listen_port": ${PORT},
      "sniff": true,
      "sniff_override_destination": false,
      "users": [
        {
          "uuid": "${UUID}",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WSPATH}",
        "headers": {
          "Host": "${HOST}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF

echo -e "${GREEN}Configuration saved to ${SING_BOX_CONFIG}${NC}"

# ---- Setup firewall ----
setup_firewall() {
    echo -e "${YELLOW}Configuring firewall...${NC}"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow ${PORT}/tcp
        ufw reload || true
        echo -e "ufw rule added."
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=${PORT}/tcp
        firewall-cmd --reload
        echo -e "firewalld rule added."
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
        # Save rules (distribution specific)
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        echo -e "iptables rule added."
    else
        echo -e "${YELLOW}No supported firewall found. Please open port ${PORT} manually.${NC}"
    fi
}
setup_firewall

# ---- Init system detection & service installation ----
setup_service() {
    echo -e "${YELLOW}Setting up service...${NC}"
    # Try systemd first
    if command -v systemctl >/dev/null 2>&1; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${SING_BOX_BIN} run -c ${SING_BOX_CONFIG}
Restart=on-failure
RestartSec=10
LimitNOFILE=102400

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl start sing-box
        systemctl status sing-box --no-pager
        echo -e "${GREEN}sing-box started with systemd.${NC}"
    elif command -v rc-update >/dev/null 2>&1; then
        # OpenRC (Alpine / Gentoo)
        cat > "$INIT_SCRIPT" <<EOF
#!/sbin/openrc-run
description="sing-box Service"
command="${SING_BOX_BIN}"
command_args="run -c ${SING_BOX_CONFIG}"
command_background=true
pidfile="/run/sing-box.pid"
EOF
        chmod +x "$INIT_SCRIPT"
        rc-update add sing-box default
        rc-service sing-box start
        echo -e "${GREEN}sing-box started with OpenRC.${NC}"
    elif command -v service >/dev/null 2>&1; then
        # SysVinit fallback
        cat > "$INIT_SCRIPT" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          sing-box
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: sing-box service
### END INIT INFO
case "\$1" in
  start)
    echo "Starting sing-box..."
    nohup ${SING_BOX_BIN} run -c ${SING_BOX_CONFIG} > ${LOG_FILE} 2>&1 &
    echo \$! > /var/run/sing-box.pid
    ;;
  stop)
    echo "Stopping sing-box..."
    kill \$(cat /var/run/sing-box.pid) 2>/dev/null
    ;;
  restart)
    \$0 stop
    sleep 1
    \$0 start
    ;;
  *)
    echo "Usage: \$0 {start|stop|restart}"
    exit 1
esac
EOF
        chmod +x "$INIT_SCRIPT"
        update-rc.d sing-box defaults >/dev/null 2>&1 || chkconfig sing-box on >/dev/null 2>&1
        service sing-box start
        echo -e "${GREEN}sing-box started with SysV init.${NC}"
    else
        # No init system (e.g., minimal container), start with nohup directly
        echo -e "${YELLOW}No init system detected. Starting sing-box in background...${NC}"
        nohup ${SING_BOX_BIN} run -c ${SING_BOX_CONFIG} > ${LOG_FILE} 2>&1 &
        echo $! > /var/run/sing-box.pid
        echo -e "${GREEN}sing-box started in background (PID $(cat /var/run/sing-box.pid)).${NC}"
        echo -e "${YELLOW}To stop: kill \$(cat /var/run/sing-box.pid)${NC}"
    fi
}
setup_service

# ---- Generate client info ----
IP=$(curl -s4 ifconfig.me || curl -s ip.sb || hostname -I | awk '{print $1}')
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WSPATH}'))" 2>/dev/null || python -c "import urllib; print(urllib.quote('${WSPATH}'))" 2>/dev/null || echo "${WSPATH}" | sed 's/\//%2F/g')
VLESS_LINK="vless://${UUID}@${IP}:${PORT}?type=ws&host=${HOST}&path=${ENCODED_PATH}#${NODE_NAME}"

echo ""
echo -e "${GREEN}==============================${NC}"
echo -e "${GREEN}    VLESS + WS (no TLS)${NC}"
echo -e "${GREEN}==============================${NC}"
echo -e "Address (IP):     ${BLUE}${IP}${NC}"
echo -e "Port:             ${BLUE}${PORT}${NC}"
echo -e "UUID:             ${BLUE}${UUID}${NC}"
echo -e "WS Host:          ${BLUE}${HOST}${NC}"
echo -e "WS Path:          ${BLUE}${WSPATH}${NC}"
echo -e "Node Name:        ${BLUE}${NODE_NAME}${NC}"
echo ""
echo -e "${GREEN}=== VLESS Link ===${NC}"
echo -e "${VLESS_LINK}"
echo ""

# QR code
if command -v qrencode >/dev/null 2>&1; then
    echo -e "${GREEN}=== QR Code ===${NC}"
    qrencode -t ANSIUTF8 "${VLESS_LINK}"
    echo ""
fi

echo -e "${YELLOW}Service status command: ${NC}"
if command -v systemctl >/dev/null 2>&1; then
    echo "systemctl status sing-box"
elif command -v service >/dev/null 2>&1; then
    echo "service sing-box status"
elif command -v rc-service >/dev/null 2>&1; then
    echo "rc-service sing-box status"
else
    echo "ps aux | grep sing-box"
fi
echo -e "${GREEN}Installation finished!${NC}"
