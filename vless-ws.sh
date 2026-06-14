#!/usr/bin/env bash
#===============================================================
#   VLESS + WebSocket (no TLS) - No QR edition
#   Compatible: Debian/Ubuntu, CentOS, Alpine, Arch, LXC
#===============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}Error: root only!${NC}" && exit 1

SING_BOX_CONFIG="/etc/sing-box/config.json"
SING_BOX_BIN="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
INIT_SCRIPT="/etc/init.d/sing-box"
LOG_FILE="/var/log/sing-box.log"

echo -e "${GREEN}=============================${NC}"
echo -e "${GREEN} VLESS + WS (no TLS) setup${NC}"
echo -e "${GREEN}=============================${NC}"

read -p "Port [random 10000-50000]: " PORT
if [[ -z "$PORT" ]]; then
    PORT=$((RANDOM % 40001 + 10000))
    echo -e "${YELLOW}Random port: ${PORT}${NC}"
fi
while true; do
    read -p "Domain / WS Host (required, no TLS): " HOST
    [[ -n "$HOST" ]] && break
    echo -e "${RED}Host cannot be empty!${NC}"
done
read -p "WebSocket path (default '/'): " WSPATH
WSPATH=${WSPATH:-/}
[[ "$WSPATH" != /* ]] && WSPATH="/$WSPATH"
read -p "Node name (default: VLESS-WS): " NODE_NAME
NODE_NAME=${NODE_NAME:-VLESS-WS}

UUID=$(cat /proc/sys/kernel/random/uuid)
echo -e "${BLUE}UUID: ${UUID}${NC}"

# Detect OS
if [[ -f /etc/os-release ]]; then . /etc/os-release; OS=$ID; else OS=$(uname -s); fi
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ARCH="amd64";;
    aarch64|arm64) ARCH="arm64";;
    armv7l) ARCH="armv7";;
    *) echo -e "${RED}Unsupported arch: $ARCH${NC}"; exit 1;;
esac

# Install deps (no qrencode)
if command -v apt >/dev/null 2>&1; then apt update -y && apt install -y curl wget unzip jq
elif command -v yum >/dev/null 2>&1; then yum install -y curl wget unzip jq
elif command -v dnf >/dev/null 2>&1; then dnf install -y curl wget unzip jq
elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl wget unzip jq
elif command -v pacman >/dev/null 2>&1; then pacman -Syu --noconfirm curl wget unzip jq
else echo -e "${RED}Please install curl/wget/unzip/jq manually.${NC}"; exit 1; fi

# Install sing-box
if [[ -f "$SING_BOX_BIN" ]]; then
    read -p "Reinstall/update sing-box? [y/N]: " UPD
    [[ "$UPD" =~ ^[Yy]$ ]] && rm -f "$SING_BOX_BIN"
fi
if [[ ! -f "$SING_BOX_BIN" ]]; then
    LATEST=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    [[ -z "$LATEST" ]] && LATEST="v1.10.0"
    FILENAME="sing-box-${LATEST#v}-linux-${ARCH}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST}/${FILENAME}"
    cd /tmp; wget -q --show-progress "$URL" || curl -L -o "$FILENAME" "$URL"
    tar -xzf "$FILENAME"
    cp "sing-box-${LATEST#v}-linux-${ARCH}/sing-box" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -rf "sing-box-${LATEST#v}-linux-${ARCH}" "$FILENAME"
fi

# Config
mkdir -p /etc/sing-box
cat > "$SING_BOX_CONFIG" <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-ws-in",
    "listen": "::",
    "listen_port": ${PORT},
    "sniff": true,
    "users": [{"uuid": "${UUID}", "flow": ""}],
    "transport": {
      "type": "ws",
      "path": "${WSPATH}",
      "headers": {"Host": "${HOST}"}
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}, {"type": "block", "tag": "block"}]
}
EOF

# Firewall
if command -v ufw >/dev/null 2>&1; then ufw allow ${PORT}/tcp; ufw reload || true
elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --permanent --add-port=${PORT}/tcp; firewall-cmd --reload
elif command -v iptables >/dev/null 2>&1; then iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT; fi

# Service
if command -v systemctl >/dev/null 2>&1; then
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box
After=network.target
[Service]
Type=simple
ExecStart=${SING_BOX_BIN} run -c ${SING_BOX_CONFIG}
Restart=on-failure
LimitNOFILE=102400
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable sing-box; systemctl start sing-box
elif command -v rc-update >/dev/null 2>&1; then
    cat > "$INIT_SCRIPT" <<EOF
#!/sbin/openrc-run
command="${SING_BOX_BIN}"
command_args="run -c ${SING_BOX_CONFIG}"
command_background=true
pidfile="/run/sing-box.pid"
EOF
    chmod +x "$INIT_SCRIPT"; rc-update add sing-box default; rc-service sing-box start
else
    nohup ${SING_BOX_BIN} run -c ${SING_BOX_CONFIG} > ${LOG_FILE} 2>&1 &
    echo $! > /var/run/sing-box.pid
fi

# Output
IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WSPATH}'))" 2>/dev/null || echo "${WSPATH}" | sed 's/\//%2F/g')
VLESS_LINK="vless://${UUID}@${IP}:${PORT}?type=ws&host=${HOST}&path=${ENCODED_PATH}#${NODE_NAME}"

echo ""
echo -e "${GREEN}==============================${NC}"
echo -e "Address: ${BLUE}${IP}${NC}"
echo -e "Port:    ${BLUE}${PORT}${NC}"
echo -e "UUID:    ${BLUE}${UUID}${NC}"
echo -e "Host:    ${BLUE}${HOST}${NC}"
echo -e "Path:    ${BLUE}${WSPATH}${NC}"
echo -e "${GREEN}=== VLESS Link ===${NC}"
echo -e "${VLESS_LINK}"
