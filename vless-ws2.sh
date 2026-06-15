#!/usr/bin/env bash

# ----------------------------------------
# Sing-box 一键管理脚本
# 作者: OpenAI
# 描述: 支持 VLESS+WS, VLESS+Reality, Hysteria2 协议的一键安装与管理
# 系统兼容: Ubuntu, Debian, CentOS, Alpine, LXC等轻量容器
# 项目参考: https://github.com/233boy/sing-box
# ----------------------------------------

# 脚本名称和路径
SCRIPT_NAME=$(basename "$0")
SING_BOX_CONFIG_DIR="/etc/sing-box"
SING_BOX_CONFIG="${SING_BOX_CONFIG_DIR}/config.json"
SING_BOX_BIN="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# ----------------------------------------
# 通用函数
# ----------------------------------------

# 显示红色信息
err() {
    echo -e "${RED}[错误]${PLAIN} $1" >&2
}

# 显示绿色信息
info() {
    echo -e "${GREEN}[信息]${PLAIN} $1"
}

# 显示黄色信息
warn() {
    echo -e "${YELLOW}[警告]${PLAIN} $1"
}

# 获取本机IP地址
get_ip() {
    local ipv4=$(curl -s -4 --connect-timeout 2 "http://ip.sb" 2>/dev/null)
    if [[ -n "$ipv4" ]]; then
        echo "$ipv4"
    else
        echo "无法获取IPv4地址"
    fi
}

# 生成随机端口（10000-50000）
generate_random_port() {
    local min_port=10000
    local max_port=50000
    local range=$((max_port - min_port + 1))
    local rand_port=$((RANDOM % range + min_port))
    while is_port_in_use "$rand_port"; do
        rand_port=$((RANDOM % range + min_port))
    done
    echo "$rand_port"
}

# 检查端口是否被占用
is_port_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -q ":$port "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep -q ":$port "
    else
        # 如果都没有，尝试用nc或telnet检测
        if command -v nc >/dev/null 2>&1; then
            nc -z 127.0.0.1 "$port" 2>/dev/null
        else
            false
        fi
    fi
}

# 生成随机UUID
generate_uuid() {
    if command -v sing-box >/dev/null 2>&1; then
        sing-box generate uuid
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "c81e728d-9d4c-4f9d-a1fd-8e7e4f2b5c3d"
    fi
}

# 生成Reality密钥对
generate_reality_keypair() {
    if command -v sing-box >/dev/null 2>&1; then
        sing-box generate reality-keypair
    else
        # 本地生成base64编码的密钥（简单fallback）
        local private_key=$(openssl rand -base64 32)
        local public_key=$(echo "$private_key" | openssl base64 -d | openssl pkey -pubout -outform DER 2>/dev/null | openssl base64)
        echo "${private_key} ${public_key}"
    fi
}

# 生成SS2022密码
generate_ss2022_password() {
    if command -v sing-box >/dev/null 2>&1; then
        sing-box generate ss2022
    else
        openssl rand -base64 32
    fi
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请使用root用户执行此脚本！"
        exit 1
    fi
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 兼容性安装函数（使用静态二进制）
install_sing-box() {
    if command_exists sing-box; then
        info "sing-box 已安装: $(sing-box version 2>&1 | head -n1)"
        return 0
    fi

    info "正在下载安装 sing-box ..."
    local arch=$(uname -m)
    local arch_map=""
    case "$arch" in
        x86_64)  arch_map="amd64" ;;
        aarch64) arch_map="arm64" ;;
        armv7l)  arch_map="armv7" ;;
        *)       err "不支持的架构: $arch"; exit 1 ;;
    esac

    local latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f4)
    if [[ -z "$latest_version" ]]; then
        err "获取最新版本失败，请检查网络。"
        exit 1
    fi

    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${latest_version}-linux-${arch_map}.tar.gz"
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit

    info "下载地址: $download_url"
    if ! curl -sL "$download_url" -o sing-box.tar.gz; then
        err "下载失败，请检查网络。"
        exit 1
    fi
    tar xzf sing-box.tar.gz
    cp "sing-box-${latest_version}-linux-${arch_map}/sing-box" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    cd - >/dev/null || exit
    rm -rf "$temp_dir"

    if command_exists sing-box; then
        info "sing-box 安装成功！"
    else
        err "sing-box 安装失败！"
        exit 1
    fi
}

