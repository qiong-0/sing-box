#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box 多协议一键安装脚本
# 功能: 一键安装 sing-box，支持 VLESS+WS、HY2+TLS、VLESS+Reality
# 环境: 兼容 systemd / OpenRC，自动适配包管理器，支持 LXC 轻量容器
# 用法: bash sing-box-multi-protocol.sh
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

error() { echo -e "${RED}错误:${NC} $*" >&2; exit 1; }
warn()  { echo -e "${YELLOW}警告:${NC} $*"; }
info()  { echo -e "${CYAN}>>>${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
bold()  { echo -e "${BOLD}$*${NC}"; }

# 全局变量
CORE_DIR="/etc/sing-box"
CONF_DIR="$CORE_DIR/conf"
LOG_DIR="/var/log/sing-box"
CORE_BIN="$CORE_DIR/bin/sing-box"
CONFIG_JSON="$CORE_DIR/config.json"
CERT_DIR="$CORE_DIR/certs"

# 协议配置数组
declare -a PROTOCOLS_TO_INSTALL=()
declare -A PROTOCOL_CONFIGS=()

# 检测包管理器
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
        error "不支持的包管理器，请手动安装 wget、tar、curl"
    fi
}

# 安装必要工具
install_deps() {
    local deps="wget tar curl openssl"
    case $PKG_MANAGER in
        apk) 
            $INSTALL_CMD $deps bash jq
            $INSTALL_CMD gcompat libcap
            ;;
        apt) 
            $UPDATE_CMD && $INSTALL_CMD $deps jq
            ;;
        yum|dnf) 
            $UPDATE_CMD && $INSTALL_CMD $deps jq
            ;;
        zypper) 
            $UPDATE_CMD && $INSTALL_CMD $deps jq
            ;;
    esac
    command -v wget &>/dev/null || error "wget 安装失败"
    command -v tar  &>/dev/null || error "tar 安装失败"
    command -v curl &>/dev/null || error "curl 安装失败"
    command -v openssl &>/dev/null || error "openssl 安装失败"
    command -v jq &>/dev/null || error "jq 安装失败"
}

# 检测 init 系统
detect_init() {
    if [[ -d /run/systemd/system ]] || command -v systemctl &>/dev/null; then
        INIT="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT="openrc"
    elif [[ -f /etc/init.d/rc ]] || [[ -d /etc/init.d ]]; then
        # 尝试 OpenRC 兼容模式
        INIT="openrc"
    else
        error "未检测到 systemd 或 OpenRC，请确认系统环境"
    fi
    ok "init 系统: $INIT"
}

# 获取系统架构
get_arch() {
    case $(uname -m) in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv8l) ARCH="armv7" ;;
        *) error "不支持的系统架构: $(uname -m)" ;;
    esac
    ok "系统架构: $ARCH"
}

# 获取本机 IP
get_server_ip() {
    local ip
    ip=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 ip.sb 2>/dev/null || echo "unknown")
    echo "$ip"
}

# 下载并安装 sing-box 二进制
install_singbox() {
    local latest_url version download_url
    info "获取 sing-box 最新版本..."
    latest_url=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    [[ -z $latest_url ]] && latest_url="v1.12.1"
    version=${latest_url#v}
    download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_url}/sing-box-${version}-linux-${ARCH}.tar.gz"
    info "下载 sing-box: $download_url"
    wget --no-check-certificate -q -O /tmp/sing-box.tar.gz "$download_url" || error "下载 sing-box 失败"
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/ || error "解压失败"
    mkdir -p "$CORE_DIR/bin" "$CONF_DIR" "$LOG_DIR" "$CERT_DIR"
    cp "/tmp/sing-box-${version}-linux-${ARCH}/sing-box" "$CORE_BIN" 2>/dev/null || \
    cp "/tmp/sing-box" "$CORE_BIN" 2>/dev/null || \
    find /tmp -name "sing-box" -type f -executable -exec cp {} "$CORE_BIN" \;
    chmod +x "$CORE_BIN"
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${version}-linux-${ARCH}"
    ok "sing-box 安装完成: $($CORE_BIN version 2>/dev/null | head -n1 || echo 'unknown')"
}

# 生成随机端口
random_port() {
    echo $((RANDOM % 40001 + 10000))
}

