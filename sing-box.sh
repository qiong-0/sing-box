#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box_multi_protocol_install.sh
# 功能: 一键安装 sing-box，配置 VLESS+WS、Hysteria2 (自签TLS)、VLESS+Reality
# 环境: 兼容 systemd / OpenRC，自动适配包管理器，支持轻量容器
# 用法: bash sing-box_multi_protocol_install.sh
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

error() { echo -e "${RED}错误:${NC} $*" >&2; exit 1; }
warn()  { echo -e "${YELLOW}警告:${NC} $*"; }
info()  { echo -e "${CYAN}>>>${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }

detect_pkg_manager() {
    if command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
        INSTALL_CMD="apk add --no-cache"
        UPDATE_CMD="apk update"
    elif command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get install -y"
        UPDATE_CMD="apt-get update"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y"
        UPDATE_CMD="yum makecache"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y"
        UPDATE_CMD="dnf makecache"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"
        INSTALL_CMD="zypper install -y"
        UPDATE_CMD="zypper refresh"
    else
        error "不支持的包管理器，请手动安装 wget、tar、curl、openssl"
    fi
}

install_deps() {
    local deps="wget tar curl openssl"
    case $PKG_MANAGER in
        apk) $INSTALL_CMD $deps bash gcompat ;;
        apt) $UPDATE_CMD && $INSTALL_CMD $deps ;;
        yum|dnf|zypper) $UPDATE_CMD && $INSTALL_CMD $deps ;;
    esac
    for cmd in wget tar curl openssl; do
        command -v $cmd &>/dev/null || error "$cmd 安装失败"
    done
}

detect_init() {
    if command -v systemctl &>/dev/null; then
        INIT="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT="openrc"
    else
        error "未检测到 systemd 或 OpenRC"
    fi
    ok "init 系统: $INIT"
}

get_arch() {
    case $(uname -m) in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) error "不支持的系统架构: $(uname -m)" ;;
    esac
    ok "系统架构: $ARCH"
}

get_public_ip() {
    info "正在获取公网 IP ..."
    PUBLIC_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null)
    if [ -z "$PUBLIC_IP" ]; then
        error "无法获取公网 IP，请检查网络连接或手动设置 PUBLIC_IP 变量"
    fi
    ok "公网 IP: $PUBLIC_IP"
}

uninstall_old() {
    if [ -d "$CORE_DIR" ]; then
        warn "检测到已安装的 sing-box，执行卸载..."
        if [ "$INIT" = "systemd" ]; then
            systemctl stop sing-box 2>/dev/null || true
            systemctl disable sing-box 2>/dev/null || true
            rm -f /lib/systemd/system/sing-box.service
        elif [ "$INIT" = "openrc" ]; then
            rc-service sing-box stop 2>/dev/null || true
            rc-update del sing-box 2>/dev/null || true
            rm -f /etc/init.d/sing-box
        fi
        rm -rf "$CORE_DIR" "$LOG_DIR"
        ok "旧版本已卸载"
    fi
}

install_singbox() {
    local latest_url
    latest_url=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    [[ -z $latest_url ]] && latest_url="v1.12.1"
    local version=${latest_url#v}
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_url}/sing-box-${version}-linux-${ARCH}.tar.gz"
    info "下载 sing-box: $download_url"
    wget --no-check-certificate -O /tmp/sing-box.tar.gz "$download_url" || error "下载失败"
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/ || error "解压失败"
    mkdir -p "$CORE_DIR/bin" "$CONF_DIR" "$LOG_DIR" "$CERT_DIR" "$REALITY_DIR"
    cp "/tmp/sing-box-${version}-linux-${ARCH}/sing-box" "$CORE_BIN"
    chmod +x "$CORE_BIN"
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${version}-linux-${ARCH}"
    ok "sing-box 安装完成: $($CORE_BIN version | head -n1)"
}

generate_cert() {
    local cert_file="$CERT_DIR/cert.pem"
    local key_file="$CERT_DIR/key.pem"
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        info "生成自签 TLS 证书（有效期 10 年）..."
        if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$key_file" -out "$cert_file" -days 3650 -nodes -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" 2>/dev/null; then
            ok "证书生成完成（含 SAN）"
        else
            warn "openssl 不支持 -addext，使用不含 SAN 的证书（客户端需跳过验证）"
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$key_file" -out "$cert_file" -days 3650 -nodes -subj "/CN=$DOMAIN"
        fi
        chmod 600 "$key_file" "$cert_file"
        ok "证书生成完成: $cert_file"
    else
        ok "证书已存在，跳过生成"
    fi
    CERT_FILE="$cert_file"
    KEY_FILE="$key_file"
}

