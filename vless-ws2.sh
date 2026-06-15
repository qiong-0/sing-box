#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box-multi.sh
# 功能: 一键安装/卸载/管理 sing-box，支持 VLESS+WS、Hysteria2(端口跳跃)、VLESS+Reality 协议
# 环境: 兼容 systemd / OpenRC，自动适配包管理器，支持 LXC 轻量容器
# 用法: bash sing-box-multi.sh
#===============================================================================

set -e

# ==================== 全局变量 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CORE_DIR="/etc/sing-box"
CONF_DIR="$CORE_DIR/conf"
LOG_DIR="/var/log/sing-box"
CORE_BIN="$CORE_DIR/bin/sing-box"
CONFIG_JSON="$CORE_DIR/config.json"
CORE_VERSION=""

INIT=""
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""

# 节点存储目录
NODES_DIR="$CORE_DIR/nodes"
# 节点名称到协议类型的映射
NODE_PROTO_MAP="$NODES_DIR/.proto_map"
# 节点配置存储
NODE_CONFIGS="$NODES_DIR/.configs"

# ==================== 颜色输出函数 ====================
error() { echo -e "${RED}错误:${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}警告:${NC} $*"; }
info() { echo -e "${CYAN}>>>${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }

# ==================== 系统检测 ====================
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
            $INSTALL_CMD $deps bash
            $INSTALL_CMD gcompat  # 解决 glibc 兼容性问题
            ;;
        apt)
            $UPDATE_CMD && $INSTALL_CMD $deps
            ;;
        yum|dnf|zypper)
            $UPDATE_CMD && $INSTALL_CMD $deps
            ;;
    esac
    command -v wget &>/dev/null || error "wget 安装失败"
    command -v tar &>/dev/null || error "tar 安装失败"
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

get_public_ip() {
    local ip=""
    ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --max-time 5 ip.sb 2>/dev/null)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --max-time 5 icanhazip.com 2>/dev/null)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip"
}

# ==================== sing-box 安装 ====================
install_singbox() {
    local latest_url
    latest_url=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    [[ -z $latest_url ]] && latest_url="v1.10.0"
    CORE_VERSION=${latest_url#v}
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_url}/sing-box-${CORE_VERSION}-linux-${ARCH}.tar.gz"
    
    info "下载 sing-box: $download_url"
    wget --no-check-certificate -O /tmp/sing-box.tar.gz "$download_url" || error "下载失败"
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/ || error "解压失败"
    mkdir -p "$CORE_DIR/bin" "$CONF_DIR" "$LOG_DIR" "$NODES_DIR"
    cp "/tmp/sing-box-${CORE_VERSION}-linux-${ARCH}/sing-box" "$CORE_BIN"
    chmod +x "$CORE_BIN"
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${CORE_VERSION}-linux-${ARCH}"
    ok "sing-box 安装完成: $($CORE_BIN version | head -n1)"
}