# 创建systemd服务
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
    systemctl daemon-reload
}

# 启动并启用服务
start_sing_box() {
    systemctl start sing-box
    systemctl enable sing-box
    info "sing-box 服务已启动！"
}

# 停止并禁用服务
stop_sing_box() {
    systemctl stop sing-box
    systemctl disable sing-box
    info "sing-box 服务已停止！"
}

# 重启服务
restart_sing_box() {
    systemctl restart sing-box
    info "sing-box 服务已重启！"
}

# 获取sing-box服务状态
service_status() {
    if systemctl is-active sing-box >/dev/null 2>&1; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${RED}未运行${PLAIN}"
    fi
}

# 初始化配置文件目录
init_config() {
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
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
    fi
}

# 显示所有节点
show_nodes() {
    if [[ ! -f "$SING_BOX_CONFIG" ]]; then
        warn "配置文件不存在，请先添加节点。"
        return
    fi

    local inbounds=$(jq -r '.inbounds[]? | "\(.tag) \(.type)"' "$SING_BOX_CONFIG" 2>/dev/null)
    if [[ -z "$inbounds" ]]; then
        warn "暂无节点配置，请使用 'sb add' 添加节点。"
        return
    fi

    echo -e "${BLUE}========== 节点列表 ==========${PLAIN}"
    echo -e "${BLUE}名称\t\t\t类型\t状态\t地址\t端口${PLAIN}"
    echo "----------------------------------------"
    local count=0
    while IFS= read -r line; do
        count=$((count+1))
        local tag=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{print $2}')
        local inbound=$(jq -r ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" 2>/dev/null)
        local listen_addr=$(echo "$inbound" | jq -r '.listen // "::"' | sed 's/^::$/::/')
        local port=$(echo "$inbound" | jq -r '.listen_port // "N/A"')
        echo -e "${GREEN}$tag${PLAIN}\t\t$type\t\t运行中\t$listen_addr\t$port"
    done <<< "$inbounds"
    echo "----------------------------------------"
    echo -e "共 ${GREEN}$count${PLAIN} 个节点"
    echo -e "${BLUE}================================${PLAIN}"
}

# 显示节点详细信息
show_node_info() {
    local tag=$1
    if [[ -z "$tag" ]]; then
        err "请指定节点名称"
        return
    fi
    local inbound=$(jq -r ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" 2>/dev/null)
    if [[ -z "$inbound" ]]; then
        err "节点 '$tag' 不存在"
        return
    fi

    local type=$(echo "$inbound" | jq -r '.type')
    local server=$(get_ip)
    local port=$(echo "$inbound" | jq -r '.listen_port // 443')
    local uuid=$(echo "$inbound" | jq -r '.users[0].uuid // .uuid // ""')
    local password=$(echo "$inbound" | jq -r '.password // .users[0].password // ""')
    local path=$(echo "$inbound" | jq -r '.transport.path // ""')
    local host=$(echo "$inbound" | jq -r '.transport.headers.Host // ""')
    local security=$(echo "$inbound" | jq -r '.transport.headers."X-Forwarded-For" // ""')
    local sni=$(echo "$inbound" | jq -r '.tls.server_name // ""')
    local public_key=$(echo "$inbound" | jq -r '.tls.reality.public_key // ""')
    local short_id=$(echo "$inbound" | jq -r '.tls.reality.short_id // ""')

    echo -e "${BLUE}========== 节点详情 ==========${PLAIN}"
    echo -e "名称: ${GREEN}$tag${PLAIN}"
    echo -e "类型: $type"
    echo -e "服务器地址: $server"
    echo -e "端口: $port"
    case $type in
        vless)
            echo -e "UUID: $uuid"
            ;;
        hysteria2)
            echo -e "密码: $password"
            ;;
        *)
            ;;
    esac
    echo -e "${BLUE}================================${PLAIN}"
}

