#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box-manager.sh
# 功能: 一键安装/管理 sing-box，支持 VLESS+WS(无TLS)、Hysteria2(端口跳跃)、VLESS+Reality
# 环境: 兼容 systemd / OpenRC，自动适配包管理器，支持 LXC 容器
# 用法: bash sing-box-manager.sh  （安装后可使用命令 sb 打开管理菜单）
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
SING_BOX_DIR="/etc/sing-box"
CONFIG_MAIN="$SING_BOX_DIR/config.json"
INBOUNDS_DIR="$SING_BOX_DIR/inbounds"
NODES_META="$SING_BOX_DIR/nodes.json"
CORE_BIN="$SING_BOX_DIR/bin/sing-box"
LOG_DIR="/var/log/sing-box"
INIT=""
ARCH=""
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""

#===============================================================================
# 基础环境检测与安装
#===============================================================================

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
        error "不支持的包管理器，请手动安装 wget、tar、curl、jq"
    fi
}

install_deps() {
    local deps="wget tar curl jq"
    info "安装依赖软件包..."
    case $PKG_MANAGER in
        apk)
            $INSTALL_CMD $deps bash gcompat
            ;;
        apt|yum|dnf|zypper)
            $UPDATE_CMD && $INSTALL_CMD $deps
            ;;
    esac
    for cmd in wget tar curl jq; do
        command -v $cmd &>/dev/null || error "$cmd 安装失败"
    done
    ok "依赖安装完成"
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
    if [[ -f "$CORE_BIN" ]]; then
        ok "sing-box 已安装: $($CORE_BIN version | head -n1)"
        return
    fi
    local latest_url
    latest_url=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    [[ -z $latest_url || "$latest_url" == "null" ]] && latest_url="v1.12.1"
    local version=${latest_url#v}
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_url}/sing-box-${version}-linux-${ARCH}.tar.gz"
    info "下载 sing-box: $download_url"
    wget --no-check-certificate -O /tmp/sing-box.tar.gz "$download_url" || error "下载失败"
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/ || error "解压失败"
    mkdir -p "$SING_BOX_DIR/bin" "$INBOUNDS_DIR" "$LOG_DIR"
    cp "/tmp/sing-box-${version}-linux-${ARCH}/sing-box" "$CORE_BIN"
    chmod +x "$CORE_BIN"
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${version}-linux-${ARCH}"
    ok "sing-box 安装完成: $($CORE_BIN version | head -n1)"
}

