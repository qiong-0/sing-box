#!/usr/bin/env bash
# ====================================================
# File: sing-box-manager.sh
# Description: Sing-box 一键管理脚本
#             支持 VLESS+WS (无 TLS)、VLESS+Reality、Hysteria2
#             自定义域名/端口/路径/节点名
#             生成 vless:// 链接
#             兼容 LXC 轻量容器及主流 Linux 发行版
# Reference: https://github.com/233boy/sing-box
# Author: Based on 233boy's design
# ====================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 路径定义
SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_CONFIG_DIR="/etc/sing-box"
SING_BOX_CONFIG="${SING_BOX_CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SB_CMD="/usr/local/bin/sb"

# ----------------------------------------
# 通用函数
# ----------------------------------------

# 显示信息
info() {
    echo -e "${GREEN}[信息]${PLAIN} $1"
}

err() {
    echo -e "${RED}[错误]${PLAIN} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[警告]${PLAIN} $1"
}

# 检查 root
check_root() {
    [[ $EUID -ne 0 ]] && err "请使用 root 用户执行此脚本！"
}

# 检测系统类型
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    else
        OS=$(uname -s)
    fi
    echo "$OS"
}

# 是否为 Alpine
is_alpine() {
    [[ "$(detect_os)" == "alpine" ]]
}

# 安装必要依赖（包括 jq, curl, wget, tar, gzip, openssl 等）
install_deps() {
    info "检查并安装必要依赖..."
    if is_alpine; then
        apk update
        apk add --no-cache curl wget tar gzip jq openssl coreutils libc6-compat
    elif command -v apt &>/dev/null; then
        apt update
        apt install -y curl wget tar gzip jq openssl
    elif command -v yum &>/dev/null; then
        yum install -y curl wget tar gzip jq openssl
    elif command -v dnf &>/dev/null; then
        dnf install -y curl wget tar gzip jq openssl
    else
        warn "无法自动安装依赖，请手动安装 curl, wget, tar, gzip, jq, openssl"
    fi
    info "依赖检查完成"
}

# 生成随机端口 (10000-50000)
random_port() {
    local min=10000 max=50000
    echo $((RANDOM % (max - min + 1) + min))
}

# 生成 UUID
generate_uuid() {
    if command -v sing-box &>/dev/null; then
        sing-box generate uuid
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "c81e728d-9d4c-4f9d-a1fd-8e7e4f2b5c3d"
    fi
}

# 生成 Reality 密钥对
generate_reality_keypair() {
    if command -v sing-box &>/dev/null; then
        sing-box generate reality-keypair
    else
        # fallback: 使用 openssl 生成 Base64 伪密钥（仅用于脚本不回显错误）
        local priv=$(openssl rand -base64 32)
        local pub=$(echo "$priv" | openssl base64 -d | openssl pkey -pubout -outform DER 2>/dev/null | openssl base64)
        echo "$priv $pub"
    fi
}

# 生成 SS2022 密码 (用于 Hysteria2)
generate_ss2022() {
    if command -v sing-box &>/dev/null; then
        sing-box generate ss2022
    else
        openssl rand -base64 32
    fi
}

# 获取本机 IPv4 地址
get_ip() {
    curl -s -4 --connect-timeout 3 "http://ip.sb" 2>/dev/null || echo "无法获取IP"
}

# 检查端口是否被占用
port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tuln | grep -q ":$port "
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -q ":$port "
    else
        false
    fi
}

