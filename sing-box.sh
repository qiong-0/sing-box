#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box-vless-dual.sh
# 功能: 一键安装 sing-box，配置 VLESS Reality + VLESS WebSocket 双入站
# 环境: 兼容 systemd / OpenRC，自动适配包管理器
# 用法: bash sing-box-vless-dual.sh
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

# ================= 检测环境 =================

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

install_deps() {
    local deps="wget tar curl"
    case $PKG_MANAGER in
        apk)
            $INSTALL_CMD $deps bash gcompat   # gcompat 解决 glibc 兼容性
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

# ================= 安装 sing-box =================

install_singbox() {
    if command -v sing-box &>/dev/null; then
        ok "sing-box 已安装: $(sing-box version | head -n1)"
        return
    fi

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
    ln -sf "$CORE_BIN" /usr/local/bin/sing-box
    ok "sing-box 安装完成: $(sing-box version | head -n1)"
}

# ================= 生成 Reality 密钥 =================

generate_reality_keys() {
    # sing-box 的 x25519 密钥生成
    local key_output
    key_output=$(sing-box generate x25519 2>/dev/null)
    if [[ -z "$key_output" ]]; then
        # 降级尝试：使用 xray 如果有
        if command -v xray &>/dev/null; then
            key_output=$(xray x25519 2>/dev/null)
        else
            warn "无法生成 x25519 密钥，尝试在线生成..."
            key_output=$(curl -s https://api.xray.plus/x25519 2>/dev/null || echo "")
        fi
    fi
    PRIVATE_KEY=$(echo "$key_output" | grep -i 'private' | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$key_output" | grep -i 'public' | awk '{print $NF}')
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "Reality 密钥生成失败"
    fi
    ok "Reality 密钥对已生成"
}

# ================= 交互式配置收集 =================

collect_config() {
    echo ""
    echo "========== 配置 VLESS Reality 入站 =========="
    read -p "监听端口 [443]: " REALITY_PORT
    REALITY_PORT=${REALITY_PORT:-443}
    read -p "dest (目标网站) [www.cloudflare.com:443]: " DEST
    DEST=${DEST:-www.cloudflare.com:443}
    read -p "serverNames (逗号分隔) [www.cloudflare.com]: " SERVER_NAMES_RAW
    SERVER_NAMES_RAW=${SERVER_NAMES_RAW:-www.cloudflare.com}
    # 取第一个作为 sni
    SERVER_NAME_FIRST=$(echo "$SERVER_NAMES_RAW" | cut -d',' -f1)

    echo ""
    echo "========== 配置 VLESS WebSocket 入站 =========="
    read -p "监听端口 (留空随机 10000-50000): " WS_PORT
    if [[ -z "$WS_PORT" ]]; then
        WS_PORT=$((RANDOM % 40001 + 10000))
        ok "随机端口: $WS_PORT"
    fi
    read -p "WebSocket 路径 (默认 /): " WSPATH
    WSPATH=${WSPATH:-/}
    read -p "伪装域名 (必填): " WS_DOMAIN
    [[ -z "$WS_DOMAIN" ]] && error "伪装域名不能为空"
    read -p "节点备注 [VLESS-WS]: " REMARK
    REMARK=${REMARK:-VLESS-WS}

    # 生成两个入站的 UUID
    UUID_REALITY=$(sing-box generate uuid)
    UUID_WS=$(sing-box generate uuid)
    ok "UUID (Reality): $UUID_REALITY"
    ok "UUID (WS): $UUID_WS"
}

# ================= 生成 config.json =================

write_config() {
    # 构建 serverNames JSON 数组
    IFS=',' read -ra SN_ARRAY <<< "$SERVER_NAMES_RAW"
    local server_names_json="["
    for sn in "${SN_ARRAY[@]}"; do
        server_names_json+="\"$sn\","
    done
    server_names_json="${server_names_json%,}]"

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
      "tag": "VLESS-Reality-in",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "uuid": "$UUID_REALITY",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SERVER_NAME_FIRST",
        "reality": {
          "enabled": true,
          "dest": "$DEST",
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            ""
          ]
        }
      }
    },
    {
      "type": "vless",
      "tag": "VLESS-WS-in",
      "listen": "::",
      "listen_port": $WS_PORT,
      "users": [
        {
          "uuid": "$UUID_WS",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$WSPATH",
        "headers": {
          "Host": "$WS_DOMAIN"
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

# ================= 服务管理 =================

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
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl restart sing-box
        ok "systemd 服务已启动"
    else  # openrc
        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="$CORE_BIN"
command_args="run -c $CONFIG_JSON"
command_user="root"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        rc-service sing-box restart
        ok "OpenRC 服务已启动"
    fi

    sleep 2
    # 检查服务状态
    if [[ $INIT == "systemd" ]] && systemctl is-active --quiet sing-box; then
        ok "服务运行正常"
    elif [[ $INIT == "openrc" ]] && rc-service sing-box status | grep -q "started"; then
        ok "服务运行正常"
    else
        warn "服务可能未正常启动，请检查日志: $LOG_DIR/access.log"
    fi
}

# ================= 输出节点链接 =================

get_public_ip() {
    IPV4=$(curl -4 -s --max-time 3 https://api.ipify.org || true)
    IPV6=$(curl -6 -s --max-time 3 https://api64.ipify.org || true)
}

output_links() {
    get_public_ip

    # Reality 链接
    if [[ -n "$IPV4" ]]; then
        REALITY_V4="vless://${UUID_REALITY}@${IPV4}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME_FIRST}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#VLESS-Reality-IPv4"
        echo ""
        echo -e "${GREEN}========== VLESS Reality 节点 (IPv4) ==========${NC}"
        echo "$REALITY_V4"
    fi
    if [[ -n "$IPV6" ]]; then
        REALITY_V6="vless://${UUID_REALITY}@[${IPV6}]:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME_FIRST}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#VLESS-Reality-IPv6"
        echo ""
        echo -e "${GREEN}========== VLESS Reality 节点 (IPv6) ==========${NC}"
        echo "$REALITY_V6"
    fi

    # WebSocket 链接
    encoded_path=$(echo -n "$WSPATH" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g')
    if [[ -n "$IPV4" ]]; then
        WS_V4="vless://${UUID_WS}@${IPV4}:${WS_PORT}?encryption=none&security=none&type=ws&host=${WS_DOMAIN}&path=${encoded_path}#${REMARK}-IPv4"
        echo ""
        echo -e "${GREEN}========== VLESS WebSocket 节点 (IPv4) ==========${NC}"
        echo "$WS_V4"
    fi
    if [[ -n "$IPV6" ]]; then
        WS_V6="vless://${UUID_WS}@[${IPV6}]:${WS_PORT}?encryption=none&security=none&type=ws&host=${WS_DOMAIN}&path=${encoded_path}#${REMARK}-IPv6"
        echo ""
        echo -e "${GREEN}========== VLESS WebSocket 节点 (IPv6) ==========${NC}"
        echo "$WS_V6"
    fi

    # 保存元信息供后续菜单使用
    cat > "$META_FILE" <<EOF
REALITY_PORT="$REALITY_PORT"
REALITY_UUID="$UUID_REALITY"
REALITY_PUBKEY="$PUBLIC_KEY"
REALITY_SNI="$SERVER_NAME_FIRST"
WS_PORT="$WS_PORT"
WS_UUID="$UUID_WS"
WS_PATH="$WSPATH"
WS_HOST="$WS_DOMAIN"
WS_REMARK="$REMARK"
INSTALL_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
}

# ================= 管理菜单功能 =================

show_config() {
    if [[ ! -f "$META_FILE" ]]; then
        warn "未找到配置文件，请先安装"
        return
    fi
    source "$META_FILE"
    echo ""
    echo "========== 当前双入站配置 =========="
    echo "安装时间: $INSTALL_TIME"
    echo "--- Reality 入站 ---"
    echo "端口: $REALITY_PORT"
    echo "UUID: $REALITY_UUID"
    echo "PublicKey: $REALITY_PUBKEY"
    echo "SNI: $REALITY_SNI"
    echo "--- WebSocket 入站 ---"
    echo "端口: $WS_PORT"
    echo "UUID: $WS_UUID"
    echo "路径: $WS_PATH"
    echo "伪装域名: $WS_HOST"
    echo "备注: $WS_REMARK"
    echo
    output_links
}

restart_service() {
    if [[ $INIT == "systemd" ]]; then
        systemctl restart sing-box
        ok "服务已重启"
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box restart
        ok "服务已重启"
    fi
}

stop_service() {
    if [[ $INIT == "systemd" ]]; then
        systemctl stop sing-box
        ok "服务已停止"
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box stop
        ok "服务已停止"
    fi
}

uninstall() {
    read -p "⚠️ 将彻底删除 sing-box 与所有配置，是否继续？(y/N): " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && return

    stop_service
    if [[ $INIT == "systemd" ]]; then
        systemctl disable sing-box
        rm -f /lib/systemd/system/sing-box.service
        systemctl daemon-reload
    else
        rc-update del sing-box
        rm -f /etc/init.d/sing-box
    fi

    rm -rf "$CORE_DIR" "$LOG_DIR"
    rm -f /usr/local/bin/sing-box
    rm -f "$META_FILE"
    ok "已彻底卸载 sing-box 双入站配置"
}

self_update() {
    local script_path=$(realpath "$0")
    curl -fsSL "https://raw.githubusercontent.com/jinqians/sing-box-vless-dual/main/sing-box-vless-dual.sh" -o "$script_path" 2>/dev/null && chmod +x "$script_path" && exec "$script_path" || error "更新失败，请检查网络"
}

# ================= 主菜单 =================

main_menu() {
    while true; do
        echo ""
        echo "============================================"
        echo "   sing-box 双入站管理 (VLESS Reality + WS)"
        echo "============================================"
        echo "1) 安装/重新安装 双入站"
        echo "2) 查看当前配置与节点链接"
        echo "3) 重启服务"
        echo "4) 停止服务"
        echo "5) 卸载"
        echo "6) 更新脚本"
        echo "0) 退出"
        read -p "请选择: " choice
        case $choice in
            1) install_dual ;;
            2) show_config ;;
            3) restart_service ;;
            4) stop_service ;;
            5) uninstall ;;
            6) self_update ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
    done
}

# ================= 主安装流程 =================

install_dual() {
    # 全局变量
    CORE_DIR="/etc/sing-box"
    CONF_DIR="$CORE_DIR/conf"
    LOG_DIR="/var/log/sing-box"
    CORE_BIN="$CORE_DIR/bin/sing-box"
    CONFIG_JSON="$CORE_DIR/config.json"
    META_FILE="$CORE_DIR/dual-meta.conf"

    detect_pkg_manager
    install_deps
    get_arch
    detect_init
    install_singbox
    generate_reality_keys
    collect_config
    write_config
    create_service
    output_links

    echo ""
    ok "双入站安装完成！"
    echo "管理命令: 再次运行此脚本即可进入菜单"
    echo "配置文件: $CONFIG_JSON"
}

# 入口
if [[ "$1" == "install" ]] || [[ ! -f "/etc/sing-box/dual-meta.conf" ]]; then
    install_dual
else
    main_menu
fi
