#!/usr/bin/env bash

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
        
        if command -v iptables &>/dev/null && iptables-save &>/dev/null; then
        if iptables-save | grep -q "sing-box"; then
            iptables-save | grep -v "sing-box" | iptables-restore
            echo -e "${INFO} 已清理 iptables 规则"
        fi
        fi
        
        if command -v crontab &>/dev/null; then
        if crontab -l 2>/dev/null | grep -q "sing-box"; then
            crontab -l 2>/dev/null | grep -v "sing-box" | crontab -
            echo -e "${INFO} 已清理 crontab 任务"
        fi
        fi
        
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
        info "生成 TLS 证书..."
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
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo ""
    echo "UUID: $UUID"
    echo ""
    info "配置 VLESS + WebSocket (无 TLS)"
    read -p "$(echo -e "${CYAN}域名:${NC} ")" WS_DOMAIN
    [[ -z $WS_DOMAIN ]] && error "域名不能为空"
    echo "域名: $WS_DOMAIN"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" WS_PORT
    [[ -z $WS_PORT ]] && WS_PORT=$((RANDOM % 40001 + 10000))
    echo "端口: $WS_PORT"

    echo ""
    info "配置 SNI（用于 TLS 伪装）"
    read -p "$(echo -e "${CYAN}SNI (默认 apple.com):${NC} ")" COMMON_SNI
    [[ -z $COMMON_SNI ]] && COMMON_SNI="apple.com"
    echo "SNI: $COMMON_SNI"

    echo ""
    info "配置 Hysteria2"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" HY2_PORT
    [[ -z $HY2_PORT ]] && HY2_PORT=$((RANDOM % 40001 + 10000))
    echo "端口: $HY2_PORT"
    read -p "$(echo -e "${CYAN}是否开启端口跳跃？(默认n) [y/n]:${NC} ")" HY2_HOP
    HY2_HOP=${HY2_HOP:-n}
    if [[ "${HY2_HOP,,}" == "y" ]]; then
        read -p "$(echo -e "${CYAN}端口跳跃范围 (起始-结束，默认 10000-50000):${NC} ")" HY2_PORTS
        [[ -z $HY2_PORTS ]] && HY2_PORTS="10000-50000"
        if [[ ! "$HY2_PORTS" =~ ^[0-9]+-[0-9]+$ ]]; then
            warn "端口范围格式错误，使用默认 10000-50000"
            HY2_PORTS="10000-50000"
        fi
        echo "端口跳跃: $HY2_PORTS"
    else
        HY2_PORTS=""
    fi

    echo ""
    info "配置 VLESS + Reality"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" REALITY_PORT
    [[ -z $REALITY_PORT ]] && REALITY_PORT=$((RANDOM % 40001 + 10000))
    echo "端口: $REALITY_PORT"
    REALITY_SID=$(openssl rand -hex 2)
    echo ""
}

write_config() {
    local hy2_tls="{
        \"enabled\": true,
        \"certificate_path\": \"$CERT_FILE\",
        \"key_path\": \"$KEY_FILE\",
        \"server_name\": \"$COMMON_SNI\"
    }"

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
        { "uuid": "$UUID", "flow": "" }
      ],
      "transport": {
        "type": "ws",
        "path": "/",
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
        { "password": "$UUID" }
      ],
      "tls": $hy2_tls
    },
    {
      "type": "vless",
      "tag": "VLESS-Reality-in",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        { "uuid": "$UUID", "flow": "xtls-rprx-vision" }
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

setup_iptables() {
    [[ "${HY2_HOP,,}" != "y" || -z "$HY2_PORTS" ]] && return 0

    local start_port=$(echo "$HY2_PORTS" | cut -d'-' -f1)
    local end_port=$(echo "$HY2_PORTS" | cut -d'-' -f2)

    if ! command -v iptables &>/dev/null; then
        warn "未安装 iptables，正在尝试安装..."
        case $PKG_MANAGER in
            apk)  $INSTALL_CMD iptables ip6tables ;;
            apt)  $UPDATE_CMD && $INSTALL_CMD iptables ip6tables ;;
            yum|dnf) $UPDATE_CMD && $INSTALL_CMD iptables iptables-services ;;
            zypper) $UPDATE_CMD && $INSTALL_CMD iptables ;;
        esac
        command -v iptables &>/dev/null || error "iptables 安装失败，请手动安装"
    fi

    iptables -t nat -D PREROUTING -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $HY2_PORT 2>/dev/null || true
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -D PREROUTING -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $HY2_PORT 2>/dev/null || true
    fi

    iptables -t nat -A PREROUTING -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $HY2_PORT
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -A PREROUTING -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $HY2_PORT
        ok "已添加 IPv4 + IPv6 端口跳跃规则 ($start_port-$end_port -> $HY2_PORT)"
    else
        ok "已添加 IPv4 端口跳跃规则 ($start_port-$end_port -> $HY2_PORT)"
    fi

    iptables -I INPUT -p udp --dport $start_port:$end_port -j ACCEPT
    if command -v ip6tables &>/dev/null; then
        ip6tables -I INPUT -p udp --dport $start_port:$end_port -j ACCEPT
    fi

    info "正在持久化 iptables 规则..."
    if [[ "$INIT" == "systemd" ]]; then
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
            ok "已通过 netfilter-persistent 保存"
        elif command -v iptables-save &>/dev/null; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
            [ -f /etc/iptables/rules.v6 ] || ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            systemctl enable iptables-restore 2>/dev/null || true
            systemctl enable ip6tables-restore 2>/dev/null || true
            ok "已保存规则到 /etc/iptables/rules.v4 和 rules.v6"
            warn "请确保系统启动时自动加载这些文件（例如通过 iptables-restore 服务或 rc.local）"
        fi
    elif [[ "$INIT" == "openrc" ]]; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules-save
        if command -v ip6tables &>/dev/null; then
            ip6tables-save > /etc/iptables/rules-save-ip6
        fi
        if [ -f /etc/init.d/iptables ]; then
            rc-update add iptables default 2>/dev/null || true
        fi
        if [ -f /etc/init.d/ip6tables ]; then
            rc-update add ip6tables default 2>/dev/null || true
        fi
        ok "已保存规则到 /etc/iptables/ 并尝试添加启动服务"
    else
        warn "未知 init 系统，请手动持久化 iptables 规则"
    fi
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