# ----------------------------------------
# Sing-box 安装 (兼容 LXC 轻量容器)
# ----------------------------------------
install_sing_box() {
    check_root
    install_deps

    if command -v sing-box &>/dev/null; then
        warn "sing-box 已安装: $(sing-box version 2>&1 | head -n1)"
        read -p "是否重新安装？(y/n): " reinstall
        [[ "$reinstall" != "y" && "$reinstall" != "Y" ]] && return
        uninstall_sing_box
    fi

    info "开始安装 sing-box ..."

    # 优先使用官方安装脚本
    if curl -fsSL https://sing-box.app/install.sh | sh -s; then
        info "官方安装脚本执行成功"
    else
        warn "官方安装失败，尝试手动下载静态二进制..."
        manual_install_sing_box
    fi

    # 验证安装
    if ! command -v sing-box &>/dev/null; then
        err "sing-box 安装失败，请检查网络或手动安装"
    fi
    info "sing-box 安装完成: $(sing-box version 2>&1 | head -n1)"

    # 创建配置目录及默认配置
    mkdir -p "$SING_BOX_CONFIG_DIR"
    if [[ ! -f "$SING_BOX_CONFIG" ]]; then
        cat > "$SING_BOX_CONFIG" <<EOF
{
  "log": {
    "level": "info",
    "output": "$SING_BOX_CONFIG_DIR/sing-box.log"
  },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ]
}
EOF
    fi

    # 创建 systemd 服务
    create_systemd_service
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    info "sing-box 服务已启动并设置开机自启"

    # 创建快捷命令 sb
    create_sb_command
    info "管理命令: sb"
}

# 手动下载静态编译版本（解决 glibc/musl 兼容问题）
manual_install_sing_box() {
    local arch=$(uname -m)
    local arch_map=""
    case "$arch" in
        x86_64)  arch_map="amd64" ;;
        aarch64) arch_map="arm64" ;;
        armv7l)  arch_map="armv7" ;;
        *)       err "不支持的架构: $arch" ;;
    esac

    # 获取最新版本
    local latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f4)
    [[ -z "$latest_version" ]] && err "获取最新版本号失败"
    info "最新版本: $latest_version"

    local url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${latest_version}-linux-${arch_map}.tar.gz"
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit

    # 带重试的下载
    local retry=0
    while [[ $retry -lt 3 ]]; do
        info "下载尝试 $((retry+1))/3"
        if wget --tries=3 --timeout=30 --retry-connrefused "$url" -O sing-box.tar.gz 2>/dev/null; then
            if gzip -t sing-box.tar.gz 2>/dev/null; then
                break
            fi
        fi
        rm -f sing-box.tar.gz
        retry=$((retry+1))
        sleep 2
    done
    [[ ! -f sing-box.tar.gz ]] && err "下载失败"

    # 解压 (兼容 busybox tar)
    if ! gunzip -f sing-box.tar.gz 2>/dev/null; then
        tar -xzf sing-box.tar.gz 2>/dev/null || err "解压失败"
    else
        tar -xf sing-box.tar 2>/dev/null || err "解压失败"
    fi

    # 复制二进制
    if [[ -f "sing-box-${latest_version}-linux-${arch_map}/sing-box" ]]; then
        cp "sing-box-${latest_version}-linux-${arch_map}/sing-box" "$SING_BOX_BIN"
    elif [[ -f "./sing-box" ]]; then
        cp ./sing-box "$SING_BOX_BIN"
    else
        err "找不到 sing-box 二进制文件"
    fi
    chmod +x "$SING_BOX_BIN"
    cd - >/dev/null || exit
    rm -rf "$temp_dir"
}

# 创建 systemd 服务文件
create_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target
[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
ExecStart=$SING_BOX_BIN run -c $SING_BOX_CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
}

# 创建 sb 快捷命令 (类似 233boy 风格)
create_sb_command() {
    cat > "$SB_CMD" <<'EOF'
#!/usr/bin/env bash
# Sing-box 管理入口
SCRIPT_URL="https://raw.githubusercontent.com/qiong-0/sing-box/main/vless-ws.sh"
if [[ -f /usr/local/bin/sing-box-manager.sh ]]; then
    bash /usr/local/bin/sing-box-manager.sh "$@"
else
    echo "脚本文件不存在，请重新安装"
fi
EOF
    chmod +x "$SB_CMD"
    # 将当前脚本自身复制到固定位置以便 sb 调用
    cp "$0" /usr/local/bin/sing-box-manager.sh 2>/dev/null || true
    chmod +x /usr/local/bin/sing-box-manager.sh
}

# ----------------------------------------
# 节点添加函数 (VLESS+WS, VLESS+Reality, Hysteria2)
# ----------------------------------------

