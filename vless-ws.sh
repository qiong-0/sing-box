#!/bin/bash
#=========================================
# VLESS+WS (无TLS) 一键安装脚本
# 版本: 1.1.0
# 系统支持: Ubuntu/Debian/CentOS/Alpine/LXC/OpenVZ
# 功能: 安装 sing-box 并创建 VLESS+WebSocket 配置
#=========================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 变量定义
SING_BOX_CONFIG_DIR="/etc/sing-box"
SING_BOX_CONFIG="${SING_BOX_CONFIG_DIR}/config.json"
SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_SERVICE="/etc/init.d/sing-box"          # 用于 OpenRC
SING_BOX_SYSTEMD_SERVICE="/etc/systemd/system/sing-box.service"
SING_BOX_VERSION="latest"

DOMAIN=""
WS_PATH=""
PORT=""
NODE_NAME=""
UUID=""

USE_SYSTEMD=false
USE_OPENRC=false

#=========================================
# 辅助函数
#=========================================

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 用户执行此脚本"
    fi
}

# 检测系统类型和服务管理器
check_system() {
    # 检测发行版
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    elif [[ -f /etc/alpine-release ]]; then
        OS="alpine"
    else
        error "无法识别当前系统"
    fi
    
    # 检测服务管理器
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null; then
        USE_SYSTEMD=true
        info "检测到 systemd"
    elif [[ -f /sbin/openrc-init ]] || [[ -d /etc/init.d ]]; then
        USE_OPENRC=true
        info "检测到 OpenRC"
    else
        warn "未检测到 systemd 或 OpenRC，将尝试手动管理进程"
    fi
    
    # 检测是否在 LXC/OpenVZ 容器中
    if command -v systemd-detect-virt &>/dev/null; then
        if systemd-detect-virt 2>/dev/null | grep -Eiq "lxc|openvz"; then
            info "检测到容器环境: $(systemd-detect-virt)"
        fi
    elif grep -q "lxc" /proc/1/environ 2>/dev/null; then
        info "检测到 LXC 容器"
    fi
    
    # 检测 CPU 架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="armv7"
            ;;
        i686|i386)
            ARCH="386"
            ;;
        *)
            error "不支持的架构: $ARCH"
            ;;
    esac
    
    info "系统: $OS $VER, 架构: $ARCH"
}

# 生成随机端口 (10000-50000)
get_random_port() {
    if command -v shuf &>/dev/null; then
        shuf -i 10000-50000 -n 1
    else
        awk -v min=10000 -v max=50000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'
    fi
}

# 生成 UUID
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        echo "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx" | sed -e 's/[xy]/$(($RANDOM%16))/g'
    fi
}

# 检查端口是否可用
check_port() {
    if command -v netstat &>/dev/null; then
        netstat -tuln 2>/dev/null | grep -q ":$1 " && return 1
    fi
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -q ":$1 " && return 1
    fi
    # 尝试绑定端口测试
    if command -v nc &>/dev/null; then
        nc -z 127.0.0.1 $1 &>/dev/null && return 1
    fi
    return 0
}

# 获取可用端口
get_available_port() {
    local port=$1
    if check_port $port; then
        echo $port
    else
        warn "端口 $port 已被占用，正在重新生成..."
        local new_port=$(get_random_port)
        get_available_port $new_port
    fi
}

# 安装依赖（兼容 Alpine）
install_deps() {
    info "正在安装依赖..."
    case $OS in
        ubuntu|debian)
            apt update -y
            apt install -y wget curl tar unzip net-tools uuid-runtime
            ;;
        centos|rhel|fedora)
            yum install -y wget curl tar unzip net-tools util-linux
            ;;
        alpine)
            apk update
            apk add --no-cache wget curl tar unzip net-tools util-linux coreutils
            # Alpine 没有单独的 uuidgen，但 /proc/sys/kernel/random/uuid 可用
            ;;
        *)
            error "不支持的系统: $OS"
            ;;
    esac
    info "依赖安装完成"
}

