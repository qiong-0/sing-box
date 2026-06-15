#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box_multi_install.sh
# 功能: 一键安装 sing-box，配置 VLESS+WS(无TLS) + Hysteria2(端口跳跃) + VLESS+Reality
# 环境: 兼容 systemd / OpenRC，自动适配包管理器
# 用法: bash sing-box_multi_install.sh
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

error() { echo -e "${RED}错误:${NC} $*" >&2; exit 1; }
warn()  { echo -e "${YELLOW}警告:${NC} $*"; }
info()  { echo -e "${CYAN}>>>${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }

# 全局变量
CORE_DIR="/etc/sing-box"
CONF_DIR="$CORE_DIR/conf"
LOG_DIR="/var/log/sing-box"
CORE_BIN="$CORE_DIR/bin/sing-box"
CONFIG_JSON="$CORE_DIR/config.json"

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
    ok "包管理器: $PKG_MANAGER"
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
    ok "依赖安装完成"
}

# 检测 init 系统 (兼容 LXC 轻量容器)
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
    info "请输入公共配置信息 (用于所有协议)"
    read -p "$(echo -e "${CYAN}域名 (必填):${NC} ")" DOMAIN
    [[ -z $DOMAIN ]] && error "域名不能为空"
    UUID=$(cat /proc/sys/kernel/random/uuid)

    # VLESS+WS 配置
    echo ""
    info "=== VLESS+WS (无 TLS) 配置 ==="
    read -p "$(echo -e "${CYAN}WS端口 (回车随机 10000-50000):${NC} ")" WS_PORT
    if [[ -z $WS_PORT ]]; then
        WS_PORT=$((RANDOM % 40001 + 10000))
        ok "随机 WS 端口: $WS_PORT"
    fi
    read -p "$(echo -e "${CYAN}WebSocket 路径 (默认 /):${NC} ")" WSPATH
    [[ -z $WSPATH ]] && WSPATH="/"
    read -p "$(echo -e "${CYAN}WS节点名称 (默认 VLESS-WS):${NC} ")" WS_REMARK
    [[ -z $WS_REMARK ]] && WS_REMARK="VLESS-WS"

    # Hysteria2 配置
    echo ""
    info "=== Hysteria2 配置 ==="
    read -p "$(echo -e "${CYAN}Hy2端口 (回车随机 10000-50000):${NC} ")" HY2_PORT
    if [[ -z $HY2_PORT ]]; then
        HY2_PORT=$((RANDOM % 40001 + 10000))
        ok "随机 Hy2 端口: $HY2_PORT"
    fi
    read -p "$(echo -e "${CYAN}跳跃端口范围 (如 20000-30000, 可选):${NC} ")" HY2_HOPPING
    read -p "$(echo -e "${CYAN}Hy2密码 (回车自动生成 UUID):${NC} ")" HY2_PASS
    if [[ -z $HY2_PASS ]]; then
        HY2_PASS=$(cat /proc/sys/kernel/random/uuid)
        ok "自动生成密码: $HY2_PASS"
    fi
    read -p "$(echo -e "${CYAN}Hy2节点名称 (默认 Hysteria2):${NC} ")" HY2_REMARK
    [[ -z $HY2_REMARK ]] && HY2_REMARK="Hysteria2"

    # VLESS+Reality 配置
    echo ""
    info "=== VLESS+Reality 配置 ==="
    read -p "$(echo -e "${CYAN}Reality端口 (回车随机 10000-50000):${NC} ")" REALITY_PORT
    if [[ -z $REALITY_PORT ]]; then
        REALITY_PORT=$((RANDOM % 40001 + 10000))
        ok "随机 Reality 端口: $REALITY_PORT"
    fi
    read -p "$(echo -e "${CYAN}SNI (例如 www.google.com):${NC} ")" REALITY_SNI
    [[ -z $REALITY_SNI ]] && REALITY_SNI="www.google.com"
    # 生成 Reality 密钥对
    local keypair=$($CORE_BIN generate reality-keypair)
    REALITY_PRIVATE_KEY=$(echo "$keypair" | grep "PrivateKey:" | awk '{print $2}')
    REALITY_PUBLIC_KEY=$(echo "$keypair" | grep "PublicKey:" | awk '{print $2}')
    [[ -z $REALITY_PRIVATE_KEY ]] && error "生成 Reality 密钥失败"
    REALITY_SHORT_ID=$($CORE_BIN generate rand --base64 8)
    read -p "$(echo -e "${CYAN}Reality节点名称 (默认 VLESS-Reality):${NC} ")" REALITY_REMARK
    [[ -z $REALITY_REMARK ]] && REALITY_REMARK="VLESS-Reality"

    echo ""
    ok "所有配置信息"
    echo "  域名: $DOMAIN"
    echo "  UUID: $UUID"
    echo "  WS端口: $WS_PORT"
    echo "  WS路径: $WSPATH"
    echo "  Hy2端口: $HY2_PORT"
    echo "  Hy2跳跃: ${HY2_HOPPING:-未启用}"
    echo "  Reality端口: $REALITY_PORT"
    echo "  Reality SNI: $REALITY_SNI"
}

# 生成 config.json
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
      "type": "hysteria2",
      "tag": "HY2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "password": "$HY2_PASS"
        }
      ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "certificate_path": "disable",
        "key_path": "disable"
      }
EOF
    if [[ -n $HY2_HOPPING ]]; then
        cat >> "$CONFIG_JSON" <<EOF
      ,
      "port_hopping": {
        "hop_interval": "30s",
        "ports": "$HY2_HOPPING"
      }
EOF
    fi
    cat >> "$CONFIG_JSON" <<EOF
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
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
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

# 生成链接
output_links() {
    # VLESS+WS 链接
    encoded_path=$(echo -n "$WSPATH" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g')
    local vless_ws_link="vless://$UUID@$DOMAIN:$WS_PORT?encryption=none&security=none&type=ws&host=$DOMAIN&path=$encoded_path#$WS_REMARK"

    # Hysteria2 链接 (hy2:// 格式)
    local hy2_link="hy2://$HY2_PASS@$DOMAIN:$HY2_PORT?auth=$HY2_PASS&insecure=1#$HY2_REMARK"

    # VLESS+Reality 链接
    local vless_reality_link="vless://$UUID@$DOMAIN:$REALITY_PORT?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=$REALITY_SNI&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID#$REALITY_REMARK"

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}           协议分享链接               ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${CYAN}[1] VLESS+WS 链接:${NC}"
    echo -e "$vless_ws_link"
    echo ""
    echo -e "${CYAN}[2] Hysteria2 链接:${NC}"
    echo -e "$hy2_link"
    echo ""
    echo -e "${CYAN}[3] VLESS+Reality 链接:${NC}"
    echo -e "$vless_reality_link"
    echo ""
    echo -e "${YELLOW}提示: 复制上述链接到客户端即可使用${NC}"
}

# 主流程
main() {
    # 检查 root
    [[ $EUID -ne 0 ]] && error "请以 root 用户执行（使用 sudo -i）"

    detect_pkg_manager
    install_deps
    get_arch
    detect_init
    install_singbox
    get_config
    write_config
    create_service
    output_links
}

main "$@"