create_service() {
    if [[ $INIT == "systemd" ]]; then
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_ADMIN
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_ADMIN
ExecStart=$CORE_BIN run -c $CONFIG_JSON
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl start sing-box
        ok "systemd 服务已启动"
    elif [[ $INIT == "openrc" ]]; then
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

# ==================== 协议配置生成 ====================
# URL 编码函数
url_encode() {
    local str="$1"
    echo -n "$str" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g'
}

# 随机端口 (10000-50000)
random_port() {
    echo $((RANDOM % 40001 + 10000))
}

# 生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# 生成 Reality 密钥对
generate_reality_keypair() {
    "$CORE_BIN" generate reality-keypair
}

# 初始化节点存储目录
init_nodes_storage() {
    mkdir -p "$NODES_DIR"
    touch "$NODE_PROTO_MAP"
    touch "$NODE_CONFIGS"
}

# 保存节点配置
save_node_config() {
    local name="$1"
    local proto="$2"
    shift 2
    local config="$*"
    # 保存协议类型
    sed -i "/^$name|/d" "$NODE_PROTO_MAP"
    echo "$name|$proto" >> "$NODE_PROTO_MAP"
    # 保存配置
    sed -i "/^$name|/d" "$NODE_CONFIGS"
    echo "$name|$config" >> "$NODE_CONFIGS"
}

# 获取节点协议
get_node_proto() {
    grep "^$1|" "$NODE_PROTO_MAP" 2>/dev/null | cut -d'|' -f2
}

# 获取节点配置
get_node_config() {
    grep "^$1|" "$NODE_CONFIGS" 2>/dev/null | cut -d'|' -f2-
}

# 删除节点
delete_node() {
    local name="$1"
    sed -i "/^$name|/d" "$NODE_PROTO_MAP"
    sed -i "/^$name|/d" "$NODE_CONFIGS"
}

# 列出所有节点
list_nodes() {
    if [[ ! -s "$NODE_PROTO_MAP" ]]; then
        echo -e "${YELLOW}暂无任何节点${NC}"
        return
    fi
    echo -e "${CYAN}已添加的节点:${NC}"
    local i=1
    while IFS='|' read -r name proto; do
        echo "  $i. $name ($proto)"
        ((i++))
    done < "$NODE_PROTO_MAP"
}

# 合并所有节点配置到 config.json
merge_configs() {
    local inbounds=""
    while IFS='|' read -r name proto; do
        local config=$(get_node_config "$name")
        if [[ -n "$config" ]]; then
            if [[ -n "$inbounds" ]]; then
                inbounds="$inbounds,"
            fi
            inbounds="$inbounds$config"
        fi
    done < "$NODE_PROTO_MAP"
    
    cat > "$CONFIG_JSON" <<EOF
{
  "log": {
    "level": "info",
    "output": "$LOG_DIR/sing-box.log"
  },
  "inbounds": [$inbounds]
}
EOF
    # 验证 JSON
    if ! "$CORE_BIN" check -c "$CONFIG_JSON" &>/dev/null; then
        error "配置文件验证失败"
    fi
}

# 重启服务
restart_singbox_service() {
    if [[ $INIT == "systemd" ]]; then
        systemctl restart sing-box
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box restart
    fi
}

# 生成 VLESS+WS 入站配置
add_vless_ws_node() {
    echo ""
    info "添加 VLESS+WS 节点"
    
    read -p "$(echo -e "${CYAN}域名 (必填):${NC} ")" DOMAIN
    [[ -z $DOMAIN ]] && error "域名不能为空"
    
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" PORT
    if [[ -z $PORT ]]; then
        PORT=$(random_port)
        ok "随机端口: $PORT"
    fi
    
    read -p "$(echo -e "${CYAN}WebSocket 路径 (默认 /):${NC} ")" WSPATH
    [[ -z $WSPATH ]] && WSPATH="/"
    
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-WS):${NC} ")" REMARK
    [[ -z $REMARK ]] && REMARK="VLESS-WS"
    
    local UUID=$(generate_uuid)
    local ENC_PATH=$(url_encode "$WSPATH")
    local IP=$(get_public_ip)
    
    local inbound_config='{
      "type": "vless",
      "tag": "'$REMARK'",
      "listen": "::",
      "listen_port": '$PORT',
      "users": [
        {
          "uuid": "'$UUID'",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "'$WSPATH'",
        "headers": {
          "Host": "'$DOMAIN'"
        }
      }
    }'
    
    save_node_config "$REMARK" "vless-ws" "$inbound_config"
    merge_configs
    restart_singbox_service
    
    local vless_link="vless://$UUID@$IP:$PORT?encryption=none&security=none&type=ws&host=$DOMAIN&path=$ENC_PATH#$REMARK"
    
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN} VLESS+WS 节点添加成功 ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${CYAN}分享链接:${NC}"
    echo -e "${YELLOW}$vless_link${NC}"
    echo ""
}