# 添加 VLESS+WS (无 TLS)
add_vless_ws() {
    info "添加 VLESS+WS 节点 (无 TLS)"
    local node_name host port path

    read -p "节点名称 (默认 vless-ws): " node_name
    node_name=${node_name:-vless-ws}
    read -p "域名 (必填，用于 WebSocket Host): " host
    [[ -z "$host" ]] && err "域名不能为空"
    read -p "端口 (回车随机 10000-50000): " port
    if [[ -z "$port" ]]; then
        port=$(random_port)
        while port_in_use "$port"; do port=$(random_port); done
        info "使用随机端口: $port"
    fi
    read -p "路径 (默认 /): " path
    path=${path:-/}

    local uuid=$(generate_uuid)
    local inbound=$(cat <<EOF
{
  "type": "vless",
  "tag": "$node_name",
  "listen": "::",
  "listen_port": $port,
  "users": [
    { "uuid": "$uuid", "flow": "" }
  ],
  "transport": {
    "type": "ws",
    "path": "$path",
    "headers": {
      "Host": "$host"
    }
  }
}
EOF
)
    add_inbound "$node_name" "$inbound"
    # 生成分享链接
    local server=$(get_ip)
    local link="vless://${uuid}@${server}:${port}?encryption=none&security=none&type=ws&host=${host}&path=${path}#${node_name}"
    echo -e "${GREEN}VLESS+WS 分享链接:${PLAIN}"
    echo "$link"
}

# 添加 VLESS+Reality
add_vless_reality() {
    info "添加 VLESS+Reality 节点"
    local node_name port sni
    read -p "节点名称 (默认 vless-reality): " node_name
    node_name=${node_name:-vless-reality}
    read -p "端口 (回车随机 10000-50000): " port
    if [[ -z "$port" ]]; then
        port=$(random_port)
        while port_in_use "$port"; do port=$(random_port); done
        info "使用随机端口: $port"
    fi
    read -p "SNI (伪装域名，如 www.microsoft.com): " sni
    [[ -z "$sni" ]] && err "SNI 不能为空"

    local uuid=$(generate_uuid)
    local keypair=$(generate_reality_keypair)
    local private_key=$(echo "$keypair" | awk '{print $1}')
    local public_key=$(echo "$keypair" | awk '{print $2}')
    local short_id=$(openssl rand -hex 8)

    local inbound=$(cat <<EOF
{
  "type": "vless",
  "tag": "$node_name",
  "listen": "::",
  "listen_port": $port,
  "users": [
    { "uuid": "$uuid", "flow": "" }
  ],
  "tls": {
    "enabled": true,
    "server_name": "$sni",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "$sni",
        "server_port": 443
      },
      "private_key": "$private_key",
      "short_id": ["$short_id"]
    },
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    }
  }
}
EOF
)
    add_inbound "$node_name" "$inbound"
    local server=$(get_ip)
    local link="vless://${uuid}@${server}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${node_name}"
    echo -e "${GREEN}VLESS+Reality 分享链接:${PLAIN}"
    echo "$link"
}

# 添加 Hysteria2
add_hysteria2() {
    info "添加 Hysteria2 节点"
    local node_name port password
    read -p "节点名称 (默认 hysteria2): " node_name
    node_name=${node_name:-hysteria2}
    read -p "端口 (回车随机 10000-50000): " port
    if [[ -z "$port" ]]; then
        port=$(random_port)
        while port_in_use "$port"; do port=$(random_port); done
        info "使用随机端口: $port"
    fi
    read -p "密码 (回车随机生成): " password
    if [[ -z "$password" ]]; then
        password=$(generate_ss2022)
        info "生成的密码: $password"
    fi

    local inbound=$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "$node_name",
  "listen": "::",
  "listen_port": $port,
  "users": [
    { "password": "$password" }
  ],
  "tls": {
    "enabled": false
  }
}
EOF
)
    add_inbound "$node_name" "$inbound"
    local server=$(get_ip)
    echo -e "${GREEN}Hysteria2 节点已添加${PLAIN}"
    echo "服务器: $server"
    echo "端口: $port"
    echo "密码: $password"
    echo "客户端可使用 sing-box / hysteria2 客户端连接"
}