generate_reality_keys() {
    local pub_file="$REALITY_DIR/public.key"
    local priv_file="$REALITY_DIR/private.key"
    if [ ! -f "$pub_file" ] || [ ! -f "$priv_file" ]; then
        info "生成 Reality 密钥对..."
        output=$($CORE_BIN generate reality-keypair)
        pub=$(echo "$output" | grep "PublicKey" | awk '{print $2}')
        priv=$(echo "$output" | grep "PrivateKey" | awk '{print $2}')
        echo "$pub" > "$pub_file"
        echo "$priv" > "$priv_file"
        chmod 600 "$pub_file" "$priv_file"
        ok "Reality 密钥对生成完成"
    else
        ok "Reality 密钥对已存在，跳过生成"
    fi
    REALITY_PUB=$(cat "$pub_file")
    REALITY_PRIV=$(cat "$priv_file")
}

get_config_all() {
    echo ""
    info "请输入 VLESS+WebSocket 使用的域名（用于 Host 和路径伪装）"
    read -p "$(echo -e "${CYAN}WS 域名 (必填):${NC} ")" WS_DOMAIN
    [[ -z $WS_DOMAIN ]] && error "WS 域名不能为空"

    # ---------- VLESS+WS ----------
    echo ""
    info "配置 VLESS+WebSocket (无 TLS)"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" WS_PORT
    [[ -z $WS_PORT ]] && WS_PORT=$((RANDOM % 40001 + 10000))
    read -p "$(echo -e "${CYAN}WebSocket 路径 (默认 /):${NC} ")" WS_PATH
    [[ -z $WS_PATH ]] && WS_PATH="/"
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-WS):${NC} ")" WS_NAME
    [[ -z $WS_NAME ]] && WS_NAME="VLESS-WS"
    WS_UUID=$(cat /proc/sys/kernel/random/uuid)

    # ---------- Hysteria2 ----------
    echo ""
    info "配置 Hysteria2 (自签 TLS)"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" HY2_PORT
    [[ -z $HY2_PORT ]] && HY2_PORT=$((RANDOM % 40001 + 10000))
    read -p "$(echo -e "${CYAN}节点名称 (默认 HY2):${NC} ")" HY2_NAME
    [[ -z $HY2_NAME ]] && HY2_NAME="HY2"
    HY2_UUID=$(cat /proc/sys/kernel/random/uuid)
    read -p "$(echo -e "${CYAN}是否开启端口跳跃？(客户端自行配置) [y/N]:${NC} ")" HY2_HOP
    HY2_HOP=${HY2_HOP:-n}   # 默认 n

    # ---------- VLESS+Reality （与 Hysteria2 共用 SNI） ----------
    echo ""
    info "配置 VLESS+Reality 和 Hysteria2 共用的 SNI（用于 TLS 伪装）"
    read -p "$(echo -e "${CYAN}SNI / 伪装目标 (默认 apple.com):${NC} ")" COMMON_SNI
    [[ -z $COMMON_SNI ]] && COMMON_SNI="apple.com"
    
    echo ""
    info "配置 VLESS+Reality 专用参数"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" REALITY_PORT
    [[ -z $REALITY_PORT ]] && REALITY_PORT=$((RANDOM % 40001 + 10000))
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-Reality):${NC} ")" REALITY_NAME
    [[ -z $REALITY_NAME ]] && REALITY_NAME="VLESS-Reality"
    REALITY_UUID=$(cat /proc/sys/kernel/random/uuid)
    REALITY_SID=$(openssl rand -hex 2)

    echo ""
    ok "配置信息汇总"
    echo "  WS 域名: $WS_DOMAIN"
    echo "  VLESS-WS: 端口 $WS_PORT, 路径 $WS_PATH, 名称 $WS_NAME"
    echo "  Hysteria2: 端口 $HY2_PORT, 名称 $HY2_NAME, 端口跳跃: ${HY2_HOP^^}"
    echo "  VLESS-Reality: 端口 $REALITY_PORT, 名称 $REALITY_NAME"
    echo "  共用 SNI: $COMMON_SNI"
}