# 下载并安装 sing-box
install_sing_box() {
    info "正在下载 sing-box..."
    
    if [[ $SING_BOX_VERSION == "latest" ]]; then
        SING_BOX_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz"
    
    wget -q --show-progress "$DOWNLOAD_URL" -O /tmp/sing-box.tar.gz || error "下载失败"
    
    cd /tmp
    tar -xzf sing-box.tar.gz
    cp sing-box-*/sing-box $SING_BOX_BIN
    chmod +x $SING_BOX_BIN
    
    rm -rf /tmp/sing-box*
    
    info "sing-box 安装完成: $($SING_BOX_BIN version 2>/dev/null | head -1)"
}

# 创建配置目录
create_config_dir() {
    mkdir -p $SING_BOX_CONFIG_DIR
}

# 生成配置文件
generate_config() {
    info "正在生成配置文件..."
    
    cat > $SING_BOX_CONFIG << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
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
        "path": "$WS_PATH",
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
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
    
    info "配置文件已生成: $SING_BOX_CONFIG"
}

# 创建服务（根据 init 系统）
create_service() {
    if [[ $USE_SYSTEMD == true ]]; then
        info "创建 systemd 服务..."
        cat > $SING_BOX_SYSTEMD_SERVICE << EOF
[Unit]
Description=sing-box universal proxy platform
After=network.target nss-lookup.target
Before=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$SING_BOX_BIN run -c $SING_BOX_CONFIG
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        
    elif [[ $USE_OPENRC == true ]]; then
        info "创建 OpenRC 服务..."
        cat > $SING_BOX_SERVICE << 'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box universal proxy platform"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_user="root"
pidfile="/run/${RC_SVCNAME}.pid"
command_background=true
EOF
        chmod +x $SING_BOX_SERVICE
        rc-update add sing-box default
    else
        warn "未检测到 systemd 或 OpenRC，将创建手动启动脚本"
        cat > /usr/local/bin/sing-box-start << EOF
#!/bin/bash
$SING_BOX_BIN run -c $SING_BOX_CONFIG &
echo \$! > /var/run/sing-box.pid
EOF
        cat > /usr/local/bin/sing-box-stop << EOF
#!/bin/bash
kill \$(cat /var/run/sing-box.pid 2>/dev/null) 2>/dev/null
rm -f /var/run/sing-box.pid
EOF
        chmod +x /usr/local/bin/sing-box-{start,stop}
    fi
}

# 启动服务
start_service() {
    if [[ $USE_SYSTEMD == true ]]; then
        systemctl restart sing-box
        sleep 2
        if systemctl is-active --quiet sing-box; then
            info "sing-box 服务已启动 (systemd)"
        else
            error "sing-box 服务启动失败，请检查: journalctl -u sing-box"
        fi
    elif [[ $USE_OPENRC == true ]]; then
        rc-service sing-box restart
        sleep 2
        if rc-service sing-box status | grep -q started; then
            info "sing-box 服务已启动 (OpenRC)"
        else
            error "sing-box 服务启动失败，请检查: rc-service sing-box status"
        fi
    else
        info "手动启动 sing-box..."
        /usr/local/bin/sing-box-start
        if pgrep -f "sing-box run" >/dev/null; then
            info "sing-box 进程已启动"
        else
            error "sing-box 启动失败"
        fi
    fi
}

# 配置防火墙（兼容 Alpine）
configure_firewall() {
    info "正在配置防火墙..."
    
    # ufw
    if command -v ufw &>/dev/null && ufw status | grep -q active; then
        ufw allow $PORT/tcp
        info "UFW 已配置"
    # firewalld
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port=$PORT/tcp
        firewall-cmd --reload
        info "Firewalld 已配置"
    # iptables (包括 Alpine)
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
        # 保存规则
        if [[ $OS == "alpine" ]]; then
            # Alpine 使用 iptables-save 和 iptables-restore
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
            cat > /etc/local.d/iptables.start << EOF
#!/bin/sh
iptables-restore < /etc/iptables/rules.v4
EOF
            chmod +x /etc/local.d/iptables.start
            rc-update add local default
        elif command -v iptables-save &>/dev/null; then
            if [[ $OS == "ubuntu" ]] || [[ $OS == "debian" ]]; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
        fi
        info "iptables 已配置"
    else
        warn "未检测到防火墙，请手动确保端口 $PORT 已开放"
    fi
}

