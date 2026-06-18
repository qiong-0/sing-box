#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box_multi_install.sh
# 功能: 一键安装 sing-box，配置三个协议：
#       1. VLESS + WebSocket (无 TLS)
#       2. Hysteria2 + TLS (支持端口跳跃)
#       3. VLESS + Reality
# 环境: 兼容 systemd / OpenRC，自动适配包管理器，修复所有已知问题
# 用法: bash sing-box_multi_install.sh
#===============================================================================

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

error() { echo -e "${RED}错误:${NC} $*" >&2; exit 1; }
warn()  { echo -e "${YELLOW}警告:${NC} $*"; }
info()  { echo -e "${CYAN}>>>${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }

# URL 编码函数（用于路径）
urlencode() {
    local string="$1"
    local encoded=""
    local length="${#string}"
    for (( i=0; i<length; i++ )); do
        local char="${string:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) encoded+="$char" ;;
            ' ') encoded+="%20" ;;
            *) printf -v encoded '%s%%%02X' "$encoded" "'$char" ;;
        esac
    done
    echo "$encoded"
}

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
        error "不支持的包管理器，请手动安装 wget、tar、curl、openssl"
    fi
}

# 安装必要工具
install_deps() {
    local deps="wget tar curl openssl"
    case $PKG_MANAGER in
        apk) 
            $INSTALL_CMD $deps bash
            $INSTALL_CMD gcompat   # 解决 glibc 兼容性问题
            ;;
        apt) 
            $UPDATE_CMD && $INSTALL_CMD $deps 
            ;;
        yum|dnf|zypper) 
            $UPDATE_CMD && $INSTALL_CMD $deps 
            ;;
    esac
    command -v wget &>/dev/null || error "wget 安装失败"
    command -v tar  &>/dev/null || error "tar 安装失败"
    command -v curl &>/dev/null || error "curl 安装失败"
    command -v openssl &>/dev/null || error "openssl 安装失败"
}

# 检测 init 系统
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

# 获取系统架构
get_arch() {
    case $(uname -m) in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) error "不支持的系统架构: $(uname -m)" ;;
    esac
    ok "系统架构: $ARCH"
}

# 下载并安装 sing-box 二进制
install_singbox() {
    local latest_url
    latest_url=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    [[ -z $latest_url ]] && latest_url="v1.12.1"
    local version=${latest_url#v}
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_url}/sing-box-${version}-linux-${ARCH}.tar.gz"
    info "下载 sing-box: $download_url"
    wget --no-check-certificate -O /tmp/sing-box.tar.gz "$download_url" || error "下载失败"
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/ || error "解压失败"
    mkdir -p "$CORE_DIR/bin" "$CONF_DIR" "$LOG_DIR"
    cp "/tmp/sing-box-${version}-linux-${ARCH}/sing-box" "$CORE_BIN"
    chmod +x "$CORE_BIN"
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${version}-linux-${ARCH}"
    ok "sing-box 安装完成: $($CORE_BIN version | head -n1)"
}

