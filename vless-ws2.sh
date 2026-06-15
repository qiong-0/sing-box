#!/usr/bin/env bash
#===============================================================================
# 名称: sb.sh (sing-box 管理脚本)
# 功能: 一键安装/管理 sing-box，支持 VLESS+WS、VLESS+Reality、Hysteria2(端口跳跃)
# 环境: 兼容 systemd / OpenRC，自动适配包管理器，支持 LXC/OpenVZ 轻量容器
# 用法: bash sb.sh 或 sb (安装后可使用快捷命令)
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
CORE_DIR="/etc/sing-box"
CONF_DIR="$CORE_DIR/conf"
LOG_DIR="/var/log/sing-box"
CORE_BIN="$CORE_DIR/bin/sing-box"
MAIN_CONFIG="$CORE_DIR/config.json"
PROTOCOLS_FILE="$CONF_DIR/protocols.conf"
SERVICE_FILE_SYSTEMD="/etc/systemd/system/sing-box.service"
SERVICE_FILE_OPENRC="/etc/init.d/sing-box"

# 协议类型
PROTOCOL_TYPES=("vless-ws" "vless-reality" "hy2")

# 帮助函数
error() { echo -e "${RED}错误:${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}警告:${NC} $*"; }
info() { echo -e "${CYAN}>>>${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }

# 快捷命令创建
create_alias() {
    if ! grep -q "alias sb=" ~/.bashrc 2>/dev/null; then
        echo "alias sb='bash $0'" >> ~/.bashrc
        ok "已创建快捷命令: sb"
    fi
    if ! grep -q "alias sb=" ~/.bash_profile 2>/dev/null; then
        echo "alias sb='bash $0'" >> ~/.bash_profile
    fi
    if ! grep -q "alias sb=" ~/.zshrc 2>/dev/null; then
        echo "alias sb='bash $0'" >> ~/.zshrc 2>/dev/null || true
    fi
}

# 检查 root
check_root() {
    [[ $EUID -ne 0 ]] && error "请以 root 用户执行（使用 sudo -i）"
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
        error "不支持的包管理器，请手动安装 wget、tar、curl"
    fi
}

# 安装必要工具
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
    command -v tar &>/dev/null || error "tar 安装失败"
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

# 生成 UUID
gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    elif [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        echo "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")"
    fi
}

# 生成随机端口（用于单端口场景，端口跳跃不再使用）
random_port() {
    echo $((RANDOM % 40001 + 10000))
}

# 添加 VLESS+WS 协议
add_vless_ws() {
    echo ""
    info "添加 VLESS+WebSocket 协议 (无 TLS)"

    read -p "$(echo -e "${CYAN}域名/IP (必填):${NC} ")" DOMAIN
    [[ -z $DOMAIN ]] && error "域名/IP 不能为空"

    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" PORT
    [[ -z $PORT ]] && PORT=$(random_port) && ok "随机端口: $PORT"

    read -p "$(echo -e "${CYAN}WebSocket 路径 (默认 /):${NC} ")" WSPATH
    [[ -z $WSPATH ]] && WSPATH="/"

    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-WS):${NC} ")" REMARK
    [[ -z $REMARK ]] && REMARK="VLESS-WS"

    UUID=$(gen_uuid)
    echo ""
    ok "配置信息: 域名=$DOMAIN, 端口=$PORT, 路径=$WSPATH, UUID=$UUID, 名称=$REMARK"

    # 生成 JSON 配置
    local proto_file="$CONF_DIR/vless-ws_${PORT}.json"
    cat > "$proto_file" <<EOF
{
    "type": "vless",
    "tag": "$REMARK",
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
        "path": "$WSPATH"
    }
}
EOF

    # 生成分享链接
    encoded_path=$(echo -n "$WSPATH" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g')
    local link="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=none&type=ws&path=$encoded_path&host=$DOMAIN#$REMARK"
    echo "$link" > "$CONF_DIR/${REMARK}_link.txt"

    echo ""
    ok "VLESS+WS 协议添加成功"
    echo -e "${GREEN}分享链接:${NC} $link"
    echo ""

    # 写入协议记录
    echo "vless-ws|$REMARK|$DOMAIN|$PORT|$WSPATH|$UUID" >> "$PROTOCOLS_FILE"
}