# 生成 VLESS 分享链接
generate_vless_link() {
    local encoded_path=$(echo -n "$WS_PATH" | sed 's/ /%20/g')
    local vless_link="vless://$UUID@$DOMAIN:$PORT?encryption=none&type=ws&host=$DOMAIN&path=$encoded_path#$NODE_NAME"
    
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}VLESS 分享链接 (请复制):${NC}"
    echo -e "${YELLOW}$vless_link${NC}"
    echo ""
    echo -e "${BLUE}配置信息:${NC}"
    echo -e "  协议: VLESS + WebSocket (无 TLS)"
    echo -e "  地址: $DOMAIN"
    echo -e "  端口: $PORT"
    echo -e "  UUID: $UUID"
    echo -e "  WebSocket 路径: $WS_PATH"
    echo -e "  Host: $DOMAIN"
    echo -e "  节点名称: $NODE_NAME"
    echo -e "${BLUE}========================================${NC}"
    
    echo "$vless_link" > /root/vless-link.txt
    info "分享链接已保存至: /root/vless-link.txt"
}

# 用户交互
get_user_input() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}VLESS + WebSocket (无 TLS) 一键安装脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    while [[ -z "$DOMAIN" ]]; do
        read -p "请输入您的域名 (必填): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            warn "域名不能为空"
        fi
    done
    
    read -p "请输入端口 (回车则随机 10000-50000): " PORT
    if [[ -z "$PORT" ]]; then
        PORT=$(get_random_port)
        info "已随机生成端口: $PORT"
    else
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ $PORT -lt 1 ]] || [[ $PORT -gt 65535 ]]; then
            error "端口无效"
        fi
        PORT=$(get_available_port $PORT)
    fi
    
    read -p "请输入 WebSocket 路径 (回车则默认为 /): " WS_PATH
    if [[ -z "$WS_PATH" ]]; then
        WS_PATH="/"
    fi
    if [[ ! "$WS_PATH" =~ ^/ ]]; then
        WS_PATH="/$WS_PATH"
    fi
    
    read -p "请输入节点名称 (回车则默认 VLESS-WS): " NODE_NAME
    if [[ -z "$NODE_NAME" ]]; then
        NODE_NAME="VLESS-WS"
    fi
    
    UUID=$(generate_uuid)
    info "已生成 UUID: $UUID"
    
    echo ""
    echo -e "${BLUE}配置确认:${NC}"
    echo -e "  域名: $DOMAIN"
    echo -e "  端口: $PORT"
    echo -e "  WebSocket 路径: $WS_PATH"
    echo -e "  节点名称: $NODE_NAME"
    echo -e "  UUID: $UUID"
    echo ""
    read -p "确认以上配置? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        error "用户取消安装"
    fi
}

# 主函数
main() {
    check_root
    check_system
    get_user_input
    install_deps
    install_sing_box
    create_config_dir
    generate_config
    create_service
    configure_firewall
    start_service
    generate_vless_link
    
    echo ""
    info "安装完成！"
    echo -e "${GREEN}畅享高速网络！${NC}"
}

# 卸载函数
uninstall_sing_box() {
    warn "正在卸载 sing-box..."
    
    if [[ $USE_SYSTEMD == true ]]; then
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f $SING_BOX_SYSTEMD_SERVICE
        systemctl daemon-reload
    elif [[ $USE_OPENRC == true ]]; then
        rc-service sing-box stop 2>/dev/null || true
        rc-update del sing-box 2>/dev/null || true
        rm -f $SING_BOX_SERVICE
    else
        /usr/local/bin/sing-box-stop 2>/dev/null || true
        rm -f /usr/local/bin/sing-box-{start,stop}
    fi
    
    rm -f $SING_BOX_BIN
    rm -rf $SING_BOX_CONFIG_DIR
    rm -f /root/vless-link.txt
    
    info "卸载完成"
}

# 帮助信息
show_help() {
    cat << EOF
用法: bash $0 [选项]

选项:
    -h, --help          显示此帮助信息
    --uninstall         卸载 sing-box 服务

说明:
    支持系统: Ubuntu, Debian, CentOS, Alpine, 以及其他 LXC/OpenVZ 容器
    支持 init: systemd, OpenRC, 手动脚本

示例:
    bash $0
    bash $0 --uninstall
EOF
}

# 参数解析
case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
    --uninstall)
        uninstall_sing_box
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo "未知参数: $1"
        show_help
        exit 1
        ;;
esac