write_config() {
    # Hysteria2 TLS（server_name 使用共用 SNI）
    local hy2_tls="{
        \"enabled\": true,
        \"certificate_path\": \"$CERT_FILE\",
        \"key_path\": \"$KEY_FILE\",
        \"server_name\": \"$COMMON_SNI\"
    }"

    # Reality TLS（server_name 和 handshake 都使用共用 SNI）
    local reality_tls="{
        \"enabled\": true,
        \"server_name\": \"$COMMON_SNI\",
        \"reality\": {
            \"enabled\": true,
            \"handshake\": {
                \"server\": \"$COMMON_SNI\",
                \"server_port\": 443
            },
            \"private_key\": \"$REALITY_PRIV\",
            \"short_id\": [
                \"$REALITY_SID\"
            ]
        }
    }"

    cat > "$CONFIG_JSON" <<EOF
{
  "log": {
    "level": "error",
    "output": "/dev/null",
    "timestamp": false
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "VLESS-WS-in",
      "listen": "::",
      "listen_port": $WS_PORT,
      "users": [
        { "uuid": "$WS_UUID", "flow": "" }
      ],
      "transport": {
        "type": "ws",
        "path": "$WS_PATH",
        "headers": {
          "Host": "$WS_DOMAIN"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "HY2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        { "password": "$HY2_UUID" }
      ],
      "tls": $hy2_tls
    },
    {
      "type": "vless",
      "tag": "VLESS-Reality-in",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        { "uuid": "$REALITY_UUID", "flow": "xtls-rprx-vision" }
      ],
      "tls": $reality_tls
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
    ok "配置文件已生成: $CONFIG_JSON"
}

create_service() {
    if [[ $INIT == "systemd" ]]; then
        cat > /lib/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$CORE_BIN run -c $CONFIG_JSON
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl start sing-box
        ok "systemd 服务已启动"
    else
        cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="CORE_BIN_PLACEHOLDER"
command_args="run -c CONFIG_JSON_PLACEHOLDER"
command_user="root"
pidfile="/run/${RC_SVCNAME}.pid"
command_background=true
depend() {
    need net
}
EOF
        sed -i "s|CORE_BIN_PLACEHOLDER|$CORE_BIN|g" /etc/init.d/sing-box
        sed -i "s|CONFIG_JSON_PLACEHOLDER|$CONFIG_JSON|g" /etc/init.d/sing-box
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        rc-service sing-box start
        ok "OpenRC 服务已启动"
    fi

    sleep 2
    if [[ $INIT == "systemd" ]] && systemctl is-active --quiet sing-box; then
        ok "服务运行正常"
    elif [[ $INIT == "openrc" ]] && rc-service sing-box status | grep -q "started"; then
        ok "服务运行正常"
    else
        warn "服务可能未正常启动，请手动运行 '$CORE_BIN run -c $CONFIG_JSON' 检查错误"
    fi
}

urlencode() {
    local string="$1"
    local encoded=""
    local i
    for ((i=0; i<${#string}; i++)); do
        local char="${string:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) encoded+="$char" ;;
            *) encoded+=$(printf '%%%02X' "'$char") ;;
        esac
    done
    echo "$encoded"
}

output_links() {
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}              VLESS 链接                ${NC}"
    echo -e "${GREEN}=========================================${NC}"

    local encoded_path=$(urlencode "$WS_PATH")
    local ws_link="vless://$WS_UUID@$WS_DOMAIN:443?encryption=none&security=tls&type=ws&host=$WS_DOMAIN&path=$encoded_path#$WS_NAME"
    echo -e "$ws_link"
    echo ""

    local reality_link="vless://$REALITY_UUID@$PUBLIC_IP:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$COMMON_SNI&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID&type=tcp&headerType=none#$REALITY_NAME"
    echo -e "$reality_link"
    echo ""

    local hy2_link="hysteria2://$HY2_UUID@$PUBLIC_IP:$HY2_PORT?insecure=1&sni=$COMMON_SNI#$HY2_NAME"
    echo -e "$hy2_link"
    if [[ "${HY2_HOP,,}" == "y" ]]; then
        echo -e "${YELLOW}提示: 已开启端口跳跃，客户端可添加 &ports=10000-50000${NC}"
    fi
    echo ""
    echo -e "${YELLOW}复制链接到客户端即可使用（自签证书需开启跳过验证）${NC}"
}

main() {
    [[ $EUID -ne 0 ]] && error "请以 root 用户执行（使用 sudo -i）"

    CORE_DIR="/etc/sing-box"
    CONF_DIR="$CORE_DIR/conf"
    LOG_DIR="/var/log/sing-box"
    CERT_DIR="$CORE_DIR/cert"
    REALITY_DIR="$CORE_DIR/reality"
    CORE_BIN="$CORE_DIR/bin/sing-box"
    CONFIG_JSON="$CORE_DIR/config.json"

    detect_pkg_manager
    install_deps
    get_arch
    get_public_ip
    detect_init
    uninstall_old
    install_singbox
    get_config_all
    generate_cert
    generate_reality_keys
    write_config
    create_service
    output_links
}

main "$@"