# 生成主配置文件（不含入站，仅基础 outbound 和 log）
generate_main_config() {
    cat > "$CONFIG_MAIN" <<EOF
{
  "log": {
    "level": "warn",
    "output": "/dev/null",
    "timestamp": false
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    ok "主配置生成: $CONFIG_MAIN"
}

# 创建服务单元
create_service() {
    if [[ -f /lib/systemd/system/sing-box.service ]] || [[ -f /etc/init.d/sing-box ]]; then
        warn "服务已存在，跳过创建"
        return
    fi
    if [[ $INIT == "systemd" ]]; then
        cat > /lib/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$CORE_BIN run -c $CONFIG_MAIN -c $INBOUNDS_DIR
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
command_args="run -c CONFIG_MAIN_PLACEHOLDER -c INBOUNDS_DIR_PLACEHOLDER"
command_user="root"
pidfile="/run/${RC_SVCNAME}.pid"
command_background=true
depend() {
    need net
}
EOF
        sed -i "s|CORE_BIN_PLACEHOLDER|$CORE_BIN|g" /etc/init.d/sing-box
        sed -i "s|CONFIG_MAIN_PLACEHOLDER|$CONFIG_MAIN|g" /etc/init.d/sing-box
        sed -i "s|INBOUNDS_DIR_PLACEHOLDER|$INBOUNDS_DIR|g" /etc/init.d/sing-box
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        rc-service sing-box start
        ok "OpenRC 服务已启动"
    fi
    sleep 2
    check_service_status
}

check_service_status() {
    if [[ $INIT == "systemd" ]]; then
        systemctl is-active --quiet sing-box && ok "服务运行正常" || warn "服务未正常运行，检查日志"
    else
        rc-service sing-box status | grep -q "started" && ok "服务运行正常" || warn "服务未正常运行，检查日志"
    fi
}

restart_service() {
    info "重启 sing-box 服务..."
    if [[ $INIT == "systemd" ]]; then
        systemctl restart sing-box
    else
        rc-service sing-box restart
    fi
    sleep 1
    check_service_status
}

stop_service() {
    info "停止 sing-box 服务..."
    if [[ $INIT == "systemd" ]]; then
        systemctl stop sing-box
    else
        rc-service sing-box stop
    fi
}

uninstall_singbox() {
    warn "即将卸载 sing-box 及所有配置"
    read -p "确认卸载？(y/N): " confirm
    [[ $confirm != "y" && $confirm != "Y" ]] && return
    stop_service
    if [[ $INIT == "systemd" ]]; then
        systemctl disable sing-box
        rm -f /lib/systemd/system/sing-box.service
        systemctl daemon-reload
    else
        rc-update del sing-box
        rm -f /etc/init.d/sing-box
    fi
    rm -rf "$SING_BOX_DIR"
    ok "sing-box 已卸载"
}

#===============================================================================
# 节点管理 (增删改查)
#===============================================================================

# 初始化元数据文件
init_nodes_meta() {
    if [[ ! -f "$NODES_META" ]]; then
        echo '{"nodes": []}' > "$NODES_META"
    fi
}

# 保存节点元信息
save_node_meta() {
    local type=$1 remark=$2 inbound_file=$3 share_link=$4
    local tmp=$(mktemp)
    jq --arg type "$type" \
       --arg remark "$remark" \
       --arg file "$inbound_file" \
       --arg link "$share_link" \
       '.nodes += [{"type": $type, "remark": $remark, "file": $file, "link": $link}]' \
       "$NODES_META" > "$tmp" && mv "$tmp" "$NODES_META"
}

# 删除节点元信息
delete_node_meta_by_file() {
    local file=$1
    local tmp=$(mktemp)
    jq --arg file "$file" 'del(.nodes[] | select(.file == $file))' "$NODES_META" > "$tmp" && mv "$tmp" "$NODES_META"
}

# 列出所有节点简要信息
list_nodes() {
    if [[ ! -s "$NODES_META" ]] || [[ $(jq '.nodes | length' "$NODES_META") -eq 0 ]]; then
        echo "暂无节点"
        return
    fi
    echo "========================================="
    echo "  节点列表"
    echo "========================================="
    jq -r '.nodes | to_entries[] | "\(.key+1). [\(.value.type)] \(.value.remark)"' "$NODES_META"
    echo "========================================="
}

# 生成 VLESS+WS 入站配置
gen_vless_ws() {
    local remark=$1 domain=$2 port=$3 path=$4 uuid=$5
    cat <<EOF
{
  "type": "vless",
  "tag": "$remark",
  "listen": "::",
  "listen_port": $port,
  "users": [{"uuid": "$uuid", "flow": ""}],
  "transport": {
    "type": "ws",
    "path": "$path",
    "headers": {"Host": "$domain"}
  }
}
EOF
}

# 生成 VLESS+Reality 入站配置
gen_vless_reality() {
    local remark=$1 port=$2 dest=$3 server_name=$4 uuid=$5 private_key=$6 public_key=$7 short_id=$8
    cat <<EOF
{
  "type": "vless",
  "tag": "$remark",
  "listen": "::",
  "listen_port": $port,
  "users": [{"uuid": "$uuid", "flow": "xtls-rprx-vision"}],
  "tls": {
    "enabled": true,
    "server_name": "$server_name",
    "reality": {
      "enabled": true,
      "dest": "$dest",
      "private_key": "$private_key",
      "public_key": "$public_key",
      "short_id": "$short_id"
    }
  }
}
EOF
}

# 生成 Hysteria2 入站配置（端口跳跃范围）
gen_hy2() {
    local remark=$1 password=$2 host=$3 start_port=$4 end_port=$5
    cat <<EOF
{
  "type": "hysteria2",
  "tag": "$remark",
  "listen": ":$start_port-$end_port",
  "users": [{"password": "$password"}],
  "tls": {
    "enabled": false
  }
}
EOF
}

# 添加 VLESS+WS 节点
add_vless_ws() {
    echo ""
    info "添加 VLESS+WS (无 TLS) 节点"
    read -p "$(echo -e "${CYAN}域名 (必填):${NC} ")" domain
    [[ -z "$domain" ]] && error "域名不能为空"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" port
    if [[ -z "$port" ]]; then
        port=$((RANDOM % 40001 + 10000))
        ok "随机端口: $port"
    fi
    read -p "$(echo -e "${CYAN}WebSocket 路径 (默认 /):${NC} ")" path
    [[ -z "$path" ]] && path="/"
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-WS):${NC} ")" remark
    [[ -z "$remark" ]] && remark="VLESS-WS"
    uuid=$(cat /proc/sys/kernel/random/uuid)

    local filename="vless_ws_$(date +%s).json"
    local filepath="$INBOUNDS_DIR/$filename"
    gen_vless_ws "$remark" "$domain" "$port" "$path" "$uuid" > "$filepath"
    # 生成分享链接
    local encoded_path=$(echo -n "$path" | jq -sRr @uri)
    local link="vless://$uuid@$domain:$port?encryption=none&security=none&type=ws&host=$domain&path=$encoded_path#$remark"
    save_node_meta "VLESS+WS" "$remark" "$filename" "$link"
    restart_service
    ok "节点添加成功"
    echo -e "${CYAN}分享链接:${NC} $link"
}

# 添加 VLESS+Reality 节点
add_vless_reality() {
    echo ""
    info "添加 VLESS+Reality 节点"
    read -p "$(echo -e "${CYAN}域名/IP (必填):${NC} ")" domain
    [[ -z "$domain" ]] && error "域名/IP 不能为空"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" port
    if [[ -z "$port" ]]; then
        port=$((RANDOM % 40001 + 10000))
        ok "随机端口: $port"
    fi
    read -p "$(echo -e "${CYAN}目标地址 (如 www.microsoft.com:443):${NC} ")" dest
    [[ -z "$dest" ]] && dest="www.microsoft.com:443"
    read -p "$(echo -e "${CYAN}SNI (默认同目标域名):${NC} ")" sni
    [[ -z "$sni" ]] && sni="${dest%:*}"
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-Reality):${NC} ")" remark
    [[ -z "$remark" ]] && remark="VLESS-Reality"
    uuid=$(cat /proc/sys/kernel/random/uuid)
    # 生成 Reality 密钥对
    keypair=$($CORE_BIN generate reality-keypair)
    private_key=$(echo "$keypair" | grep "PrivateKey" | awk '{print $2}')
    public_key=$(echo "$keypair" | grep "PublicKey" | awk '{print $2}')
    short_id=$($CORE_BIN generate rand --hex 8)

    local filename="vless_reality_$(date +%s).json"
    local filepath="$INBOUNDS_DIR/$filename"
    gen_vless_reality "$remark" "$port" "$dest" "$sni" "$uuid" "$private_key" "$public_key" "$short_id" > "$filepath"
    # 生成分享链接
    local link="vless://$uuid@$domain:$port?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=$sni&pbk=$public_key&sid=$short_id#$remark"
    save_node_meta "VLESS+Reality" "$remark" "$filename" "$link"
    restart_service
    ok "节点添加成功"
    echo -e "${CYAN}分享链接:${NC} $link"
}

