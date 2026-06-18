#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box_multi_protocol_install.sh
# 功能: 一键安装 sing-box，同时配置 VLESS+WS(无TLS)、Hysteria2(TLS)、VLESS+Reality
# 环境: 兼容 systemd / OpenRC，自动适配包管理器
# 用法: bash sing-box_multi_protocol_install.sh
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

# ===================== 原有函数（完全保留，未修改） =====================
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
    local deps="wget tar curl"
    case $PKG_MANAGER in
        apk) 
            $INSTALL_CMD $deps bash
            $INSTALL_CMD gcompat
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

# 原单协议配置（保留但不再调用）
get_config() {
    echo ""
    info "请输入配置信息"
    read -p "$(echo -e "${CYAN}域名 (必填):${NC} ")" DOMAIN
    [[ -z $DOMAIN ]] && error "域名不能为空"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" PORT
    if [[ -z $PORT ]]; then
        PORT=$((RANDOM % 40001 + 10000))
        ok "随机端口: $PORT"
    fi
    read -p "$(echo -e "${CYAN}WebSocket 路径 (默认 /):${NC} ")" WSPATH
    [[ -z $WSPATH ]] && WSPATH="/"
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-WS):${NC} ")" REMARK
    [[ -z $REMARK ]] && REMARK="VLESS-WS"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo ""
    ok "配置信息"
    echo "  域名: $DOMAIN"
    echo "  端口: $PORT"
    echo "  路径: $WSPATH"
    echo "  UUID: $UUID"
    echo "  节点名: $REMARK"
}

write_config() {
    cat > "$CONFIG_JSON" <<EOF
{
  "log": {
    "level": "info",
    "output": "$LOG_DIR/access.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "VLESS-WS-in",
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
        warn "服务可能未正常启动，请检查日志"
    fi
}

output_link() {
    encoded_path=$(echo -n "$WSPATH" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g')
    local vless_link="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=none&type=ws&host=$DOMAIN&path=$encoded_path#$REMARK"
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}              VLESS 链接                ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${CYAN}$vless_link${NC}"
    echo ""
    echo -e "${YELLOW}提示: 复制上述链接到客户端即可使用${NC}"
}

# ===================== 新增功能（多协议） =====================

# 安装额外依赖（openssl）
install_extra_deps() {
    local extra="openssl"
    case $PKG_MANAGER in
        apk) $INSTALL_CMD $extra ;;
        apt) $UPDATE_CMD && $INSTALL_CMD $extra ;;
        yum|dnf) $UPDATE_CMD && $INSTALL_CMD $extra ;;
        zypper) $UPDATE_CMD && $INSTALL_CMD $extra ;;
    esac
    command -v openssl &>/dev/null || error "openssl 安装失败"
}

# URL 编码（复用原逻辑）
url_encode() {
    echo -n "$1" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g'
}

# 清理旧配置
clean_previous() {
    info "清理之前的配置..."
    if [[ $INIT == "systemd" ]]; then
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /lib/systemd/system/sing-box.service
        systemctl daemon-reload
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box stop 2>/dev/null || true
        rc-update del sing-box 2>/dev/null || true
        rm -f /etc/init.d/sing-box
    fi
    rm -rf "$CORE_DIR"
    rm -rf "$LOG_DIR"
    ok "清理完成"
}

# 获取公共域名
get_public_domain() {
    echo ""
    info "请输入公共域名（所有协议共用，用于客户端连接）"
    read -p "$(echo -e "${CYAN}域名 (必填):${NC} ")" PUBLIC_DOMAIN
    [[ -z $PUBLIC_DOMAIN ]] && error "域名不能为空"
}

# 获取 VLESS+WS 配置
get_ws_config() {
    echo ""
    info "--- 配置 VLESS+WS (无 TLS) ---"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" WS_PORT
    [[ -z $WS_PORT ]] && WS_PORT=$((RANDOM % 40001 + 10000))
    read -p "$(echo -e "${CYAN}WebSocket 路径 (默认 /):${NC} ")" WS_PATH
    [[ -z $WS_PATH ]] && WS_PATH="/"
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-WS):${NC} ")" WS_REMARK
    [[ -z $WS_REMARK ]] && WS_REMARK="VLESS-WS"
    WS_UUID=$(cat /proc/sys/kernel/random/uuid)
    ok "WS 端口: $WS_PORT, 路径: $WS_PATH, UUID: $WS_UUID"
}