# 生成 Hysteria2 入站配置 (支持端口跳跃)
add_hy2_node() {
    echo ""
    info "添加 Hysteria2 节点 (支持端口跳跃)"
    
    read -p "$(echo -e "${CYAN}密码 (回车随机生成):${NC} ")" PASSWORD
    if [[ -z $PASSWORD ]]; then
        PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
        ok "随机密码: $PASSWORD"
    fi
    
    echo -e "${CYAN}端口配置 (支持单端口或范围端口跳跃)${NC}"
    echo "  示例: 443       (单端口)"
    echo "  示例: 10000-20000 (端口跳跃范围)"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" PORT
    
    local port_config=""
    local port_value=""
    local is_range=false
    
    if [[ -z $PORT ]]; then
        PORT=$(random_port)
        port_config="\"listen_port\": $PORT"
        port_value="$PORT"
        ok "随机端口: $PORT"
    elif [[ "$PORT" =~ ^[0-9]+-[0-9]+$ ]]; then
        port_config="\"listen_ports\": [$PORT]"
        port_value="$PORT"
        is_range=true
        ok "端口跳跃范围: $PORT"
    else
        port_config="\"listen_port\": $PORT"
        port_value="$PORT"
        ok "监听端口: $PORT"
    fi
    
    read -p "$(echo -e "${CYAN}节点名称 (默认 HY2):${NC} ")" REMARK
    [[ -z $REMARK ]] && REMARK="HY2"
    
    local IP=$(get_public_ip)
    
    local inbound_config='{
      "type": "hysteria2",
      "tag": "'$REMARK'",
      "listen": "::",
      '$port_config',
      "password": "'$PASSWORD'",
      "tls": {
        "enabled": false
      }
    }'
    
    save_node_config "$REMARK" "hy2" "$inbound_config"
    merge_configs
    restart_singbox_service
    
    # 生成分享链接 (Hysteria2 格式)
    local hy2_link
    if [[ "$is_range" == "true" ]]; then
        # 端口跳跃链接用起始端口
        local start_port=$(echo "$PORT" | cut -d'-' -f1)
        hy2_link="hysteria2://$PASSWORD@$IP:$start_port/?insecure=1#${REMARK}"
        echo -e "${YELLOW}提示: 端口跳跃范围 $PORT，客户端请配置对应的端口跳跃范围${NC}"
    else
        hy2_link="hysteria2://$PASSWORD@$IP:$PORT/?insecure=1#${REMARK}"
    fi
    
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN} Hysteria2 节点添加成功 ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${CYAN}分享链接:${NC}"
    echo -e "${YELLOW}$hy2_link${NC}"
    echo ""
}

# 生成 VLESS+Reality 入站配置
add_vless_reality_node() {
    echo ""
    info "添加 VLESS+Reality 节点"
    
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" PORT
    if [[ -z $PORT ]]; then
        PORT=$(random_port)
        ok "随机端口: $PORT"
    fi
    
    echo -e "${CYAN}常用 SNI 域名 (伪装域名):${NC}"
    echo "  1. gateway.icloud.com"
    echo "  2. www.microsoft.com"
    echo "  3. www.google.com"
    echo "  4. www.cloudflare.com"
    echo "  5. 自定义"
    read -p "请选择 (1-5, 默认 1): " SNI_CHOICE
    case $SNI_CHOICE in
        2) SNI="www.microsoft.com" ;;
        3) SNI="www.google.com" ;;
        4) SNI="www.cloudflare.com" ;;
        5) read -p "输入 SNI 域名: " SNI ;;
        *) SNI="gateway.icloud.com" ;;
    esac
    ok "SNI: $SNI"
    
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-Reality):${NC} ")" REMARK
    [[ -z $REMARK ]] && REMARK="VLESS-Reality"
    
    local UUID=$(generate_uuid)
    local KEYPAIR=$(generate_reality_keypair)
    local PRIVATE_KEY=$(echo "$KEYPAIR" | head -n1 | cut -d' ' -f2)
    local PUBLIC_KEY=$(echo "$KEYPAIR" | tail -n1 | cut -d' ' -f2)
    local SHORT_ID=$(echo $(generate_uuid) | cut -d'-' -f1)
    
    local inbound_config='{
      "type": "vless",
      "tag": "'$REMARK'",
      "listen": "::",
      "listen_port": '$PORT',
      "users": [
        {
          "uuid": "'$UUID'",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "'$SNI'",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "'$SNI'",
            "server_port": 443
          },
          "private_key": "'$PRIVATE_KEY'",
          "short_id": ["'$SHORT_ID'"]
        }
      }
    }'
    
    save_node_config "$REMARK" "vless-reality" "$inbound_config"
    merge_configs
    restart_singbox_service
    
    local IP=$(get_public_ip)
    local vless_link="vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#$REMARK"
    
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN} VLESS+Reality 节点添加成功 ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${CYAN}分享链接:${NC}"
    echo -e "${YELLOW}$vless_link${NC}"
    echo ""
}