# 添加 VLESS+Reality 协议
add_vless_reality() {
    echo ""
    info "添加 VLESS+Reality 协议"

    read -p "$(echo -e "${CYAN}域名/IP (必填):${NC} ")" DOMAIN
    [[ -z $DOMAIN ]] && error "域名/IP 不能为空"

    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" PORT
    [[ -z $PORT ]] && PORT=$(random_port) && ok "随机端口: $PORT"

    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-REALITY):${NC} ")" REMARK
    [[ -z $REMARK ]] && REMARK="VLESS-REALITY"

    UUID=$(gen_uuid)
    echo ""
    ok "配置信息: 域名=$DOMAIN, 端口=$PORT, UUID=$UUID, 名称=$REMARK"

    # 生成 Reality 密钥对
    info "正在生成 Reality 密钥对..."
    local keypair=$($CORE_BIN generate reality-keypair)
    local private_key=$(echo "$keypair" | grep "PrivateKey" | awk '{print $2}')
    local public_key=$(echo "$keypair" | grep "PublicKey" | awk '{print $2}')

    # 生成 shortId
    local short_id=$(tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 16)
    [[ -z $short_id ]] && short_id="0000000000000000"

    # 获取外网 IP
    local server_ip=$(curl -s --max-time 5 ip.sb 2>/dev/null)
    [[ -z $server_ip ]] && server_ip="$DOMAIN"

    # 生成 JSON 配置
    local proto_file="$CONF_DIR/vless-reality_${PORT}.json"
    cat > "$proto_file" <<EOF
{
    "type": "vless",
    "tag": "$REMARK",
    "listen": "::",
    "listen_port": $PORT,
    "users": [
        {
            "uuid": "$UUID",
            "flow": "xtls-rprx-vision"
        }
    ],
    "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "reality": {
            "enabled": true,
            "handshake": {
                "server": "$DOMAIN",
                "server_port": 443
            },
            "private_key": "$private_key",
            "short_id": ["$short_id"]
        }
    }
}
EOF

    # 生成分享链接
    local link="vless://$UUID@$server_ip:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&pbk=$public_key&sid=$short_id#$REMARK"
    echo "$link" > "$CONF_DIR/${REMARK}_link.txt"

    echo ""
    ok "VLESS+Reality 协议添加成功"
    echo -e "${GREEN}分享链接:${NC} $link"
    echo ""
    echo -e "${YELLOW}注: 如需修改 sni，请将链接中的域名参数 ($DOMAIN) 替换为目标域名${NC}"
    echo ""

    # 写入协议记录
    echo "vless-reality|$REMARK|$DOMAIN|$PORT|$UUID|$private_key|$public_key|$short_id" >> "$PROTOCOLS_FILE"
}