# 协议选择菜单
select_protocols() {
    echo ""
    bold "============================================"
    bold "     请选择要安装的协议（可多选）"
    bold "============================================"
    echo -e "${CYAN}1) VLESS + WebSocket (无 TLS)${NC}"
    echo -e "${CYAN}2) Hysteria2 + TLS (支持端口跳跃)${NC}"
    echo -e "${CYAN}3) VLESS + Reality${NC}"
    echo -e "${YELLOW}0) 开始安装${NC}"
    echo ""
    
    while true; do
        read -p "$(echo -e "${CYAN}请选择 [用空格分隔多个选项，如 1 2 3，输入 0 开始]: ${NC}")" choices
        if [[ "$choices" == "0" ]]; then
            [[ ${#PROTOCOLS_TO_INSTALL[@]} -eq 0 ]] && error "请至少选择一种协议"
            break
        fi
        PROTOCOLS_TO_INSTALL=()
        for c in $choices; do
            case $c in
                1) PROTOCOLS_TO_INSTALL+=("vless-ws") ;;
                2) PROTOCOLS_TO_INSTALL+=("hy2") ;;
                3) PROTOCOLS_TO_INSTALL+=("vless-reality") ;;
                *) warn "无效选项: $c" ;;
            esac
        done
        [[ ${#PROTOCOLS_TO_INSTALL[@]} -gt 0 ]] && break
    done
    
    ok "已选择协议: ${PROTOCOLS_TO_INSTALL[*]}"
}

# 全局配置
get_global_config() {
    echo ""
    info "请输入全局配置信息"
    
    read -p "$(echo -e "${CYAN}域名 (必填，Reality 协议也需要):${NC} ")" GLOBAL_DOMAIN
    [[ -z $GLOBAL_DOMAIN ]] && error "域名不能为空"
    
    read -p "$(echo -e "${CYAN}基础端口 (回车随机 10000-50000):${NC} ")" GLOBAL_PORT
    if [[ -z $GLOBAL_PORT ]]; then
        GLOBAL_PORT=$(random_port)
        ok "随机端口: $GLOBAL_PORT"
    fi
    
    read -p "$(echo -e "${CYAN}节点名称前缀 (默认 sing-box):${NC} ")" NODE_PREFIX
    [[ -z $NODE_PREFIX ]] && NODE_PREFIX="sing-box"
    
    SERVER_IP=$(get_server_ip)
    ok "检测到服务器 IP: $SERVER_IP"
}

# 获取 VLESS-WS 配置
get_vless_ws_config() {
    echo ""
    bold "--- VLESS + WebSocket 配置 ---"
    
    read -p "$(echo -e "${CYAN}端口 (回车使用基础端口 $GLOBAL_PORT):${NC} ")" VLESS_WS_PORT
    [[ -z $VLESS_WS_PORT ]] && VLESS_WS_PORT=$GLOBAL_PORT
    
    read -p "$(echo -e "${CYAN}WebSocket 路径 (默认 /):${NC} ")" VLESS_WS_PATH
    [[ -z $VLESS_WS_PATH ]] && VLESS_WS_PATH="/"
    
    read -p "$(echo -e "${CYAN}节点名称 (默认 ${NODE_PREFIX}-VLESS-WS):${NC} ")" VLESS_WS_REMARK
    [[ -z $VLESS_WS_REMARK ]] && VLESS_WS_REMARK="${NODE_PREFIX}-VLESS-WS"
    
    VLESS_WS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    
    ok "VLESS-WS 配置完成"
}

# 获取 HY2 配置
get_hy2_config() {
    echo ""
    bold "--- Hysteria2 + TLS 配置 ---"
    
    read -p "$(echo -e "${CYAN}端口 (回车使用基础端口 $GLOBAL_PORT):${NC} ")" HY2_PORT
    [[ -z $HY2_PORT ]] && HY2_PORT=$GLOBAL_PORT
    
    # 端口跳跃选项
    echo -e "${CYAN}是否启用端口跳跃？(y/n)${NC}"
    read -p "$(echo -e "${CYAN}端口跳跃可以将流量分散到多个端口，提高可用性: ${NC}")" ENABLE_PORT_HOPPING
    HY2_PORT_HOPPING="false"
    HY2_HOP_PORTS=""
    if [[ "$ENABLE_PORT_HOPPING" =~ ^[Yy]$ ]]; then
        HY2_PORT_HOPPING="true"
        read -p "$(echo -e "${CYAN}跳跃端口数量 (默认 3):${NC} ")" HOP_COUNT
        [[ -z $HOP_COUNT ]] && HOP_COUNT=3
        HY2_HOP_PORTS=""
        for ((i=1; i<HOP_COUNT; i++)); do
            hop_port=$(random_port)
            if [[ -n "$HY2_HOP_PORTS" ]]; then
                HY2_HOP_PORTS="$HY2_HOP_PORTS,$hop_port"
            else
                HY2_HOP_PORTS="$hop_port"
            fi
        done
        ok "跳跃端口: $HY2_PORT,$HY2_HOP_PORTS"
    fi
    
    read -p "$(echo -e "${CYAN}节点名称 (默认 ${NODE_PREFIX}-HY2):${NC} ")" HY2_REMARK
    [[ -z $HY2_REMARK ]] && HY2_REMARK="${NODE_PREFIX}-HY2"
    
    read -p "$(echo -e "${CYAN}Hy2 密码 (回车自动生成):${NC} ")" HY2_PASSWORD
    [[ -z $HY2_PASSWORD ]] && HY2_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
    
    # 生成自签名证书
    generate_hy2_cert
    
    ok "HY2 配置完成"
}

# 生成 HY2 自签名证书
generate_hy2_cert() {
    info "生成 Hysteria2 TLS 证书..."
    mkdir -p "$CERT_DIR"
    HY2_CERT_FILE="$CERT_DIR/hy2.crt"
    HY2_KEY_FILE="$CERT_DIR/hy2.key"
    
    openssl ecparam -genkey -name prime256v1 -out "$HY2_KEY_FILE" 2>/dev/null || \
    openssl genpkey -algorithm EC -out "$HY2_KEY_FILE" -pkeyopt ec_paramgen_curve:prime256v1 2>/dev/null || \
    error "生成 EC 私钥失败"
    
    openssl req -new -x509 -days 3650 -key "$HY2_KEY_FILE" -out "$HY2_CERT_FILE" \
        -subj "/CN=$GLOBAL_DOMAIN/O=Hysteria2/C=US" \
        -addext "subjectAltName=DNS:$GLOBAL_DOMAIN" 2>/dev/null || \
    openssl req -new -x509 -days 3650 -key "$HY2_KEY_FILE" -out "$HY2_CERT_FILE" \
        -subj "/CN=$GLOBAL_DOMAIN" 2>/dev/null || \
    error "生成证书失败"
    
    chmod 644 "$HY2_CERT_FILE"
    chmod 600 "$HY2_KEY_FILE"
    ok "TLS 证书已生成: $HY2_CERT_FILE"
}

# 获取 VLESS-Reality 配置
get_vless_reality_config() {
    echo ""
    bold "--- VLESS + Reality 配置 ---"
    
    read -p "$(echo -e "${CYAN}端口 (回车使用基础端口 $GLOBAL_PORT):${NC} ")" REALITY_PORT
    [[ -z $REALITY_PORT ]] && REALITY_PORT=$GLOBAL_PORT
    
    read -p "$(echo -e "${CYAN}节点名称 (默认 ${NODE_PREFIX}-Reality):${NC} ")" REALITY_REMARK
    [[ -z $REALITY_REMARK ]] && REALITY_REMARK="${NODE_PREFIX}-Reality"
    
    REALITY_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    
    # 生成 Reality 密钥对
    info "生成 Reality 密钥对..."
    local keypair
    keypair=$($CORE_BIN generate reality-keypair 2>/dev/null || echo "")
    if [[ -n "$keypair" ]]; then
        REALITY_PRIVATE_KEY=$(echo "$keypair" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
        REALITY_PUBLIC_KEY=$(echo "$keypair" | grep "PublicKey" | awk '{print $2}' | tr -d '"')
    else
        # 备用方案：使用 openssl 生成
        REALITY_PRIVATE_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 64)
        REALITY_PUBLIC_KEY=$(echo -n "$REALITY_PRIVATE_KEY" | rev | base64)
    fi
    
    [[ -z "$REALITY_PRIVATE_KEY" ]] && error "生成 Reality 私钥失败"
    [[ -z "$REALITY_PUBLIC_KEY" ]] && error "生成 Reality 公钥失败"
    
    # 设置 Reality 目标
    REALITY_SERVER_NAMES="www.microsoft.com,www.apple.com,www.amazon.com,www.cloudflare.com"
    read -p "$(echo -e "${CYAN}Reality 伪装域名 (回车使用默认随机):${NC} ")" REALITY_DEST
    if [[ -z $REALITY_DEST ]]; then
        REALITY_DEST=$(echo "$REALITY_SERVER_NAMES" | tr ',' '\n' | shuf -n1)
    fi
    
    ok "VLESS-Reality 配置完成"
}

# URL 编码函数
url_encode() {
    local string="$1"
    local length="${#string}"
    local encoded=""
    local pos c
    for ((pos = 0; pos < length; pos++)); do
        c="${string:$pos:1}"
        case "$c" in
            [-_.~a-zA-Z0-9]) encoded+="$c" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$encoded"
}

# 生成 sing-box 配置文件
write_config() {
    info "生成 sing-box 配置文件..."
    
    local inbounds="[]"
    local first=true
    
    for proto in "${PROTOCOLS_TO_INSTALL[@]}"; do
        case $proto in
            "vless-ws")
                local vless_inbound
                vless_inbound=$(cat <<EOF
{
  "type": "vless",
  "tag": "vless-ws-in",
  "listen": "::",
  "listen_port": $VLESS_WS_PORT,
  "users": [
    {
      "uuid": "$VLESS_WS_UUID",
      "flow": ""
    }
  ],
  "transport": {
    "type": "ws",
    "path": "$VLESS_WS_PATH",
    "headers": {
      "Host": "$GLOBAL_DOMAIN"
    }
  }
}
EOF
)
                if $first; then
                    inbounds="[$vless_inbound"
                    first=false
                else
                    inbounds="$inbounds,$vless_inbound"
                fi
                ;;
            "hy2")
                # 主端口
                local hy2_inbound
                hy2_inbound=$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "hy2-in",
  "listen": "::",
  "listen_port": $HY2_PORT,
  "users": [
    {
      "password": "$HY2_PASSWORD"
    }
  ],
  "tls": {
    "enabled": true,
    "certificate_path": "$HY2_CERT_FILE",
    "key_path": "$HY2_KEY_FILE"
  }
}
EOF
)
                if $first; then
                    inbounds="[$hy2_inbound"
                    first=false
                else
                    inbounds="$inbounds,$hy2_inbound"
                fi
                
                # 端口跳跃的额外端口
                if [[ "$HY2_PORT_HOPPING" == "true" ]] && [[ -n "$HY2_HOP_PORTS" ]]; then
                    IFS=',' read -ra HOP_PORTS <<< "$HY2_HOP_PORTS"
                    local idx=1
                    for hop_port in "${HOP_PORTS[@]}"; do
                        local hop_inbound
                        hop_inbound=$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "hy2-hop-${idx}-in",
  "listen": "::",
  "listen_port": $hop_port,
  "users": [
    {
      "password": "$HY2_PASSWORD"
    }
  ],
  "tls": {
    "enabled": true,
    "certificate_path": "$HY2_CERT_FILE",
    "key_path": "$HY2_KEY_FILE"
  }
}
EOF
)
                        inbounds="$inbounds,$hop_inbound"
                        ((idx++))
                    done
                fi
                ;;
            "vless-reality")
                local reality_inbound
                reality_inbound=$(cat <<EOF
{
  "type": "vless",
  "tag": "vless-reality-in",
  "listen": "::",
  "listen_port": $REALITY_PORT,
  "users": [
    {
      "name": "sing-box-user",
      "uuid": "$REALITY_UUID",
      "flow": ""
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "$REALITY_DEST",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "$REALITY_DEST",
        "server_port": 443
      },
      "private_key": "$REALITY_PRIVATE_KEY",
      "short_id": [
        ""
      ]
    }
  }
}
EOF
)
                if $first; then
                    inbounds="[$reality_inbound"
                    first=false
                else
                    inbounds="$inbounds,$reality_inbound"
                fi
                ;;
        esac
    done
    
    inbounds="$inbounds]"
    
    # 生成完整配置
    cat > "$CONFIG_JSON" <<EOF
{
  "log": {
    "level": "info",
    "output": "$LOG_DIR/access.log",
    "timestamp": true
  },
  "inbounds": $inbounds,
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "block"
      }
    ]
  }
}
EOF
    
    ok "配置文件已生成: $CONFIG_JSON"
}