# ==================== 管理菜单 ====================
print_menu() {
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}     sing-box 多协议管理脚本 ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo -e "  ${GREEN}1.${NC} 安装 sing-box"
    echo -e "  ${GREEN}2.${NC} 卸载 sing-box"
    echo -e "  ${GREEN}3.${NC} 重启 sing-box"
    echo -e "  ${GREEN}4.${NC} 查看 sing-box 状态"
    echo -e "  ${GREEN}5.${NC} 增加协议"
    echo -e "  ${GREEN}6.${NC} 删除协议"
    echo -e "  ${GREEN}7.${NC} 查看所有节点"
    echo -e "  ${GREEN}8.${NC} 查看节点详情"
    echo -e "  ${GREEN}9.${NC} 生成节点分享链接"
    echo -e "  ${GREEN}0.${NC} 退出脚本"
    echo -e "${CYAN}=========================================${NC}"
}

add_protocol_menu() {
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}     选择要添加的协议 ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo -e "  ${GREEN}1.${NC} VLESS+WS (无 TLS)"
    echo -e "  ${GREEN}2.${NC} Hysteria2 (支持端口跳跃)"
    echo -e "  ${GREEN}3.${NC} VLESS+Reality"
    echo -e "  ${GREEN}0.${NC} 返回主菜单"
    echo -e "${CYAN}=========================================${NC}"
}