# 添加 Hysteria2 节点
add_hy2() {
    echo ""
    info "添加 Hysteria2 (端口跳跃) 节点"
    read -p "$(echo -e "${CYAN}域名/IP (必填):${NC} ")" host
    [[ -z "$host" ]] && error "域名/IP 不能为空"
    read -p "$(echo -e "${CYAN}起始端口 (回车随机 10000-50000):${NC} ")" start_port
    if [[ -z "$start_port" ]]; then
        start_port=$((RANDOM % 40001 + 10000))
        ok "随机起始端口: $start_port"
    fi
    read -p "$(echo -e "${CYAN}结束端口 (起始端口 + 100):${NC} ")" end_port
    if [[ -z "$end_port" ]]; then
        end_port=$((start_port + 100))
        ok "随机结束端口: $end_port"
    fi
    read -p "$(echo -e "${CYAN}密码 (回车自动生成):${NC} ")" password
    if [[ -z "$password" ]]; then
        password=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
        ok "自动生成密码: $password"
    fi
    read -p "$(echo -e "${CYAN}节点名称 (默认 Hysteria2):${NC} ")" remark
    [[ -z "$remark" ]] && remark="Hysteria2"

    local filename="hy2_$(date +%s).json"
    local filepath="$INBOUNDS_DIR/$filename"
    gen_hy2 "$remark" "$password" "$host" "$start_port" "$end_port" > "$filepath"
    local link="hysteria2://$password@$host:$start_port?mport=$start_port-$end_port&insecure=1#$remark"
    save_node_meta "Hysteria2" "$remark" "$filename" "$link"
    restart_service
    ok "节点添加成功"
    echo -e "${CYAN}分享链接:${NC} $link"
}