# 交互式获取配置
get_config() {
    echo ""
    info "请输入公共配置信息"
    read -p "$(echo -e "${CYAN}域名 (必填):${NC} ")" DOMAIN
    [[ -z $DOMAIN ]] && error "域名不能为空"

    echo ""
    info "配置 VLESS+WS"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" PORT_WS
    [[ -z $PORT_WS ]] && PORT_WS=$((RANDOM % 40001 + 10000))
    read -p "$(echo -e "${CYAN}WebSocket 路径 (默认 /):${NC} ")" WSPATH
    [[ -z $WSPATH ]] && WSPATH="/"
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-WS):${NC} ")" REMARK_WS
    [[ -z $REMARK_WS ]] && REMARK_WS="VLESS-WS"

    echo ""
    info "配置 Hysteria2+TLS"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" PORT_HY2
    [[ -z $PORT_HY2 ]] && PORT_HY2=$((RANDOM % 40001 + 10000))
    read -p "$(echo -e "${CYAN}是否启用端口跳跃？(y/n，默认 n):${NC} ")" ENABLE_HOP
    [[ -z $ENABLE_HOP ]] && ENABLE_HOP="n"
    if [[ $ENABLE_HOP =~ ^[Yy]$ ]]; then
        read -p "$(echo -e "${CYAN}跳跃端口结束端口 (起始为 $PORT_HY2，请输入结束端口):${NC} ")" PORT_HOP_END
        if [[ -z $PORT_HOP_END || $PORT_HOP_END -le $PORT_HY2 ]]; then
            error "结束端口必须大于起始端口"
        fi
        PORT_HOP_START=$PORT_HY2
    else
        PORT_HOP_START=""
        PORT_HOP_END=""
    fi
    read -p "$(echo -e "${CYAN}节点名称 (默认 HY2-TLS):${NC} ")" REMARK_HY2
    [[ -z $REMARK_HY2 ]] && REMARK_HY2="HY2-TLS"

    echo ""
    info "配置 VLESS+Reality"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" PORT_REAL
    [[ -z $PORT_REAL ]] && PORT_REAL=$((RANDOM % 40001 + 10000))
    read -p "$(echo -e "${CYAN}目标网站 (用于 SNI，默认 www.bing.com):${NC} ")" DEST
    [[ -z $DEST ]] && DEST="www.bing.com"
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-Reality):${NC} ")" REMARK_REAL
    [[ -z $REMARK_REAL ]] && REMARK_REAL="VLESS-Reality"

    # 生成 UUID
    UUID_WS=$(cat /proc/sys/kernel/random/uuid)
    UUID_REAL=$(cat /proc/sys/kernel/random/uuid)
    # Hysteria2 密码
    HY2_PASS=$(openssl rand -base64 12 | tr -d '\n' | tr -d '=' | tr -d '+/')
    ok "配置信息汇总"
    echo "  域名: $DOMAIN"
    echo "  WS 端口: $PORT_WS 路径: $WSPATH"
    echo "  HY2 端口: $PORT_HY2 跳跃: ${ENABLE_HOP^^} ${PORT_HOP_START:+范围 $PORT_HOP_START-$PORT_HOP_END}"
    echo "  Reality 端口: $PORT_REAL 目标: $DEST"
}

# 生成自签名证书
generate_cert() {
    info "生成自签名证书 (用于 Hysteria2 TLS)"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CORE_DIR/key.pem" -out "$CORE_DIR/cert.pem" \
        -subj "/CN=$DOMAIN" >/dev/null 2>&1
    ok "证书生成完成: $CORE_DIR/cert.pem, $CORE_DIR/key.pem"
}

# 生成 Reality 密钥对
generate_reality_keys() {
    info "生成 Reality 密钥对"
    local key_output
    key_output=$($CORE_BIN generate reality-keypair)
    PRIVATE_KEY=$(echo "$key_output" | grep -oP 'PrivateKey:\s*\K.*' | tr -d ' ')
    PUBLIC_KEY=$(echo "$key_output" | grep -oP 'PublicKey:\s*\K.*' | tr -d ' ')
    SHORT_ID=$($CORE_BIN generate rand 8)
    ok "Reality 密钥生成完成"
}