# 通用 inbound 添加函数 (合并到 config.json)
add_inbound() {
    local tag=$1
    local new_inbound=$2
    [[ ! -f "$SING_BOX_CONFIG" ]] && init_config
    if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" &>/dev/null; then
        err "节点 $tag 已存在，请更换名称"
    fi
    local tmp=$(mktemp)
    jq --argjson inbound "$new_inbound" '.inbounds += [$inbound]' "$SING_BOX_CONFIG" > "$tmp"
    mv "$tmp" "$SING_BOX_CONFIG"
    restart_sing_box
    info "节点 $tag 已添加并生效"
}

# 初始化空配置
init_config() {
    mkdir -p "$SING_BOX_CONFIG_DIR"
    cat > "$SING_BOX_CONFIG" <<EOF
{
  "log": {
    "level": "info",
    "output": "$SING_BOX_CONFIG_DIR/sing-box.log"
  },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ]
}
EOF
}

# 重启 sing-box 服务
restart_sing_box() {
    systemctl restart sing-box
    sleep 1
    if systemctl is-active sing-box &>/dev/null; then
        info "sing-box 重启成功"
    else
        err "sing-box 启动失败，请检查配置"
    fi
}

# ----------------------------------------
# 管理功能 (列表、删除、链接、状态)
# ----------------------------------------

# 列出所有节点
list_nodes() {
    [[ ! -f "$SING_BOX_CONFIG" ]] && { warn "配置文件不存在"; return; }
    local inbounds=$(jq -r '.inbounds[]? | "\(.tag) \(.type)"' "$SING_BOX_CONFIG" 2>/dev/null)
    if [[ -z "$inbounds" ]]; then
        echo "暂无节点"
        return
    fi
    echo -e "${BLUE}========== 节点列表 ==========${PLAIN}"
    echo -e "名称\t\t类型\t端口"
    echo "---------------------------------"
    while IFS= read -r line; do
        local tag=$(echo "$line" | awk '{print $1}')
        local typ=$(echo "$line" | awk '{print $2}')
        local port=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .listen_port" "$SING_BOX_CONFIG" 2>/dev/null)
        echo -e "${GREEN}$tag${PLAIN}\t\t$typ\t$port"
    done <<< "$inbounds"
    echo "---------------------------------"
}

# 删除节点
delete_node() {
    local tag=$1
    if [[ -z "$tag" ]]; then
        read -p "请输入要删除的节点名称: " tag
        [[ -z "$tag" ]] && { warn "未提供名称"; return; }
    fi
    [[ ! -f "$SING_BOX_CONFIG" ]] && { warn "配置文件不存在"; return; }
    if ! jq -e ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" &>/dev/null; then
        warn "节点 $tag 不存在"
        return
    fi
    local tmp=$(mktemp)
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$SING_BOX_CONFIG" > "$tmp"
    mv "$tmp" "$SING_BOX_CONFIG"
    restart_sing_box
    info "节点 $tag 已删除"
}