# 添加 Hysteria2 协议（端口跳跃版本，无带宽限制）
add_hy2() {
    echo ""
    info "添加 Hysteria2 协议 (支持端口跳跃)"

    read -p "$(echo -e "${CYAN}域名/IP (必填):${NC} ")" DOMAIN
    [[ -z $DOMAIN ]] && error "域名/IP 不能为空"

    # 输入端口跳跃范围
    echo -e "${CYAN}端口跳跃设置:${NC}"
    echo -e "  示例: 10000-50000 (范围)  或  10000,20000,30000 (多个单端口)  或  10000 (单端口)"
    read -p "$(echo -e "${CYAN}请输入端口范围/端口 (回车默认 10000-50000):${NC} ")" PORTS_INPUT
    if [[ -z $PORTS_INPUT ]]; then
        PORTS_INPUT="10000-50000"
        ok "使用默认端口跳跃范围: $PORTS_INPUT"
    fi

    # 验证格式（简单校验）
    if [[ ! $PORTS_INPUT =~ ^[0-9]+([,-][0-9]+)*$ ]]; then
        error "端口格式错误，请使用数字、短横线范围或逗号分隔，例如 10000-20000 或 10000,20000,30000"
    fi

    # 提取起始端口（用于文件名和记录）
    local start_port=$(echo "$PORTS_INPUT" | grep -oE '[0-9]+' | head -n1)
    if [[ -z $start_port ]]; then
        error "无法解析起始端口"
    fi

    read -p "$(echo -e "${CYAN}节点名称 (默认 HYSTERIA2):${NC} ")" REMARK
    [[ -z $REMARK ]] && REMARK="HYSTERIA2"

    # 生成随机密码
    local password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 32)
    [[ -z $password ]] && password=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
    read -p "$(echo -e "${CYAN}密码 (回车随机生成):${NC} ")" input_pass
    [[ -n $input_pass ]] && password="$input_pass"

    echo ""
    ok "配置信息: 域名=$DOMAIN, 端口跳跃=$PORTS_INPUT, 密码=$password, 名称=$REMARK"

    # 生成 JSON 配置（使用 ports 字段，支持字符串范围或数组）
    local proto_file="$CONF_DIR/hy2_${start_port}.json"
    # 判断 ports 输入格式，如果是纯数字范围（如 10000-50000）则直接作为字符串，否则尝试转换为数组
    if [[ $PORTS_INPUT =~ ^[0-9]+-[0-9]+$ ]]; then
        ports_conf="\"$PORTS_INPUT\""
    else
        # 支持逗号分隔的多个端口/范围，转为 JSON 数组
        IFS=',' read -ra port_arr <<< "$PORTS_INPUT"
        json_array="["
        for item in "${port_arr[@]}"; do
            json_array+="\"$item\","
        done
        ports_conf="${json_array%,}]"
    fi

    cat > "$proto_file" <<EOF
{
    "type": "hysteria2",
    "tag": "$REMARK",
    "listen": "::",
    "ports": $ports_conf,
    "users": [
        {
            "password": "$password"
        }
    ]
}
EOF

    # 生成分享链接（带 ports 参数）
    # 标准 hy2 链接格式：hysteria2://password@domain:first_port?ports=range#remark
    # first_port 取起始端口（第一个端口号）
    local first_port="$start_port"
    # URL 编码 ports 参数（保留 - 和 ,）
    local encoded_ports=$(echo "$PORTS_INPUT" | sed 's/,/%2C/g')
    local link="hysteria2://$password@$DOMAIN:$first_port?ports=$encoded_ports#$REMARK"
    echo "$link" > "$CONF_DIR/${REMARK}_link.txt"

    echo ""
    ok "Hysteria2 协议添加成功 (端口跳跃: $PORTS_INPUT)"
    echo -e "${GREEN}分享链接:${NC} $link"
    echo -e "${YELLOW}注: 客户端需支持 ports 参数才能使用端口跳跃，否则仅使用 $first_port 单端口${NC}"
    echo ""

    # 写入协议记录（字段: 类型|名称|域名|起始端口|密码|端口跳跃原始串）
    echo "hy2|$REMARK|$DOMAIN|$start_port|$password|$PORTS_INPUT" >> "$PROTOCOLS_FILE"
}

