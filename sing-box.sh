#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box_multi_inbound_install.sh
# 功能: 一键安装 sing-box，同时配置 VLESS+WebSocket (无 TLS) 和 VLESS+Reality
# 环境: 兼容 systemd / OpenRC，自动适配包管理器
# 用法: bash sing-box_multi_inbound_install.sh
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
    local deps="wget tar curl"
    case $PKG_MANAGER in
        apk) 
            $INSTALL_CMD $deps bash        # 安装原有依赖
            $INSTALL_CMD gcompat           # 添加 gcompat 解决 glibc 兼容性问题
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

# 生成 Reality 密钥对
generate_reality_keypair() {
    local keypair=$($CORE_BIN generate reality-keypair)
    PRIVATE_KEY=$(echo "$keypair" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$keypair" | grep "PublicKey" | awk '{print $2}')
    if [[ -z $PRIVATE_KEY || -z $PUBLIC_KEY ]]; then
        error "生成 Reality 密钥对失败"
    fi
}

# 交互式获取配置 (同时获取两个入站的配置)
get_config() {
    echo ""
    info "请输入 VLESS+WebSocket 配置"
    read -p "$(echo -e "${CYAN}域名 (必填):${NC} ")" DOMAIN
    [[ -z $DOMAIN ]] && error "域名不能为空"
    read -p "$(echo -e "${CYAN}WS 端口 (回车随机 10000-50000):${NC} ")" WS_PORT
    if [[ -z $WS_PORT ]]; then
        WS_PORT=$((RANDOM % 40001 + 10000))
        ok "随机 WS 端口: $WS_PORT"
    fi
    read -p "$(echo -e "${CYAN}WebSocket 路径 (默认 /):${NC} ")" WSPATH
    [[ -z $WSPATH ]] && WSPATH="/"
    read -p "$(echo -e "${CYAN}WS 节点名称 (默认 VLESS-WS):${NC} ")" WS_REMARK
    [[ -z $WS_REMARK ]] && WS_REMARK="VLESS-WS"

    echo ""
    info "请输入 VLESS+Reality 配置"
    read -p "$(echo -e "${CYAN}Reality 端口 (回车随机 10000-50000，建议与 WS 不同):${NC} ")" REALITY_PORT
    if [[ -z $REALITY_PORT ]]; then
        REALITY_PORT=$((RANDOM % 40001 + 10000))
        ok "随机 Reality 端口: $REALITY_PORT"
    fi
    read -p "$(echo -e "${CYAN}服务器地址 (IP 或域名，用于 Reality 客户端链接):${NC} ")" SERVER_ADDR
    [[ -z $SERVER_ADDR ]] && error "服务器地址不能为空"
    read -p "$(echo -e "${CYAN}fallback SNI (目标网站域名，如 www.microsoft.com):${NC} ")" SERVER_NAME
    [[ -z $SERVER_NAME ]] && SERVER_NAME="www.microsoft.com"
    read -p "$(echo -e "${CYAN}目标地址 (target，格式 host:port，默认 ${SERVER_NAME}:443):${NC} ")" TARGET
    [[ -z $TARGET ]] && TARGET="${SERVER_NAME}:443"
    read -p "$(echo -e "${CYAN}Reality 节点名称 (默认 VLESS-Reality):${NC} ")" REALITY_REMARK
    [[ -z $REALITY_REMARK ]] && REALITY_REMARK="VLESS-Reality"

    # 生成通用 UUID (两个入站可以使用相同或不同UUID，这里使用相同UUID)
    UUID=$(cat /proc/sys/kernel/random/uuid)

    # 生成 Reality 密钥对和 shortId
    generate_reality_keypair
    SHORT_ID=$(openssl rand -hex 8)

    echo ""
    ok "配置信息汇总"
    echo "  WS 域名: $DOMAIN"
    echo "  WS 端口: $WS_PORT"
    echo "  WS 路径: $WSPATH"
    echo "  Reality 端口: $REALITY_PORT"
    echo "  Reality 服务器地址: $SERVER_ADDR"
    echo "  Reality fallback SNI: $SERVER_NAME"
    echo "  Reality 目标地址: $TARGET"
    echo "  Reality 公钥: $PUBLIC_KEY"
    echo "  Reality shortId: $SHORT_ID"
    echo "  公共 UUID: $UUID"
}

# 写入 config.json (包含两个 inbounds)
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
      "listen_port": $WS_PORT,
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
    },
    {
      "type": "vless",
      "tag": "VLESS-Reality-in",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SERVER_NAME",
        "reality": {
          "enabled": true,
          "target": "$TARGET",
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
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
    if [[ $INIT == "systemd" ]] && systemctl is-active --quiet sing-box; then
        ok "服务运行正常"
    elif [[ $INIT == "openrc" ]] && rc-service sing-box status | grep -q "started"; then
        ok "服务运行正常"
    else
        warn "服务可能未正常启动，请检查日志"
    fi
}

# 输出两个 VLESS 链接
output_links() {
    # WS 链接
    encoded_path=$(echo -n "$WSPATH" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g')
    local ws_link="vless://$UUID@$DOMAIN:$WS_PORT?encryption=none&security=none&type=ws&host=$DOMAIN&path=$encoded_path#$WS_REMARK"

    # Reality 链接
    local reality_link="vless://$UUID@$SERVER_ADDR:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SERVER_NAME&pbk=$PUBLIC_KEY&sid=$SHORT_ID&fp=chrome&type=tcp#$REALITY_REMARK"

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}         VLESS+WebSocket 链接            ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${CYAN}$ws_link${NC}"
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}         VLESS+Reality 链接             ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${CYAN}$reality_link${NC}"
    echo ""
    echo -e "${YELLOW}提示: 复制对应链接到客户端即可使用${NC}"
    echo -e "${YELLOW}提醒: Reality 私钥已保存在配置文件中，请勿泄露${NC}"
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
    get_config          # 同时获取两个入站的配置
    write_config        # 生成包含两个入站的 config.json
    create_service      # 启动服务
    output_links        # 输出两个链接
}

main "$@"