# 生成 config.json（修正版：无 transport 字段，自动清理 \r）
write_config() {
    info "生成配置文件 $CONFIG_JSON"

    # 构建 Hysteria2 的 port_hopping 部分（如果启用）
    local port_hopping_json=""
    if [[ $ENABLE_HOP =~ ^[Yy]$ ]]; then
        port_hopping_json="\"port_hopping\": { \"enabled\": true, \"range\": [$PORT_HOP_START, $PORT_HOP_END] },"
    fi

    cat > "$CONFIG_JSON" <<EOF
{
  "log": {
    "level": "warning",
    "output": "/dev/null"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "VLESS-WS",
      "listen": "::",
      "listen_port": $PORT_WS,
      "users": [
        { "uuid": "$UUID_WS", "flow": "" }
      ],
      "transport": {
        "type": "ws",
        "path": "$WSPATH",
        "headers": { "Host": "$DOMAIN" }
      }
    },
    {
      "type": "hysteria2",
      "tag": "HY2-TLS",
      "listen": "::",
      "listen_port": $PORT_HY2,
      "users": [
        { "name": "default", "password": "$HY2_PASS" }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CORE_DIR/cert.pem",
        "key_path": "$CORE_DIR/key.pem"
      },
      $port_hopping_json
      "ignore_client_bandwidth": false
    },
    {
      "type": "vless",
      "tag": "VLESS-Reality",
      "listen": "::",
      "listen_port": $PORT_REAL,
      "users": [
        { "uuid": "$UUID_REAL", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DEST",
        "reality": {
          "enabled": true,
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

    # 清理可能存在的 Windows 换行符（\r）
    sed -i 's/\r$//' "$CONFIG_JSON"
    ok "配置文件已生成"
}

# 创建服务 (systemd 或 openrc)
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
    else  # openrc
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
    # 检查服务状态
    local status_ok=false
    if [[ $INIT == "systemd" ]] && systemctl is-active --quiet sing-box; then
        status_ok=true
    elif [[ $INIT == "openrc" ]] && rc-service sing-box status | grep -q "started"; then
        status_ok=true
    fi

    if $status_ok; then
        ok "服务运行正常"
    else
        warn "服务可能未正常启动，请手动检查："
        echo "  1. 运行 $CORE_BIN run -c $CONFIG_JSON 查看错误"
        echo "  2. 检查端口是否被占用：netstat -tulnp | grep -E '$PORT_WS|$PORT_HY2|$PORT_REAL'"
        echo "  3. 确认证书文件存在：ls -l $CORE_DIR/cert.pem $CORE_DIR/key.pem"
        echo "  4. 若使用 Alpine，确保已安装 gcompat"
    fi
}

# 生成并输出链接
output_links() {
    # 编码路径
    encoded_path=$(urlencode "$WSPATH")

    # VLESS+WS 链接
    local link_ws="vless://$UUID_WS@$DOMAIN:$PORT_WS?encryption=none&security=none&type=ws&host=$DOMAIN&path=$encoded_path#$REMARK_WS"

    # Hysteria2 链接（仅单端口，端口跳跃由服务端处理）
    local link_hy2="hysteria2://$DOMAIN:$PORT_HY2?auth=$HY2_PASS&peer=$DOMAIN&insecure=1#$REMARK_HY2"
    if [[ $ENABLE_HOP =~ ^[Yy]$ ]]; then
        link_hy2="$link_hy2 (端口跳跃范围: $PORT_HOP_START-$PORT_HOP_END，客户端无需额外配置)"
    fi

    # VLESS+Reality 链接
    local link_reality="vless://$UUID_REAL@$DOMAIN:$PORT_REAL?encryption=none&security=reality&sni=$DEST&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#$REMARK_REAL"

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}             客户端链接                  ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo -e "${CYAN}VLESS+WS:${NC}"
    echo -e "$link_ws"
    echo ""
    echo -e "${CYAN}Hysteria2+TLS:${NC}"
    echo -e "$link_hy2"
    echo ""
    echo -e "${CYAN}VLESS+Reality:${NC}"
    echo -e "$link_reality"
    echo ""
    echo -e "${YELLOW}提示: 复制相应链接到客户端即可使用${NC}"
    echo -e "${YELLOW}注意: Hysteria2 使用自签名证书，客户端需忽略证书验证 (insecure=1)${NC}"
}

# 主流程
main() {
    # 检查 root
    [[ $EUID -ne 0 ]] && error "请以 root 用户执行（使用 sudo -i）"

    # 全局变量
    CORE_DIR="/etc/sing-box"
    CONF_DIR="$CORE_DIR/conf"
    LOG_DIR="/var/log/sing-box"
    CORE_BIN="$CORE_DIR/bin/sing-box"
    CONFIG_JSON="$CORE_DIR/config.json"

    detect_pkg_manager
    install_deps
    get_arch
    detect_init
    install_singbox
    get_config
    generate_cert
    generate_reality_keys
    write_config
    create_service
    output_links
}

main "$@"