# 合并所有配置生成主 config.json
merge_configs() {
    local configs=""
    for conf in "$CONF_DIR"/*.json; do
        if [ -f "$conf" ]; then
            configs="${configs}$(cat "$conf"),"
        fi
    done
    configs="${configs%,}"

    if [ -z "$configs" ]; then
        configs="[]"
    fi

    cat > "$MAIN_CONFIG" <<EOF
{
    "log": {
        "disabled": true,
        "level": "warn"
    },
    "inbounds": [$configs],
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
}

# 创建 systemd 服务
create_systemd_service() {
    cat > "$SERVICE_FILE_SYSTEMD" <<EOF
[Unit]
Description=sing-box service
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$CORE_BIN run -c $MAIN_CONFIG
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# 创建 OpenRC 服务
create_openrc_service() {
    cat > "$SERVICE_FILE_OPENRC" <<'EOF'
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
    sed -i "s|CORE_BIN_PLACEHOLDER|$CORE_BIN|g" "$SERVICE_FILE_OPENRC"
    sed -i "s|CONFIG_JSON_PLACEHOLDER|$MAIN_CONFIG|g" "$SERVICE_FILE_OPENRC"
    chmod +x "$SERVICE_FILE_OPENRC"
}

# 重启服务
restart_service() {
    merge_configs
    if [[ $INIT == "systemd" ]]; then
        systemctl restart sing-box
        sleep 2
        if systemctl is-active --quiet sing-box; then
            ok "服务已重启"
        else
            warn "服务启动失败，请检查配置"
        fi
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box restart
        sleep 2
        if rc-service sing-box status | grep -q "started"; then
            ok "服务已重启"
        else
            warn "服务启动失败，请检查配置"
        fi
    fi
}

# 停止服务
stop_service() {
    if [[ $INIT == "systemd" ]]; then
        systemctl stop sing-box
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box stop
    fi
    ok "服务已停止"
}

# 启动服务
start_service() {
    if [[ $INIT == "systemd" ]]; then
        systemctl start sing-box
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box start
    fi
    ok "服务已启动"
}

# 查看服务状态
status_service() {
    if [[ $INIT == "systemd" ]]; then
        systemctl status sing-box --no-pager
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box status
    fi
}

# 安装主流程
do_install() {
    info "开始安装 sing-box..."
    mkdir -p "$CORE_DIR" "$CONF_DIR" "$LOG_DIR"
    detect_pkg_manager
    install_deps
    get_arch
    detect_init
    install_singbox
    create_alias
    info "请选择要安装的协议 (可多选，空格分隔):"
    echo "  1) VLESS+WS (无 TLS)"
    echo "  2) VLESS+Reality"
    echo "  3) Hysteria2 (端口跳跃)"
    echo "  4) 全部安装"
    read -p "请选择 [1-4，默认1]: " choice

    case $choice in
        2) add_vless_reality ;;
        3) add_hy2 ;;
        4)
            add_vless_ws
            add_vless_reality
            add_hy2
            ;;
        *) add_vless_ws ;;
    esac

    merge_configs
    if [[ $INIT == "systemd" ]]; then
        create_systemd_service
        systemctl enable sing-box
        systemctl start sing-box
        if systemctl is-active --quiet sing-box; then
            ok "服务运行正常"
        else
            warn "服务可能未正常启动，请检查"
        fi
    elif [[ $INIT == "openrc" ]]; then
        create_openrc_service
        rc-update add sing-box default
        rc-service sing-box start
        if rc-service sing-box status | grep -q "started"; then
            ok "服务运行正常"
        else
            warn "服务可能未正常启动，请检查"
        fi
    fi
    echo ""
    info "安装完成！使用 'sb' 命令打开管理菜单"
}

# 卸载 sing-box
do_uninstall() {
    warn "即将卸载 sing-box 及所有配置"
    read -p "确认卸载? [y/N]: " confirm
    [[ $confirm != "y" && $confirm != "Y" ]] && return

    if [[ $INIT == "systemd" ]]; then
        systemctl stop sing-box 2>/dev/null
        systemctl disable sing-box 2>/dev/null
        rm -f "$SERVICE_FILE_SYSTEMD"
        systemctl daemon-reload
    elif [[ $INIT == "openrc" ]]; then
        rc-service sing-box stop 2>/dev/null
        rc-update del sing-box default 2>/dev/null
        rm -f "$SERVICE_FILE_OPENRC"
    fi

    rm -rf "$CORE_DIR"
    ok "sing-box 已卸载"
}

# 查看所有节点
list_nodes() {
    if [ ! -f "$PROTOCOLS_FILE" ]; then
        warn "暂无节点，请先添加协议"
        return
    fi
    echo ""
    echo -e "${CYAN}===== 节点列表 =====${NC}"
    local i=1
    while IFS='|' read -r type remark domain port rest; do
        # 显示端口信息：对于 hy2 显示端口跳跃范围（如果存在第6字段）
        if [[ "$type" == "hy2" ]]; then
            local ports_range=$(echo "$rest" | cut -d'|' -f2)
            [[ -z $ports_range ]] && ports_range="$port"
            echo -e "  $i) ${GREEN}$remark${NC} | $type | $domain | 端口跳跃: $ports_range"
        else
            echo -e "  $i) ${GREEN}$remark${NC} | $type | $domain:$port"
        fi
        ((i++))
    done < "$PROTOCOLS_FILE"
    echo ""
}

# 查看节点详情
show_node_detail() {
    if [ ! -f "$PROTOCOLS_FILE" ]; then
        warn "暂无节点"
        return
    fi
    list_nodes
    read -p "请输入节点编号: " node_num
    local line=$(sed -n "${node_num}p" "$PROTOCOLS_FILE" 2>/dev/null)
    if [ -z "$line" ]; then
        warn "节点不存在"
        return
    fi
    IFS='|' read -r type remark domain port other <<< "$line"
    echo ""
    echo -e "${CYAN}===== 节点详情 =====${NC}"
    echo -e "  名称: ${GREEN}$remark${NC}"
    echo -e "  类型: $type"
    echo -e "  域名: $domain"
    case $type in
        vless-ws)
            IFS='|' read -r _ _ _ _ path uuid <<< "$line"
            echo -e "  端口: $port"
            echo -e "  路径: $path"
            echo -e "  UUID: $uuid"
            ;;
        vless-reality)
            IFS='|' read -r _ _ _ _ uuid private_key public_key short_id <<< "$line"
            echo -e "  端口: $port"
            echo -e "  UUID: $uuid"
            echo -e "  PrivateKey: $private_key"
            echo -e "  PublicKey: $public_key"
            echo -e "  ShortId: $short_id"
            ;;
        hy2)
            IFS='|' read -r _ _ _ start_port password ports_range <<< "$line"
            echo -e "  起始端口: $start_port"
            echo -e "  密码: $password"
            echo -e "  端口跳跃范围: ${ports_range:-$start_port}"
            ;;
    esac
    echo ""
}

# 生成节点分享链接
gen_share_link() {
    if [ ! -f "$PROTOCOLS_FILE" ]; then
        warn "暂无节点"
        return
    fi
    list_nodes
    read -p "请输入节点编号: " node_num
    local line=$(sed -n "${node_num}p" "$PROTOCOLS_FILE" 2>/dev/null)
    if [ -z "$line" ]; then
        warn "节点不存在"
        return
    fi
    IFS='|' read -r type remark domain port rest <<< "$line"

    local link=""
    case $type in
        vless-ws)
            IFS='|' read -r _ _ _ _ path uuid <<< "$line"
            encoded_path=$(echo -n "$path" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g')
            link="vless://$uuid@$domain:$port?encryption=none&security=none&type=ws&path=$encoded_path&host=$domain#$remark"
            ;;
        vless-reality)
            IFS='|' read -r _ _ _ _ uuid _ public_key short_id <<< "$line"
            local server_ip=$(curl -s --max-time 5 ip.sb 2>/dev/null)
            [[ -z $server_ip ]] && server_ip="$domain"
            link="vless://$uuid@$server_ip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain&pbk=$public_key&sid=$short_id#$remark"
            ;;
        hy2)
            IFS='|' read -r _ _ _ start_port password ports_range <<< "$line"
            [[ -z $ports_range ]] && ports_range="$start_port"
            local encoded_ports=$(echo "$ports_range" | sed 's/,/%2C/g')
            link="hysteria2://$password@$domain:$start_port?ports=$encoded_ports#$remark"
            ;;
    esac
    echo ""
    echo -e "${GREEN}分享链接:${NC}"
    echo -e "${CYAN}$link${NC}"
    echo ""
}

# 删除协议
delete_protocol() {
    if [ ! -f "$PROTOCOLS_FILE" ]; then
        warn "暂无节点"
        return
    fi
    list_nodes
    read -p "请输入要删除的节点编号: " node_num
    local line=$(sed -n "${node_num}p" "$PROTOCOLS_FILE" 2>/dev/null)
    if [ -z "$line" ]; then
        warn "节点不存在"
        return
    fi
    IFS='|' read -r type remark domain port rest <<< "$line"

    # 删除协议 JSON 配置文件
    case $type in
        vless-ws) rm -f "$CONF_DIR/vless-ws_${port}.json" ;;
        vless-reality) rm -f "$CONF_DIR/vless-reality_${port}.json" ;;
        hy2) 
            # hy2 的文件名使用起始端口（port 字段）
            rm -f "$CONF_DIR/hy2_${port}.json"
            ;;
    esac

    # 删除链接文件
    rm -f "$CONF_DIR/${remark}_link.txt"

    # 从记录文件中删除
    sed -i "${node_num}d" "$PROTOCOLS_FILE"

    # 重启服务
    restart_service
    ok "节点 [$remark] 已删除"
}

# 主菜单
show_menu() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "         sing-box 管理菜单"
    echo -e "${CYAN}========================================${NC}"
    echo -e "  ${GREEN}1)${NC} 安装 sing-box"
    echo -e "  ${GREEN}2)${NC} 卸载 sing-box"
    echo -e "  ${GREEN}3)${NC} 重启 sing-box"
    echo -e "  ${GREEN}4)${NC} 查看 sing-box 状态"
    echo -e "  ${GREEN}5)${NC} 增加协议"
    echo -e "  ${GREEN}6)${NC} 删除协议"
    echo -e "  ${GREEN}7)${NC} 查看所有节点"
    echo -e "  ${GREEN}8)${NC} 查看节点详情"
    echo -e "  ${GREEN}9)${NC} 生成节点分享链接"
    echo -e "  ${GREEN}0)${NC} 退出脚本"
    echo -e "${CYAN}========================================${NC}"
}

# 增加协议子菜单
add_protocol_menu() {
    echo ""
    echo -e "${CYAN}===== 选择协议 =====${NC}"
    echo -e "  ${GREEN}1)${NC} VLESS+WS (无 TLS)"
    echo -e "  ${GREEN}2)${NC} VLESS+Reality"
    echo -e "  ${GREEN}3)${NC} Hysteria2 (端口跳跃)"
    read -p "请选择 [1-3]: " proto_choice
    case $proto_choice in
        1) add_vless_ws ;;
        2) add_vless_reality ;;
        3) add_hy2 ;;
        *) warn "无效选择" ;;
    esac
    # 如果有服务存在则重启，否则提示安装
    if [[ -f "$CORE_BIN" ]]; then
        restart_service
    else
        warn "sing-box 尚未安装，请先选择选项 1 安装"
    fi
}

# 主入口
main() {
    check_root
    # 检测现有环境
    detect_pkg_manager 2>/dev/null || true
    if [[ -f "$CORE_BIN" ]]; then
        detect_init 2>/dev/null || true
        get_arch 2>/dev/null || true
    fi

    while true; do
        show_menu
        read -p "请输入选项 [0-9]: " opt
        case $opt in
            1) do_install ;;
            2) do_uninstall ;;
            3)
                if [[ -f "$CORE_BIN" ]]; then
                    restart_service
                else
                    warn "sing-box 尚未安装"
                fi
                ;;
            4)
                if [[ -f "$CORE_BIN" ]]; then
                    status_service
                else
                    warn "sing-box 尚未安装"
                fi
                ;;
            5) add_protocol_menu ;;
            6) delete_protocol ;;
            7) list_nodes ;;
            8) show_node_detail ;;
            9) gen_share_link ;;
            0) echo "退出脚本"; exit 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

main "$@"