# 生成VLESS分享链接
generate_vless_link() {
    local tag=$1
    local inbound=$(jq -r ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" 2>/dev/null)
    if [[ -z "$inbound" ]]; then
        err "节点 '$tag' 不存在"
        return
    fi

    local server=$(get_ip)
    local port=$(echo "$inbound" | jq -r '.listen_port // 443')
    local uuid=$(echo "$inbound" | jq -r '.users[0].uuid // .uuid // ""')
    local type=$(echo "$inbound" | jq -r '.type')
    local encryption="none"
    local security=""
    local flow=""
    local sni=$(echo "$inbound" | jq -r '.tls.server_name // ""')
    local fingerprint="chrome"
    local public_key=$(echo "$inbound" | jq -r '.tls.reality.public_key // ""')
    local short_id=$(echo "$inbound" | jq -r '.tls.reality.short_id // ""')
    local pbk=""
    local sid=""
    local host=$(echo "$inbound" | jq -r '.transport.headers.Host // ""')
    local path=$(echo "$inbound" | jq -r '.transport.path // "/"')
    local allowed_host=$(echo "$inbound" | jq -r '.transport.headers.Host // ""')

    case $type in
        vless)
            if [[ $(echo "$inbound" | jq -r '.transport.type // ""') == "ws" ]]; then
                security="tls"
                # 构建查询参数部分
                local query_params="encryption=${encryption}&security=${security}&type=ws&host=${allowed_host}&path=${path}&sni=${sni}&fp=${fingerprint}"
                if [[ -n "$public_key" ]] && [[ "$public_key" != "null" ]]; then
                    query_params="${query_params}&pbk=${public_key}"
                fi
                local link="vless://${uuid}@${server}:${port}?${query_params}#${tag}"
                echo -e "${GREEN}VLESS+WS 分享链接:${PLAIN}"
                echo "$link"
            elif [[ $(echo "$inbound" | jq -r '.tls.reality.enabled // false') == "true" ]]; then
                security="reality"
                local query_params="encryption=${encryption}&security=${security}&sni=${sni}&fp=${fingerprint}&pbk=${public_key}&sid=${short_id}&type=tcp&flow="
                local link="vless://${uuid}@${server}:${port}?${query_params}#${tag}"
                echo -e "${GREEN}VLESS+Reality 分享链接:${PLAIN}"
                echo "$link"
            fi
            ;;
        *)
            echo -e "${YELLOW}只支持生成 VLESS 类型节点的分享链接${PLAIN}"
            ;;
    esac
    echo -e "${BLUE}================================${PLAIN}"
}

# ----------------------------------------
# 协议添加函数
# ----------------------------------------

# 添加VLESS+WS协议
add_vless_ws() {
    info "正在添加 VLESS+WS 节点..."
    local node_name host port path allowed_host
    read -p "请输入节点名称 (默认: vless-ws): " node_name
    node_name=${node_name:-vless-ws}
    read -p "请输入域名 (必填): " host
    if [[ -z "$host" ]]; then
        err "域名为必填项"
        return
    fi
    read -p "请输入端口 (回车随机10000-50000): " port
    if [[ -z "$port" ]]; then
        port=$(generate_random_port)
        info "使用随机端口: $port"
    fi
    read -p "请输入路径 (默认 /): " path
    path=${path:-/}
    allowed_host="$host"

    local uuid=$(generate_uuid)
    info "生成的UUID: $uuid"

    local inbound_conf=$(cat <<EOF
{
  "type": "vless",
  "tag": "$node_name",
  "listen": "::",
  "listen_port": $port,
  "users": [
    {
      "uuid": "$uuid",
      "flow": ""
    }
  ],
  "transport": {
    "type": "ws",
    "path": "$path",
    "headers": {
      "Host": "$allowed_host"
    }
  },
  "tls": {
    "enabled": true,
    "server_name": "$host",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    }
  }
}
EOF
)
    add_inbound "$node_name" "$inbound_conf"
    echo -e "${BLUE}========== VLESS+WS 节点已添加 ==========${PLAIN}"
    generate_vless_link "$node_name"
}