# 删除节点
delete_node() {
    list_nodes
    local total=$(jq '.nodes | length' "$NODES_META")
    if [[ $total -eq 0 ]]; then
        return
    fi
    read -p "请输入要删除的节点编号: " idx
    if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ $idx -lt 1 ]] || [[ $idx -gt $total ]]; then
        error "无效编号"
    fi
    local file=$(jq -r ".nodes[$((idx-1))].file" "$NODES_META")
    rm -f "$INBOUNDS_DIR/$file"
    delete_node_meta_by_file "$file"
    restart_service
    ok "节点删除成功"
}

# 查看节点详情
node_detail() {
    list_nodes
    local total=$(jq '.nodes | length' "$NODES_META")
    if [[ $total -eq 0 ]]; then
        return
    fi
    read -p "请输入要查看的节点编号: " idx
    if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ $idx -lt 1 ]] || [[ $idx -gt $total ]]; then
        error "无效编号"
    fi
    local remark=$(jq -r ".nodes[$((idx-1))].remark" "$NODES_META")
    local type=$(jq -r ".nodes[$((idx-1))].type" "$NODES_META")
    local file=$(jq -r ".nodes[$((idx-1))].file" "$NODES_META")
    local link=$(jq -r ".nodes[$((idx-1))].link" "$NODES_META")
    echo "========================================="
    echo "节点名称: $remark"
    echo "协议类型: $type"
    echo "配置文件: $INBOUNDS_DIR/$file"
    echo "分享链接: $link"
    echo "========================================="
    # 显示原始 json 配置
    echo "完整配置:"
    jq . "$INBOUNDS_DIR/$file"
}

# 生成指定节点的分享链接
gen_share_link() {
    list_nodes
    local total=$(jq '.nodes | length' "$NODES_META")
    if [[ $total -eq 0 ]]; then
        return
    fi
    read -p "请输入要生成链接的节点编号: " idx
    if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ $idx -lt 1 ]] || [[ $idx -gt $total ]]; then
        error "无效编号"
    fi
    local link=$(jq -r ".nodes[$((idx-1))].link" "$NODES_META")
    echo -e "${CYAN}分享链接:${NC} $link"
}

#===============================================================================
# 主菜单
#===============================================================================

menu_install() {
    detect_pkg_manager
    install_deps
    get_arch
    detect_init
    install_singbox
    generate_main_config
    init_nodes_meta
    create_service
    # 创建 /usr/local/bin/sb 快捷命令
    cat > /usr/local/bin/sb <<'EOF'
#!/bin/bash
exec /usr/local/bin/sing-box-manager.sh menu
EOF
    chmod +x /usr/local/bin/sb
    cp "$0" /usr/local/bin/sing-box-manager.sh
    chmod +x /usr/local/bin/sing-box-manager.sh
    ok "安装完成！现在您可以使用命令 'sb' 打开管理菜单"
}

menu_main() {
    while true; do
        echo ""
        echo "========================================="
        echo "       sing-box 管理菜单"
        echo "========================================="
        echo " 1. 安装 sing-box"
        echo " 2. 卸载 sing-box"
        echo " 3. 重启 sing-box"
        echo " 4. 查看 sing-box 状态"
        echo " 5. 增加协议"
        echo " 6. 删除协议"
        echo " 7. 查看所有节点"
        echo " 8. 查看节点详情"
        echo " 9. 生成节点分享链接"
        echo " 0. 退出脚本"
        echo "========================================="
        read -p "请输入选项 [0-9]: " opt
        case $opt in
            1) menu_install ;;
            2) uninstall_singbox ;;
            3) restart_service ;;
            4) check_service_status ;;
            5) menu_add_protocol ;;
            6) delete_node ;;
            7) list_nodes ;;
            8) node_detail ;;
            9) gen_share_link ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

menu_add_protocol() {
    echo ""
    echo "选择协议类型:"
    echo " 1. VLESS+WebSocket (无 TLS)"
    echo " 2. VLESS+Reality"
    echo " 3. Hysteria2 (端口跳跃)"
    read -p "请选择 [1-3]: " proto
    case $proto in
        1) add_vless_ws ;;
        2) add_vless_reality ;;
        3) add_hy2 ;;
        *) error "无效选择" ;;
    esac
}

#===============================================================================
# 入口
#===============================================================================

if [[ $EUID -ne 0 ]]; then
    error "请以 root 用户执行（使用 sudo -i）"
fi

if [[ "$1" == "menu" ]] || [[ -z "$1" ]]; then
    # 确保基础目录存在，避免菜单部分功能出错
    mkdir -p "$SING_BOX_DIR" "$INBOUNDS_DIR" 2>/dev/null || true
    if [[ ! -f "$NODES_META" ]]; then
        init_nodes_meta
    fi
    menu_main
else
    # 直接执行其他函数（可扩展）
    "$@"
fi