get_public_ip() {
    echo ""
    echo "$(timeout 5 curl -s4 --connect-timeout 2 --max-time 4 -k https://ipinfo.io 2>/dev/null | grep -E '"country"|"city"' | sed -e 's/.*"country": "\(.*\)".*/国家: \1/' -e 's/.*"city": "\(.*\)".*/城市: \1/')"

    echo ""
    info "正在获取公网 IP ..."

    local ip_v4=""
    local ip_v6=""
    ip_v4=$(timeout 5 curl -s4 --connect-timeout 2 --max-time 4 -k https://icanhazip.com 2>/dev/null | head -n1)
    ip_v6=$(timeout 5 curl -s6 --connect-timeout 2 --max-time 4 -k https://icanhazip.com 2>/dev/null | head -n1)

    ip_v4=$(echo "$ip_v4" | tr -d '\r\n')
    ip_v6=$(echo "$ip_v6" | tr -d '\r\n')

    if [ -n "$ip_v4" ] && [ -z "$ip_v6" ]; then
        PUBLIC_IP="$ip_v4"; IP_VERSION=4
        ok "IPv4: $PUBLIC_IP"
        return 0
    fi
    if [ -z "$ip_v4" ] && [ -n "$ip_v6" ]; then
        PUBLIC_IP="$ip_v6"; IP_VERSION=6
        ok "IPv6: $PUBLIC_IP"
        return 0
    fi
    if [ -n "$ip_v4" ] && [ -n "$ip_v6" ]; then
        echo ""
        echo "IPv4: $ip_v4"
        echo "IPv6: $ip_v6"
        echo "1) 使用 IPv4"
        echo "2) 使用 IPv6"
        read -p "$(echo -e "${CYAN}请选择节点使用的IP [1-2] (默认 1):${NC} ")" IP_CHOICE
        case "$IP_CHOICE" in
            2) PUBLIC_IP="$ip_v6"; IP_VERSION=6; ok "选择 IPv6: $PUBLIC_IP" ;;
            *) PUBLIC_IP="$ip_v4"; IP_VERSION=4; ok "选择 IPv4: $PUBLIC_IP" ;;
        esac
        return 0
    fi

    warn "所有自动获取方式均失败（超时或不可达），请手动输入公网 IP"
    read -p "$(echo -e "${CYAN}请输入公网 IP:${NC} ")" PUBLIC_IP
    if [ -z "$PUBLIC_IP" ]; then
        error "未输入 IP，无法继续"
    fi
    [[ "$PUBLIC_IP" =~ : ]] && IP_VERSION=6 || IP_VERSION=4
    ok "使用手动输入的 IP: $PUBLIC_IP"
}

output_links() {
    echo ""
    echo -e "${GREEN}节点链接(如果使用vless + ws + cdn 请把端口改成443(security=tls)或80(security=none))：${NC}"

    local ip_for_url="$PUBLIC_IP"
    if [[ "$PUBLIC_IP" =~ : ]]; then
        ip_for_url="[$PUBLIC_IP]"
    fi

    echo -e "vless://$UUID@$WS_DOMAIN:$WS_PORT?encryption=none&security=none&type=ws&host=$WS_DOMAIN&path=#vless-ws"
    echo ""

    echo -e "vless://$UUID@$ip_for_url:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$COMMON_SNI&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID&type=tcp&headerType=none#vless-reality"
    echo ""

    local hy2_link="hysteria2://$UUID@$ip_for_url:$HY2_PORT?security=tls&sni=$COMMON_SNI"
    if [[ "${HY2_HOP,,}" == "y" && -n "$HY2_PORTS" ]]; then
        hy2_link="${hy2_link}&mport=$HY2_PORTS&ports=$HY2_PORTS"
    fi
    hy2_link="${hy2_link}#hy2"
    echo -e "$hy2_link"
    echo ""
    echo -e "${YELLOW}复制链接到客户端即可使用${NC}"
    echo ""
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
    detect_init
    uninstall_old
    install_singbox
    get_config_all
    generate_cert
    generate_reality_keys
    write_config
    setup_iptables
    create_service
    get_public_ip
    output_links
}

main "$@"