# 添加VLESS+Reality协议
add_vless_reality() {
    info "正在添加 VLESS+Reality 节点..."
    local node_name port sni
    read -p "请输入节点名称 (默认: vless-reality): " node_name
    node_name=${node_name:-vless-reality}
    read -p "请输入端口 (回车随机10000-50000): " port
    if [[ -z "$port" ]]; then
        port=$(generate_random_port)
        info "使用随机端口: $port"
    fi
    read -p "请输入SNI (伪装域名, 例如: www.microsoft.com): " sni
    if [[ -z "$sni" ]]; then
        err "SNI是必填项"
        return
    fi

    local uuid=$(generate_uuid)
    info "生成的UUID: $uuid"
    local keypair=$(generate_reality_keypair)
    local private_key=$(echo "$keypair" | awk '{print $1}')
    local public_key=$(echo "$keypair" | awk '{print $2}')
    local short_id=$(openssl rand -hex 8)
    info "Reality 密钥对已生成"

    local inbound_conf=$(cat <<EOF
{
  "type": "vless",
  "tag": "$node_name",
  "listen": "::",
  "listen_port": $port,
  "users": [
    {
      "uuid": "$uuid",
      "flow": ""
    }
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
    add_inbound "$node_name" "$inbound_conf"
    echo -e "${BLUE}========== VLESS+Reality 节点已添加 ==========${PLAIN}"
    generate_vless_link "$node_name"
}

# 添加Hysteria2协议
add_hysteria2() {
    info "正在添加 Hysteria2 节点..."
    local node_name port password
    read -p "请输入节点名称 (默认: hysteria2): " node_name
    node_name=${node_name:-hysteria2}
    read -p "请输入端口 (回车随机10000-50000): " port
    if [[ -z "$port" ]]; then
        port=$(generate_random_port)
        info "使用随机端口: $port"
    fi
    read -p "请输入密码 (回车随机生成): " password
    if [[ -z "$password" ]]; then
        password=$(generate_ss2022_password)
        info "生成的密码: $password"
    fi

    local inbound_conf=$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "$node_name",
  "listen": "::",
  "listen_port": $port,
  "users": [
    {
      "password": "$password"
    }
  ],
  "tls": {
    "enabled": false
  }
}
EOF
)
    add_inbound "$node_name" "$inbound_conf"
    echo -e "${BLUE}========== Hysteria2 节点已添加 ==========${PLAIN}"
    # Hysteria2 有自己的分享链接格式，简单提示
    local server=$(get_ip)
    echo -e "Hysteria2 配置信息："
    echo -e "服务器: $server"
    echo -e "端口: $port"
    echo -e "密码: $password"
    echo -e "客户端可用 sing-box 或 hysteria2 客户端连接"
}

# 添加inbound到配置文件
add_inbound() {
    local tag=$1
    local new_inbound=$2
    if [[ ! -f "$SING_BOX_CONFIG" ]]; then
        init_config
    fi
    # 检查是否已存在同名节点
    if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" >/dev/null 2>&1; then
        err "节点 '$tag' 已存在，请使用不同的名称。"
        return
    fi
    # 添加新inbound
    local tmp_config=$(mktemp)
    jq --argjson new_inbound "$new_inbound" '.inbounds += [$new_inbound]' "$SING_BOX_CONFIG" > "$tmp_config"
    mv "$tmp_config" "$SING_BOX_CONFIG"
    restart_sing_box
    info "节点 '$tag' 已添加并生效。"
}

# 删除节点
delete_node() {
    local tag=$1
    if [[ -z "$tag" ]]; then
        err "请指定要删除的节点名称。"
        return
    fi
    if [[ ! -f "$SING_BOX_CONFIG" ]]; then
        err "配置文件不存在。"
        return
    fi
    if ! jq -e ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" >/dev/null 2>&1; then
        err "节点 '$tag' 不存在。"
        return
    fi
    # 删除inbound
    local tmp_config=$(mktemp)
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$SING_BOX_CONFIG" > "$tmp_config"
    mv "$tmp_config" "$SING_BOX_CONFIG"
    restart_sing_box
    info "节点 '$tag' 已删除。"
}

# 卸载sing-box
uninstall_sing_box() {
    warn "此操作将卸载 sing-box 并删除所有配置数据！"
    read -p "确定要卸载吗？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "取消卸载。"
        return
    fi
    stop_sing_box
    rm -f "$SING_BOX_BIN"
    rm -rf "$SING_BOX_CONFIG_DIR"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    # 删除快捷命令
    if [[ -f "/usr/local/bin/sb" ]]; then
        rm -f "/usr/local/bin/sb"
    fi
    info "sing-box 已卸载。"
}

# ----------------------------------------
# 主菜单和初始化
# ----------------------------------------

# 显示主菜单
show_menu() {
    clear
    echo -e "  ${GREEN}sing-box 一键管理脚本${PLAIN}"
    echo -e "  ${BLUE}=========================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN}  安装 sing-box"
    echo -e "  ${GREEN}2.${PLAIN}  卸载 sing-box"
    echo -e "  ${GREEN}3.${PLAIN}  添加节点"
    echo -e "  ${GREEN}4.${PLAIN}  删除节点"
    echo -e "  ${GREEN}5.${PLAIN}  查看所有节点"
    echo -e "  ${GREEN}6.${PLAIN}  查看节点详情"
    echo -e "  ${GREEN}7.${PLAIN}  生成节点分享链接"
    echo -e "  ${GREEN}8.${PLAIN}  重启 sing-box 服务"
    echo -e "  ${GREEN}9.${PLAIN}  查看 sing-box 状态"
    echo -e "  ${GREEN}0.${PLAIN}  退出"
    echo -e "  ${BLUE}=========================${PLAIN}"
    echo -e "  当前状态: $(service_status)"
    echo -e "  ${BLUE}=========================${PLAIN}"
}

# 添加节点子菜单
show_add_menu() {
    echo -e "  ${GREEN}请选择要添加的协议:${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN}  VLESS+WS (WebSocket)"
    echo -e "  ${GREEN}2.${PLAIN}  VLESS+Reality"
    echo -e "  ${GREEN}3.${PLAIN}  Hysteria2"
    echo -e "  ${GREEN}0.${PLAIN}  返回"
    read -p "请输入选择 [0-3]: " choice
    case $choice in
        1) add_vless_ws ;;
        2) add_vless_reality ;;
        3) add_hysteria2 ;;
        0) return ;;
        *) err "无效选择" ;;
    esac
}