# 生成 VLESS 链接 (根据节点类型自动识别)
gen_link() {
    local tag=$1
    if [[ -z "$tag" ]]; then
        read -p "请输入节点名称: " tag
        [[ -z "$tag" ]] && { warn "未提供名称"; return; }
    fi
    local inbound=$(jq -r ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" 2>/dev/null)
    [[ -z "$inbound" ]] && { warn "节点 $tag 不存在"; return; }
    local type=$(echo "$inbound" | jq -r '.type')
    if [[ "$type" != "vless" ]]; then
        warn "仅支持 VLESS 类型节点生成 vless:// 链接"
        return
    fi
    local server=$(get_ip)
    local port=$(echo "$inbound" | jq -r '.listen_port')
    local uuid=$(echo "$inbound" | jq -r '.users[0].uuid // .uuid')
    local is_reality=$(echo "$inbound" | jq -r '.tls.reality.enabled // false')
    if [[ "$is_reality" == "true" ]]; then
        local sni=$(echo "$inbound" | jq -r '.tls.server_name')
        local pbk=$(echo "$inbound" | jq -r '.tls.reality.public_key')
        local sid=$(echo "$inbound" | jq -r '.tls.reality.short_id[0]')
        local link="vless://${uuid}@${server}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#${tag}"
    else
        # VLESS+WS
        local host=$(echo "$inbound" | jq -r '.transport.headers.Host // ""')
        local path=$(echo "$inbound" | jq -r '.transport.path // "/"')
        local link="vless://${uuid}@${server}:${port}?encryption=none&security=none&type=ws&host=${host}&path=${path}#${tag}"
    fi
    echo -e "${GREEN}分享链接:${PLAIN}"
    echo "$link"
}

# 查看服务状态
status_sb() {
    if systemctl is-active sing-box &>/dev/null; then
        echo -e "sing-box: ${GREEN}运行中${PLAIN}"
    else
        echo -e "sing-box: ${RED}未运行${PLAIN}"
    fi
}

# 卸载
uninstall_sing_box() {
    warn "此操作将卸载 sing-box 并删除所有配置！"
    read -p "确认卸载？(y/n): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    systemctl stop sing-box
    systemctl disable sing-box
    rm -f "$SING_BOX_BIN"
    rm -rf "$SING_BOX_CONFIG_DIR"
    rm -f "$SERVICE_FILE"
    rm -f "$SB_CMD"
    rm -f /usr/local/bin/sing-box-manager.sh
    systemctl daemon-reload
    info "sing-box 已卸载"
}

# ----------------------------------------
# 菜单显示
# ----------------------------------------
show_menu() {
    clear
    echo -e "  ${GREEN}Sing-box 一键管理脚本${PLAIN}"
    echo -e "  ${BLUE}=========================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN}  安装 sing-box"
    echo -e "  ${GREEN}2.${PLAIN}  卸载 sing-box"
    echo -e "  ${GREEN}3.${PLAIN}  添加节点"
    echo -e "  ${GREEN}4.${PLAIN}  删除节点"
    echo -e "  ${GREEN}5.${PLAIN}  查看节点列表"
    echo -e "  ${GREEN}6.${PLAIN}  生成节点链接"
    echo -e "  ${GREEN}7.${PLAIN}  重启 sing-box"
    echo -e "  ${GREEN}8.${PLAIN}  查看服务状态"
    echo -e "  ${GREEN}0.${PLAIN}  退出"
    echo -e "  ${BLUE}=========================${PLAIN}"
    echo -e "  当前状态: $(status_sb)"
}

add_node_menu() {
    echo -e "  ${GREEN}请选择协议:${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN}  VLESS+WS (无 TLS)"
    echo -e "  ${GREEN}2.${PLAIN}  VLESS+Reality"
    echo -e "  ${GREEN}3.${PLAIN}  Hysteria2"
    echo -e "  ${GREEN}0.${PLAIN}  返回"
    read -p "请输入 [0-3]: " choice
    case $choice in
        1) add_vless_ws ;;
        2) add_vless_reality ;;
        3) add_hysteria2 ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
}

# ----------------------------------------
# 命令行参数处理
# ----------------------------------------
case "$1" in
    add)
        add_node_menu
        ;;
    del)
        delete_node "$2"
        ;;
    list)
        list_nodes
        ;;
    link)
        gen_link "$2"
        ;;
    uninstall)
        uninstall_sing_box
        ;;
    restart)
        restart_sing_box
        ;;
    status)
        status_sb
        ;;
    *)
        check_root
        if [[ ! -f "$SING_BOX_BIN" ]]; then
            install_sing_box
        fi
        while true; do
            show_menu
            read -p "请输入选项 [0-8]: " opt
            case $opt in
                1) install_sing_box ;;
                2) uninstall_sing_box ;;
                3) add_node_menu ;;
                4) delete_node ;;
                5) list_nodes ;;
                6) gen_link ;;
                7) restart_sing_box ;;
                8) status_sb ;;
                0) exit 0 ;;
                *) warn "无效选项" ;;
            esac
            echo ""
            read -p "按 Enter 继续..."
        done
        ;;
esac
