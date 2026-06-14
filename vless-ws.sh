#!/bin/bash
#=========================================
# VLESS+WS (无TLS) 一键安装脚本
# 版本: 1.0.0
# 系统支持: Ubuntu/Debian/CentOS/LXC/OpenVZ
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
SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"
SING_BOX_VERSION="latest"

# 代理配置变量
DOMAIN=""
WS_PATH=""
PORT=""
NODE_NAME=""
UUID=""

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

# 检查系统类型和架构
check_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        error "无法识别当前系统"
    fi
    
    # 检测是否在 LXC/OpenVZ 容器中
    if systemd-detect-virt 2>/dev/null | grep -Eiq "lxc|openvz"; then
        info "检测到容器环境: $(systemd-detect-virt)"
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
    local port=$(shuf -i 10000-50000 -n 1 2>/dev/null || awk -v min=10000 -v max=50000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')
    echo $port
}

# 生成 UUID
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    else
        echo "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx" | sed -e 's/[xy]/$(($RANDOM%16))/g' 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null
    fi
}

# 检查端口是否可用
check_port() {
    if netstat -tuln 2>/dev/null | grep -q ":$1 "; then
        return 1
    fi
    if ss -tuln 2>/dev/null | grep -q ":$1 "; then
        return 1
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

# 安装依赖
install_deps() {
    info "正在安装依赖..."
    if [[ $OS == "ubuntu" ]] || [[ $OS == "debian" ]]; then
        apt update -y
        apt install -y wget curl tar unzip net-tools uuid-runtime
    elif [[ $OS == "centos" ]] || [[ $OS == "rhel" ]] || [[ $OS == "fedora" ]]; then
        yum install -y wget curl tar unzip net-tools uuidgen
    else
        error "不支持的系统: $OS"
    fi
}

# 下载并安装 sing-box
install_sing_box() {
    info "正在下载 sing-box..."
    
    # 获取最新版本号
    if [[ $SING_BOX_VERSION == "latest" ]]; then
        SING_BOX_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    # 下载对应架构的二进制文件
    local DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz"
    
    wget -q --show-progress "$DOWNLOAD_URL" -O /tmp/sing-box.tar.gz || error "下载失败"
    
    cd /tmp
    tar -xzf sing-box.tar.gz
    cp sing-box-*/sing-box $SING_BOX_BIN
    chmod +x $SING_BOX_BIN
    
    # 清理临时文件
    rm -rf /tmp/sing-box*
    
    info "sing-box 安装完成: $($SING_BOX_BIN version 2>/dev/null | head -1)"
}

# 创建配置目录
create_config_dir() {
    mkdir -p $SING_BOX_CONFIG_DIR
}

# 生成 sing-box 配置文件 (VLESS + WS 无 TLS)
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

# 创建 systemd 服务
create_systemd_service() {
    info "正在创建 systemd 服务..."
    
    cat > $SING_BOX_SERVICE << EOF
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
}

# 启动服务
start_service() {
    info "正在启动 sing-box 服务..."
    systemctl restart sing-box
    sleep 2
    
    if systemctl is-active --quiet sing-box; then
        info "sing-box 服务已启动"
    else
        error "sing-box 服务启动失败，请检查日志: journalctl -u sing-box"
    fi
}

# 配置防火墙
configure_firewall() {
    info "正在配置防火墙..."
    
    # 检测防火墙类型并开放端口
    if command -v ufw &>/dev/null && ufw status | grep -q active; then
        ufw allow $PORT/tcp
        info "UFW 防火墙已配置"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=$PORT/tcp
        firewall-cmd --reload
        info "Firewalld 防火墙已配置"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
        # 保存 iptables 规则 (如果支持)
        if command -v iptables-save &>/dev/null; then
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
    # VLESS 链接格式: vless://UUID@域名:端口?encryption=none&type=ws&host=域名&path=路径#节点名称
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
    
    # 保存链接到文件
    echo "$vless_link" > /root/vless-link.txt
    info "分享链接已保存至: /root/vless-link.txt"
}

# 用户交互：获取配置参数
get_user_input() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}VLESS + WebSocket (无 TLS) 一键安装脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    # 获取域名
    while [[ -z "$DOMAIN" ]]; do
        read -p "请输入您的域名 (必填): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            warn "域名不能为空，请输入有效域名"
        fi
    done
    
    # 获取端口 (回车则随机生成)
    read -p "请输入端口 (回车则随机 10000-50000): " PORT
    if [[ -z "$PORT" ]]; then
        PORT=$(get_random_port)
        info "已随机生成端口: $PORT"
    else
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ $PORT -lt 1 ]] || [[ $PORT -gt 65535 ]]; then
            error "端口无效，请输入 1-65535 之间的数字"
        fi
        PORT=$(get_available_port $PORT)
    fi
    
    # 获取 WebSocket 路径 (回车则默认为 "/")
    read -p "请输入 WebSocket 路径 (回车则默认为 /): " WS_PATH
    if [[ -z "$WS_PATH" ]]; then
        WS_PATH="/"
    fi
    # 确保路径以 / 开头
    if [[ ! "$WS_PATH" =~ ^/ ]]; then
        WS_PATH="/$WS_PATH"
    fi
    
    # 获取节点名称 (回车则默认 VLESS-WS)
    read -p "请输入节点名称 (回车则默认 VLESS-WS): " NODE_NAME
    if [[ -z "$NODE_NAME" ]]; then
        NODE_NAME="VLESS-WS"
    fi
    
    # 生成 UUID
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
    create_systemd_service
    configure_firewall
    start_service
    generate_vless_link
    
    echo ""
    info "安装完成！"
    echo -e "${GREEN}畅享高速网络！${NC}"
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: bash $0 [选项]

选项:
    -h, --help          显示此帮助信息
    --uninstall         卸载 sing-box 服务

说明:
    直接运行脚本将进入交互式安装流程
    安装完成后会生成 VLESS 分享链接

示例:
    bash $0
    bash $0 --uninstall
EOF
}

# 卸载函数
uninstall_sing_box() {
    warn "正在卸载 sing-box..."
    
    # 停止服务
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    
    # 删除服务文件
    rm -f $SING_BOX_SERVICE
    systemctl daemon-reload
    
    # 删除二进制文件
    rm -f $SING_BOX_BIN
    
    # 删除配置文件 (备份)
    if [[ -f $SING_BOX_CONFIG ]]; then
        cp $SING_BOX_CONFIG /root/sing-box.config.backup 2>/dev/null || true
        rm -rf $SING_BOX_CONFIG_DIR
    fi
    
    # 删除分享链接文件
    rm -f /root/vless-link.txt
    
    info "卸载完成"
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