# 安装主流程
install_sing_box() {
    if command_exists sing-box; then
        warn "sing-box 已安装。"
        read -p "是否重新安装？(y/n): " reinstall
        if [[ "$reinstall" != "y" && "$reinstall" != "Y" ]]; then
            return
        fi
        uninstall_sing_box
    fi
    install_sing-box
    init_config
    create_systemd_service
    start_sing_box
    info "sing-box 安装完成！"
    echo -e "请使用 ${GREEN}sb add${PLAIN} 添加节点，或 ${GREEN}sb${PLAIN} 进入管理菜单。"
}

# ----------------------------------------
# 命令行参数处理
# ----------------------------------------
case "$1" in
    add)
        show_add_menu
        ;;
    del)
        if [[ -z "$2" ]]; then
            err "请指定要删除的节点名称"
            echo "用法: sb del <节点名称>"
            exit 1
        fi
        delete_node "$2"
        ;;
    uninstall)
        uninstall_sing_box
        ;;
    *)
        check_root
        if [[ ! -f "$SING_BOX_CONFIG" ]] && [[ ! -f "$SING_BOX_BIN" ]]; then
            install_sing_box
        fi
        while true; do
            show_menu
            read -p "请输入选择 [0-9]: " opt
            case $opt in
                1) install_sing_box ;;
                2) uninstall_sing_box ;;
                3) show_add_menu ;;
                4) 
                    read -p "请输入要删除的节点名称: " node_name
                    delete_node "$node_name"
                    ;;
                5) show_nodes ;;
                6)
                    read -p "请输入节点名称: " node_name
                    show_node_info "$node_name"
                    ;;
                7)
                    read -p "请输入节点名称: " node_name
                    generate_vless_link "$node_name"
                    ;;
                8) restart_sing_box ;;
                9) 
                    systemctl status sing-box --no-pager
                    ;;
                0) exit 0 ;;
                *) err "无效选择" ;;
            esac
            echo ""
            read -p "按 Enter 键继续..." 
        done
        ;;
esac