# 获取 Hysteria2 配置
get_hy2_config() {
    echo ""
    info "--- 配置 Hysteria2 (TLS, 自签名证书) ---"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" HY2_PORT
    [[ -z $HY2_PORT ]] && HY2_PORT=$((RANDOM % 40001 + 10000))
    read -p "$(echo -e "${CYAN}是否开启端口跳跃? (y/n, 默认 n):${NC} ")" HY2_JUMP_ENABLE
    HY2_JUMP_ENABLE=${HY2_JUMP_ENABLE:-n}
    if [[ $HY2_JUMP_ENABLE == "y" || $HY2_JUMP_ENABLE == "Y" ]]; then
        read -p "$(echo -e "${CYAN}起始端口 (默认 $((HY2_PORT+1))):${NC} ")" HY2_JUMP_START
        [[ -z $HY2_JUMP_START ]] && HY2_JUMP_START=$((HY2_PORT+1))
        read -p "$(echo -e "${CYAN}结束端口 (默认 $((HY2_JUMP_START+99))):${NC} ")" HY2_JUMP_END
        [[ -z $HY2_JUMP_END ]] && HY2_JUMP_END=$((HY2_JUMP_START+99))
        # 确保起始 <= 结束
        if [[ $HY2_JUMP_START -gt $HY2_JUMP_END ]]; then
            local tmp=$HY2_JUMP_START
            HY2_JUMP_START=$HY2_JUMP_END
            HY2_JUMP_END=$tmp
        fi
        ok "端口跳跃范围: $HY2_JUMP_START-$HY2_JUMP_END"
    fi
    read -p "$(echo -e "${CYAN}节点名称 (默认 HY2):${NC} ")" HY2_REMARK
    [[ -z $HY2_REMARK ]] && HY2_REMARK="HY2"
    HY2_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n1)
    ok "HY2 端口: $HY2_PORT, 密码: $HY2_PASSWORD"
}

# 获取 VLESS+Reality 配置
get_reality_config() {
    echo ""
    info "--- 配置 VLESS+Reality ---"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" REALITY_PORT
    [[ -z $REALITY_PORT ]] && REALITY_PORT=$((RANDOM % 40001 + 10000))
    read -p "$(echo -e "${CYAN}目标网站 (dest, 默认 www.cloudflare.com):${NC} ")" REALITY_DEST
    [[ -z $REALITY_DEST ]] && REALITY_DEST="www.cloudflare.com"
    read -p "$(echo -e "${CYAN}SNI (server_name, 默认与目标相同):${NC} ")" REALITY_SNI
    [[ -z $REALITY_SNI ]] && REALITY_SNI="$REALITY_DEST"
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-REALITY):${NC} ")" REALITY_REMARK
    [[ -z $REALITY_REMARK ]] && REALITY_REMARK="VLESS-REALITY"
    REALITY_UUID=$(cat /proc/sys/kernel/random/uuid)
    REALITY_SID=$(tr -dc 'a-f0-9' < /dev/urandom | fold -w 8 | head -n1)
    ok "Reality 端口: $REALITY_PORT, 目标: $REALITY_DEST, SNI: $REALITY_SNI"
}

# 生成自签名证书 (用于 HY2)
generate_self_signed_cert() {
    local cert_dir="$CORE_DIR/cert"
    mkdir -p "$cert_dir"
    local cert_file="$cert_dir/cert.crt"
    local key_file="$cert_dir/private.key"
    # 生成 10 年有效期的自签名证书
    openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" -subj "/CN=$PUBLIC_DOMAIN" 2>/dev/null
    chmod 600 "$key_file"
    chmod 644 "$cert_file"
    ok "自签名证书生成: $cert_file"
    HY2_CERT="$cert_file"
    HY2_KEY="$key_file"
}

# 生成 Reality 密钥对
generate_reality_keys() {
    local keypair
    keypair=$("$CORE_BIN" generate reality-keypair)
    REALITY_PRIVATE_KEY=$(echo "$keypair" | grep -oP 'PrivateKey:\s*\K.*' | head -1)
    REALITY_PUBLIC_KEY=$(echo "$keypair" | grep -oP 'PublicKey:\s*\K.*' | head -1)
    if [[ -z $REALITY_PRIVATE_KEY || -z $REALITY_PUBLIC_KEY ]]; then
        error "Reality 密钥生成失败"
    fi
    ok "Reality 密钥对生成成功"
}