# 创建服务
create_service() {
    info "创建系统服务..."
    
    if [[ $INIT == "systemd" ]]; then
        cat > /lib/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Multi-Protocol Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$CORE_BIN run -c $CONFIG_JSON
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable sing-box 2>/dev/null || true
        systemctl start sing-box 2>/dev/null || true
        ok "systemd 服务已创建并启动"
    else  # openrc
        cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box multi-protocol proxy service"
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
        rc-update add sing-box default 2>/dev/null || true
        rc-service sing-box start 2>/dev/null || true
        ok "OpenRC 服务已创建并启动"
    fi
    
    sleep 2
    
    # 检查服务状态
    if [[ $INIT == "systemd" ]]; then
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            ok "服务运行正常"
        else
            warn "服务可能未正常启动，请检查配置"
        fi
    else
        if rc-service sing-box status 2>/dev/null | grep -q "started"; then
            ok "服务运行正常"
        else
            warn "服务可能未正常启动，请检查配置"
        fi
    fi
}

# 输出 VLESS-WS 链接
output_vless_ws_link() {
    local encoded_path
    encoded_path=$(url_encode "$VLESS_WS_PATH")
    local vless_link="vless://$VLESS_WS_UUID@$SERVER_IP:$VLESS_WS_PORT?encryption=none&security=none&type=ws&host=$GLOBAL_DOMAIN&path=$encoded_path#$(url_encode "$VLESS_WS_REMARK")"
    
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}        VLESS + WebSocket 链接          ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${CYAN}$vless_link${NC}"
    echo ""
}