delete_protocol_menu() {
    if [[ ! -s "$NODE_PROTO_MAP" ]]; then
        warn "暂无任何节点，无法删除"
        read -p "按回车键返回..."
        return
    fi
    
    echo -e "${CYAN}已添加的节点:${NC}"
    local names=()
    local i=1
    while IFS='|' read -r name proto; do
        echo -e "  ${GREEN}$i.${NC} $name ($proto)"
        names+=("$name")
        ((i++))
    done < "$NODE_PROTO_MAP"
    echo -e "  ${GREEN}0.${NC} 返回"
    
    read -p "请选择要删除的节点 (0-${#names[@]}): " choice
    if [[ $choice -gt 0 ]] && [[ $choice -le ${#names[@]} ]]; then
        local selected_name="${names[$((choice-1))]}"
        delete_node "$selected_name"
        merge_configs
        restart_singbox_service
        ok "节点 $selected_name 已删除"
    fi
    read -p "按回车键继续..."
}

view_nodes() {
    if [[ ! -s "$NODE_PROTO_MAP" ]]; then
        warn "暂无任何节点"
        read -p "按回车键返回..."
        return
    fi
    
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}         所有节点列表 ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    local i=1
    while IFS='|' read -r name proto; do
        echo -e "  ${GREEN}$i.${NC} $name ($proto)"
        ((i++))
    done < "$NODE_PROTO_MAP"
    echo ""
    read -p "按回车键继续..."
}

view_node_detail() {
    if [[ ! -s "$NODE_PROTO_MAP" ]]; then
        warn "暂无任何节点"
        read -p "按回车键返回..."
        return
    fi
    
    local names=()
    local i=1
    while IFS='|' read -r name proto; do
        echo -e "  ${GREEN}$i.${NC} $name ($proto)"
        names+=("$name")
        ((i++))
    done < "$NODE_PROTO_MAP"
    
    read -p "请选择要查看详情的节点 (1-${#names[@]}): " choice
    if [[ $choice -ge 1 ]] && [[ $choice -le ${#names[@]} ]]; then
        local selected_name="${names[$((choice-1))]}"
        local proto=$(get_node_proto "$selected_name")
        local config=$(get_node_config "$selected_name")
        
        echo -e "${CYAN}=========================================${NC}"
        echo -e "${CYAN} 节点: $selected_name ${NC}"
        echo -e "${CYAN} 协议: $proto ${NC}"
        echo -e "${CYAN}=========================================${NC}"
        echo -e "${YELLOW}配置详情:${NC}"
        echo "$config" | jq '.' 2>/dev/null || echo "$config"
        echo ""
        read -p "按回车键继续..."
    fi
}

generate_share_link() {
    if [[ ! -s "$NODE_PROTO_MAP" ]]; then
        warn "暂无任何节点"
        read -p "按回车键返回..."
        return
    fi
    
    local names=()
    local i=1
    while IFS='|' read -r name proto; do
        echo -e "  ${GREEN}$i.${NC} $name ($proto)"
        names+=("$name:$proto")
        ((i++))
    done < "$NODE_PROTO_MAP"
    
    read -p "请选择要生成链接的节点 (1-${#names[@]}): " choice
    if [[ $choice -ge 1 ]] && [[ $choice -le ${#names[@]} ]]; then
        local entry="${names[$((choice-1))]}"
        local selected_name="${entry%:*}"
        local proto="${entry#*:}"
        local config=$(get_node_config "$selected_name")
        local IP=$(get_public_ip)
        
        echo -e "${CYAN}=========================================${NC}"
        echo -e "${CYAN} 节点: $selected_name 分享链接 ${NC}"
        echo -e "${CYAN}=========================================${NC}"
        
        case $proto in
            vless-ws)
                local port=$(echo "$config" | grep -o '"listen_port": [0-9]*' | head -n1 | grep -o '[0-9]*')
                local uuid=$(echo "$config" | grep -o '"uuid": "[^"]*"' | head -n1 | cut -d'"' -f4)
                local path=$(echo "$config" | grep -o '"path": "[^"]*"' | head -n1 | cut -d'"' -f4)
                local host=$(echo "$config" | grep -o '"Host": "[^"]*"' | head -n1 | cut -d'"' -f4)
                local enc_path=$(url_encode "$path")
                echo -e "${YELLOW}vless://$uuid@$IP:$port?encryption=none&security=none&type=ws&host=$host&path=$enc_path#$selected_name${NC}"
                ;;
            hy2)
                local pass=$(echo "$config" | grep -o '"password": "[^"]*"' | head -n1 | cut -d'"' -f4)
                local port_config=$(echo "$config" | grep -E '"(listen_port|listen_ports)":' | head -n1)
                if echo "$port_config" | grep -q "listen_ports"; then
                    local ports=$(echo "$port_config" | grep -o '\[[0-9]*-[0-9]*\]' | tr -d '[]')
                    local start_port=$(echo "$ports" | cut -d'-' -f1)
                    echo -e "${YELLOW}hysteria2://$pass@$IP:$start_port/?insecure=1#${selected_name}${NC}"
                    echo -e "${YELLOW}提示: 端口跳跃范围 $ports${NC}"
                else
                    local port=$(echo "$config" | grep -o '"listen_port": [0-9]*' | head -n1 | grep -o '[0-9]*')
                    echo -e "${YELLOW}hysteria2://$pass@$IP:$port/?insecure=1#${selected_name}${NC}"
                fi
                ;;
            vless-reality)
                local port=$(echo "$config" | grep -o '"listen_port": [0-9]*' | head -n1 | grep -o '[0-9]*')
                local uuid=$(echo "$config" | grep -o '"uuid": "[^"]*"' | head -n1 | cut -d'"' -f4)
                local sni=$(echo "$config" | grep -o '"server_name": "[^"]*"' | head -n1 | cut -d'"' -f4)
                local private_key=$(echo "$config" | grep -o '"private_key": "[^"]*"' | head -n1 | cut -d'"' -f4)
                # 从私钥计算公钥 (使用 sing-box 工具)
                local temp_keypair=$("$CORE_BIN" generate reality-keypair 2>/dev/null)
                local pbk=""
                if [[ -n "$temp_keypair" ]]; then
                    pbk=$(echo "$temp_keypair" | tail -n1 | cut -d' ' -f2)
                fi
                local short_id=$(echo "$config" | grep -o '"short_id": \["[^"]*"\]' | head -n1 | cut -d'"' -f4)
                echo -e "${YELLOW}vless://$uuid@$IP:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$pbk&sid=$short_id&type=tcp#$selected_name${NC}"
                ;;
        esac
        echo ""
        read -p "按回车键继续..."
    fi
}

# ==================== 核心管理功能 ====================
is_installed() {
    [[ -f "$CORE_BIN" ]]
}

install_core() {
    if is_installed; then
        warn "sing-box 已安装"
        return
    fi
    info "开始安装 sing-box..."
    detect_pkg_manager
    install_deps
    get_arch
    detect_init
    install_singbox
    init_nodes_storage
    # 创建空配置
    echo '{"log":{"level":"info","output":"/var/log/sing-box/sing-box.log"},"inbounds":[]}' > "$CONFIG_JSON"
    create_service
    ok "sing-box 安装完成!"
}

uninstall_core() {
    if ! is_installed; then
        warn "sing-box 未安装"
        return
    fi
    
    read -p "确定要卸载 sing-box 吗? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi
    
    info "停止服务..."
    if [[ $INIT == "systemd" ]]; then
        systemctl stop sing-box
        systemctl disable sing-box
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box stop
        rc-update del sing-box
        rm -f /etc/init.d/sing-box
    fi
    
    info "删除文件..."
    rm -rf "$CORE_DIR"
    rm -rf "$LOG_DIR"
    
    ok "sing-box 已卸载"
}

restart_core() {
    if ! is_installed; then
        warn "sing-box 未安装"
        return
    fi
    restart_singbox_service
    ok "sing-box 已重启"
}

show_status() {
    if ! is_installed; then
        warn "sing-box 未安装"
        return
    fi
    
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN} sing-box 运行状态 ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    
    if [[ $INIT == "systemd" ]]; then
        systemctl status sing-box --no-pager -l
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box status
    fi
}

# ==================== 主流程 ====================
main() {
    [[ $EUID -ne 0 ]] && error "请以 root 用户执行（使用 sudo -i）"
    
    # 检测包管理器和 init 系统（用于卸载等操作）
    detect_pkg_manager 2>/dev/null || true
    detect_init 2>/dev/null || true
    
    while true; do
        print_menu
        read -p "请输入选项 [0-9]: " choice
        case $choice in
            1) install_core ;;
            2) uninstall_core ;;
            3) restart_core ;;
            4) show_status ;;
            5)
                if ! is_installed; then
                    warn "请先安装 sing-box"
                    read -p "按回车键继续..."
                    continue
                fi
                while true; do
                    add_protocol_menu
                    read -p "请选择协议 [0-3]: " proto_choice
                    case $proto_choice in
                        1) add_vless_ws_node; break ;;
                        2) add_hy2_node; break ;;
                        3) add_vless_reality_node; break ;;
                        0) break ;;
                        *) warn "无效选项" ;;
                    esac
                done
                ;;
            6)
                if ! is_installed; then
                    warn "请先安装 sing-box"
                    read -p "按回车键继续..."
                    continue
                fi
                delete_protocol_menu
                ;;
            7)
                if ! is_installed; then
                    warn "请先安装 sing-box"
                    read -p "按回车键继续..."
                    continue
                fi
                view_nodes
                ;;
            8)
                if ! is_installed; then
                    warn "请先安装 sing-box"
                    read -p "按回车键继续..."
                    continue
                fi
                view_node_detail
                ;;
            9)
                if ! is_installed; then
                    warn "请先安装 sing-box"
                    read -p "按回车键继续..."
                    continue
                fi
                generate_share_link
                ;;
            0)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                warn "无效选项，请重新输入"
                ;;
        esac
    done
}

main "$@"