# 写入多协议配置文件
write_multi_config() {
    # 构建 WS inbound
    local ws_inbound=$(cat <<EOF
    {
      "type": "vless",
      "tag": "VLESS-WS-in",
      "listen": "::",
      "listen_port": $WS_PORT,
      "users": [
        {
          "uuid": "$WS_UUID",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$WS_PATH",
        "headers": {
          "Host": "$PUBLIC_DOMAIN"
        }
      }
    }
EOF
)

    # 构建 HY2 inbound
    local hy2_inbound=""
    if [[ $HY2_JUMP_ENABLE == "y" || $HY2_JUMP_ENABLE == "Y" ]]; then
        hy2_inbound=$(cat <<EOF
    {
      "type": "hysteria2",
      "tag": "HY2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "ports": ["$HY2_JUMP_START-$HY2_JUMP_END"],
      "users": [
        {
          "password": "$HY2_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$HY2_CERT",
        "key_path": "$HY2_KEY"
      }
    }
EOF
)
    else
        hy2_inbound=$(cat <<EOF
    {
      "type": "hysteria2",
      "tag": "HY2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "password": "$HY2_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$HY2_CERT",
        "key_path": "$HY2_KEY"
      }
    }
EOF
)
    fi

    # 构建 Reality inbound
    local reality_inbound=$(cat <<EOF
    {
      "type": "vless",
      "tag": "REALITY-in",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "uuid": "$REALITY_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "dest": "$REALITY_DEST:443",
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": ["$REALITY_SID"]
        }
      }
    }
EOF
)

    # 生成完整 config.json
    cat > "$CONFIG_JSON" <<EOF
{
  "log": {
    "level": "none"
  },
  "inbounds": [
$ws_inbound,
$hy2_inbound,
$reality_inbound
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    ok "多协议配置文件已生成: $CONFIG_JSON"
}

# 输出所有链接
output_links() {
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}            生成的客户端链接             ${NC}"
    echo -e "${GREEN}=========================================${NC}"

    # 1. VLESS+WS
    local encoded_ws_path=$(url_encode "$WS_PATH")
    local ws_link="vless://$WS_UUID@$PUBLIC_DOMAIN:$WS_PORT?encryption=none&security=none&type=ws&host=$PUBLIC_DOMAIN&path=$encoded_ws_path#$WS_REMARK"
    echo -e "${CYAN}[VLESS+WS]${NC}"
    echo -e "$ws_link"
    echo ""

    # 2. Hysteria2
    local hy2_link="hysteria2://$HY2_PASSWORD@$PUBLIC_DOMAIN:$HY2_PORT?insecure=1&sni=$PUBLIC_DOMAIN"
    if [[ $HY2_JUMP_ENABLE == "y" || $HY2_JUMP_ENABLE == "Y" ]]; then
        hy2_link="${hy2_link}&mport=$HY2_JUMP_START-$HY2_JUMP_END"
    fi
    hy2_link="${hy2_link}#$HY2_REMARK"
    echo -e "${CYAN}[Hysteria2]${NC}"
    echo -e "$hy2_link"
    echo ""

    # 3. VLESS+Reality
    local reality_link="vless://$REALITY_UUID@$PUBLIC_DOMAIN:$REALITY_PORT?encryption=none&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SID&type=tcp&flow=xtls-rprx-vision#$REALITY_REMARK"
    echo -e "${CYAN}[VLESS+Reality]${NC}"
    echo -e "$reality_link"
    echo ""

    echo -e "${YELLOW}提示: 复制对应链接到客户端即可使用${NC}"
}

# ===================== 主流程（重写） =====================
main() {
    [[ $EUID -ne 0 ]] && error "请以 root 用户执行（使用 sudo -i）"

    # 全局变量
    CORE_DIR="/etc/sing-box"
    CONF_DIR="$CORE_DIR/conf"
    LOG_DIR="/var/log/sing-box"
    CORE_BIN="$CORE_DIR/bin/sing-box"
    CONFIG_JSON="$CORE_DIR/config.json"

    detect_pkg_manager
    install_deps
    install_extra_deps        # 额外安装 openssl
    get_arch
    detect_init

    # 清理旧配置（必须在安装前，因为安装时会创建目录）
    clean_previous

    # 安装 sing-box（会创建目录）
    install_singbox

    # 获取公共配置
    get_public_domain

    # 获取各协议配置
    get_ws_config
    get_hy2_config
    get_reality_config

    # 生成证书和密钥（依赖 CORE_BIN 和 PUBLIC_DOMAIN）
    generate_self_signed_cert
    generate_reality_keys

    # 写入多协议配置
    write_multi_config

    # 创建服务（原函数，使用新配置文件）
    create_service

    # 输出链接
    output_links
}

main "$@"