# 输出 HY2 链接
output_hy2_link() {
    # 主链接
    local hy2_link="hysteria2://$HY2_PASSWORD@$SERVER_IP:$HY2_PORT?insecure=1&sni=$GLOBAL_DOMAIN#$(url_encode "$HY2_REMARK")"
    
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}        Hysteria2 + TLS 链接             ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${CYAN}主端口链接:${NC}"
    echo -e "${CYAN}$hy2_link${NC}"
    
    # 如果有端口跳跃，生成多端口链接
    if [[ "$HY2_PORT_HOPPING" == "true" ]] && [[ -n "$HY2_HOP_PORTS" ]]; then
        echo -e "${YELLOW}端口跳跃链接:${NC}"
        IFS=',' read -ra HOP_PORTS <<< "$HY2_HOP_PORTS"
        for hop_port in "${HOP_PORTS[@]}"; do
            local hop_link="hysteria2://$HY2_PASSWORD@$SERVER_IP:$hop_port?insecure=1&sni=$GLOBAL_DOMAIN#$(url_encode "$HY2_REMARK-hop")"
            echo -e "${CYAN}$hop_link${NC}"
        done
    fi
    echo ""
}

# 输出 VLESS-Reality 链接
output_vless_reality_link() {
    local reality_link="vless://$REALITY_UUID@$SERVER_IP:$REALITY_PORT?encryption=none&security=reality&type=tcp&sni=$REALITY_DEST&pbk=$REALITY_PUBLIC_KEY&fp=chrome#$(url_encode "$REALITY_REMARK")"
    
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}        VLESS + Reality 链接             ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${CYAN}$reality_link${NC}"
    echo ""
}

# 显示所有链接
output_links() {
    echo ""
    bold "============================================"
    bold "          配置完成！以下是连接信息          "
    bold "============================================"
    echo -e "${YELLOW}服务器 IP: $SERVER_IP${NC}"
    echo -e "${YELLOW}域名: $GLOBAL_DOMAIN${NC}"
    echo ""
    
    for proto in "${PROTOCOLS_TO_INSTALL[@]}"; do
        case $proto in
            "vless-ws") output_vless_ws_link ;;
            "hy2") output_hy2_link ;;
            "vless-reality") output_vless_reality_link ;;
        esac
    done
    
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${YELLOW}提示: 复制上述链接到客户端即可使用${NC}"
}

# 主流程
main() {
    # 检查 root
    [[ $EUID -ne 0 ]] && error "请以 root 用户执行（使用 sudo -i）"
    
    bold "============================================"
    bold "   Sing-Box 多协议一键安装脚本"
    bold "   支持: VLESS-WS | HY2-TLS | VLESS-Reality"
    bold "============================================"
    echo ""
    
    detect_pkg_manager
    install_deps
    get_arch
    detect_init
    install_singbox
    
    select_protocols
    get_global_config
    
    for proto in "${PROTOCOLS_TO_INSTALL[@]}"; do
        case $proto in
            "vless-ws") get_vless_ws_config ;;
            "hy2") get_hy2_config ;;
            "vless-reality") get_vless_reality_config ;;
        esac
    done
    
    write_config
    create_service
    output_links
    
    bold "============================================"
    bold "            安装完成！"
    bold "============================================"
}

main "$@"
