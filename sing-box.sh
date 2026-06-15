#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box_multi_protocol_install.sh
# 功能: 一键安装 sing-box，配置 VLESS+WS (无TLS) + Hysteria2 (TLS+端口跳跃) + VLESS+Reality
# 环境: 兼容 systemd / OpenRC，自动适配包管理器，支持 LXC 等轻量容器
# 用法: bash sing-box_multi_protocol_install.sh
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 辅助函数
error() { echo -e "${RED}错误:${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}警告:${NC} $*"; }
info() { echo -e "${CYAN}>>>${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }

#===============================================================================
# 检测系统环境
#===============================================================================

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
        error "不支持的包管理器，请手动安装 wget、tar、curl、openssl"
    fi
}

# 安装必要工具
install_deps() {
    local deps="wget tar curl openssl"
    case $PKG_MANAGER in
        apk)
            $INSTALL_CMD $deps bash
            $INSTALL_CMD gcompat  # 添加 gcompat 解决 glibc 兼容性问题
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
    command -v openssl &>/dev/null || error "openssl 安装失败"
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
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            error "不支持的系统架构: $(uname -m)"
            ;;
    esac
    ok "系统架构: $ARCH"
}

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请以 root 权限运行此脚本"
    fi
}

#===============================================================================
# 获取用户自定义输入
#===============================================================================

# 获取服务器 IP
get_server_ip() {
    SERVER_IP=$(curl -s -4 ip.sb 2>/dev/null)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null)
    fi
    if [[ -z "$SERVER_IP" ]]; then
        error "无法获取服务器 IPv4 地址"
    fi
    ok "服务器 IP: $SERVER_IP"
}

# 获取域名 (用于 VLESS+WS Host 和 Reality SNI)
get_domain() {
    read -p "$(echo -e "${CYAN}请输入域名 (用于 VLESS+WS Host 和 Reality SNI):${NC} ")" DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        error "域名不能为空，请重新运行脚本并输入域名"
    fi
    ok "域名: $DOMAIN"
}

# 获取 VLESS+WS 端口
get_vless_ws_port() {
    read -p "$(echo -e "${CYAN}请输入 VLESS+WS 端口 (回车随机 10000-50000):${NC} ")" VLESS_WS_PORT_INPUT
    if [[ -z "$VLESS_WS_PORT_INPUT" ]]; then
        VLESS_WS_PORT=$(shuf -i 10000-50000 -n 1)
    else
        VLESS_WS_PORT="$VLESS_WS_PORT_INPUT"
    fi
    ok "VLESS+WS 端口: $VLESS_WS_PORT"
}

# 获取 VLESS+WS 路径
get_vless_ws_path() {
    read -p "$(echo -e "${CYAN}请输入 VLESS+WS 路径 (默认 /):${NC} ")" VLESS_WS_PATH_INPUT
    if [[ -z "$VLESS_WS_PATH_INPUT" ]]; then
        VLESS_WS_PATH="/"
    else
        # 确保路径以 / 开头
        if [[ "$VLESS_WS_PATH_INPUT" != /* ]]; then
            VLESS_WS_PATH="/$VLESS_WS_PATH_INPUT"
        else
            VLESS_WS_PATH="$VLESS_WS_PATH_INPUT"
        fi
    fi
    ok "VLESS+WS 路径: $VLESS_WS_PATH"
}

# 获取 Hysteria2 端口范围
get_hysteria2_ports() {
    read -p "$(echo -e "${CYAN}请输入 Hysteria2 端口跳跃范围 (格式: 起始-结束, 例如 10000-50000, 回车随机):${NC} ")" HY2_PORTS_INPUT
    if [[ -z "$HY2_PORTS_INPUT" ]]; then
        START_PORT=$(shuf -i 10000-40000 -n 1)
        END_PORT=$((START_PORT + 1000))
        HY2_PORTS="${START_PORT}-${END_PORT}"
    else
        HY2_PORTS="$HY2_PORTS_INPUT"
    fi
    ok "Hysteria2 端口范围: $HY2_PORTS"
}

# 获取 VLESS Reality 端口
get_vless_reality_port() {
    read -p "$(echo -e "${CYAN}请输入 VLESS Reality 端口 (回车随机 10000-50000):${NC} ")" VLESS_REALITY_PORT_INPUT
    if [[ -z "$VLESS_REALITY_PORT_INPUT" ]]; then
        VLESS_REALITY_PORT=$(shuf -i 10000-50000 -n 1)
    else
        VLESS_REALITY_PORT="$VLESS_REALITY_PORT_INPUT"
    fi
    ok "VLESS Reality 端口: $VLESS_REALITY_PORT"
}

# 获取节点名称
get_node_names() {
    read -p "$(echo -e "${CYAN}请输入 VLESS+WS 节点名称 (默认 VLESS-WS):${NC} ")" NODE_NAME_WS
    [[ -z "$NODE_NAME_WS" ]] && NODE_NAME_WS="VLESS-WS"
    read -p "$(echo -e "${CYAN}请输入 Hysteria2 节点名称 (默认 Hysteria2):${NC} ")" NODE_NAME_HY2
    [[ -z "$NODE_NAME_HY2" ]] && NODE_NAME_HY2="Hysteria2"
    read -p "$(echo -e "${CYAN}请输入 VLESS Reality 节点名称 (默认 VLESS-Reality):${NC} ")" NODE_NAME_REALITY
    [[ -z "$NODE_NAME_REALITY" ]] && NODE_NAME_REALITY="VLESS-Reality"
}

#===============================================================================
# 安装 sing-box
#===============================================================================

install_singbox() {
    info "正在安装 sing-box..."
    
    # 创建必要目录
    mkdir -p /etc/sing-box /usr/local/etc/sing-box
    cd /etc/sing-box
    
    # 获取最新版本号
    local latest_url
    latest_url=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    if [[ -z "$latest_url" ]]; then
        latest_url="v1.12.1"
        warn "无法获取最新版本，使用默认版本: $latest_url"
    fi
    
    local version=${latest_url#v}
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_url}/sing-box-${version}-linux-${ARCH}.tar.gz"
    
    # 下载并解压
    info "下载地址: $download_url"
    wget -q --show-progress "$download_url" -O sing-box.tar.gz || error "下载 sing-box 失败"
    tar -xzf sing-box.tar.gz
    cp "sing-box-${version}-linux-${ARCH}/sing-box" /usr/local/bin/ || error "复制二进制文件失败"
    chmod +x /usr/local/bin/sing-box
    
    # 验证安装
    if ! /usr/local/bin/sing-box version &>/dev/null; then
        error "sing-box 安装验证失败"
    fi
    
    # 清理
    rm -rf "sing-box-${version}-linux-${ARCH}" sing-box.tar.gz
    
    ok "sing-box 安装完成: $(/usr/local/bin/sing-box version | head -1)"
}

#===============================================================================
# 生成密钥和配置
#===============================================================================

# 生成 UUID
generate_uuid() {
    if command -v sing-box &>/dev/null; then
        UUID_WS=$(sing-box generate uuid)
        UUID_REALITY=$(sing-box generate uuid)
    else
        # 使用 OpenSSL 生成 UUID
        UUID_WS=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-9a-f-\1\2\3\4\5\6\7\8/')
        UUID_REALITY=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-9a-f-\1\2\3\4\5\6\7\8/')
    fi
}

# 生成 Reality 密钥对
generate_reality_keys() {
    if command -v sing-box &>/dev/null; then
        REALITY_KEYPAIR=$(sing-box generate reality-keypair)
        REALITY_PRIVATE_KEY=$(echo "$REALITY_KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
        REALITY_PUBLIC_KEY=$(echo "$REALITY_KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    else
        error "无法生成 Reality 密钥对，请确保 sing-box 已安装"
    fi
}

# 生成 Hysteria2 密码
generate_hy2_password() {
    HY2_PASSWORD=$(sing-box generate password 2>/dev/null || openssl rand -base64 16)
}

# 生成自签名证书 (用于 Hysteria2)
generate_self_signed_cert() {
    local cert_dir="/etc/sing-box/certs"
    mkdir -p "$cert_dir"
    
    # 生成私钥
    openssl genrsa -out "$cert_dir/private.key" 2048 2>/dev/null
    if [[ $? -ne 0 || ! -f "$cert_dir/private.key" ]]; then
        error "生成私钥失败，请检查 openssl 是否正常工作"
    fi
    
    # 生成自签名证书
    openssl req -new -x509 -days 3650 -key "$cert_dir/private.key" -out "$cert_dir/cert.crt" -subj "/CN=$DOMAIN" 2>/dev/null
    if [[ $? -ne 0 || ! -f "$cert_dir/cert.crt" ]]; then
        error "生成证书失败"
    fi
    
    ok "自签名证书已生成"
}

#===============================================================================
# 创建配置文件
#===============================================================================

create_config() {
    info "正在生成配置文件..."
    
    # 解码 URL 编码的路径
    ENCODED_PATH=$(printf "%s" "$VLESS_WS_PATH" | sed 's/\//%2F/g')
    
    cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "disabled": true,
    "level": "info",
    "output": "/dev/null",
    "timestamp": false
  },
  "dns": {
    "servers": [
      {
        "tag": "cloudflare",
        "address": "1.1.1.1"
      }
    ]
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "::",
      "listen_port": $VLESS_WS_PORT,
      "users": [
        {
          "uuid": "$UUID_WS",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$VLESS_WS_PATH",
        "headers": {
          "Host": "$DOMAIN"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "server_ports": ["$HY2_PORTS"],
      "hop_interval": "30s",
      "users": [
        {
          "password": "$HY2_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "/etc/sing-box/certs/cert.crt",
        "key_path": "/etc/sing-box/certs/private.key"
      }
    },
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": $VLESS_REALITY_PORT,
      "users": [
        {
          "uuid": "$UUID_REALITY",
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
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": [
            "6ba85179e30d4fc2"
          ]
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
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ]
}
EOF
    
    ok "配置文件已生成: /etc/sing-box/config.json"
}

#===============================================================================
# 创建 systemd / OpenRC 服务
#===============================================================================

create_service() {
    info "正在创建服务..."
    
    if [ "$INIT" = "systemd" ]; then
        cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        ok "systemd 服务已创建并启用开机自启"
        
    elif [ "$INIT" = "openrc" ]; then
        cat > /etc/init.d/sing-box << EOF
#!/sbin/openrc-run
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_user="root"
pidfile="/run/sing-box.pid"
command_background=true

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        ok "OpenRC 服务已创建并启用开机自启"
    fi
}

#===============================================================================
# 启动服务
#===============================================================================

start_service() {
    info "正在启动 sing-box 服务..."
    
    if [ "$INIT" = "systemd" ]; then
        systemctl start sing-box
        sleep 2
        if systemctl is-active --quiet sing-box; then
            ok "sing-box 服务已启动"
        else
            error "sing-box 服务启动失败，请检查配置"
        fi
    elif [ "$INIT" = "openrc" ]; then
        rc-service sing-box start
        sleep 2
        if rc-service sing-box status | grep -q "started"; then
            ok "sing-box 服务已启动"
        else
            error "sing-box 服务启动失败，请检查配置"
        fi
    fi
}

#===============================================================================
# 生成并输出节点链接
#===============================================================================

generate_links() {
    info "正在生成节点链接..."
    
    # 1. VLESS+WS 链接
    # 格式: vless://UUID@IP:PORT?encryption=none&type=ws&host=DOMAIN&path=ENCODED_PATH#节点名称
    VLESS_WS_LINK="vless://$UUID_WS@$SERVER_IP:$VLESS_WS_PORT?encryption=none&type=ws&host=$DOMAIN&path=$ENCODED_PATH#$NODE_NAME_WS"
    
    # 2. Hysteria2 链接
    # 格式: hysteria2://PASSWORD@IP:PORT?insecure=1&sni=DOMAIN&mport=PORT-RANGE#节点名称
    # 提取端口范围的第一个和最后一个端口
    HY2_START_PORT=$(echo "$HY2_PORTS" | cut -d'-' -f1)
    HY2_END_PORT=$(echo "$HY2_PORTS" | cut -d'-' -f2)
    HY2_LINK="hysteria2://$HY2_PASSWORD@$SERVER_IP:$HY2_START_PORT?insecure=1&sni=$DOMAIN&mport=$HY2_START_PORT-$HY2_END_PORT#$NODE_NAME_HY2"
    
    # 3. VLESS Reality 链接
    # 格式: vless://UUID@IP:PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=DOMAIN&fp=chrome&pbk=PUBLIC_KEY&sid=6ba85179e30d4fc2#节点名称
    VLESS_REALITY_LINK="vless://$UUID_REALITY@$SERVER_IP:$VLESS_REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=6ba85179e30d4fc2#$NODE_NAME_REALITY"
    
    # 输出链接
    echo ""
    echo "================================================================================"
    echo -e "${GREEN}节点链接已生成，请直接复制使用：${NC}"
    echo "================================================================================"
    echo ""
    echo -e "${CYAN}1. VLESS+WS (无 TLS)${NC}"
    echo -e "${YELLOW}$VLESS_WS_LINK${NC}"
    echo ""
    echo -e "${CYAN}2. Hysteria2 (TLS + 端口跳跃)${NC}"
    echo -e "${YELLOW}$HY2_LINK${NC}"
    echo ""
    echo -e "${CYAN}3. VLESS Reality${NC}"
    echo -e "${YELLOW}$VLESS_REALITY_LINK${NC}"
    echo ""
    echo "================================================================================"
    echo -e "${GREEN}安装完成！以上链接可直接导入 v2rayN、Nekobox、sing-box 等客户端使用${NC}"
    echo "================================================================================"
}

#===============================================================================
# 主函数
#===============================================================================

main() {
    echo "================================================================================"
    echo -e "${CYAN}Sing-box 多协议一键安装脚本${NC}"
    echo "协议: VLESS+WS (无TLS) + Hysteria2 (TLS+端口跳跃) + VLESS+Reality"
    echo "================================================================================"
    
    check_root
    detect_pkg_manager
    install_deps
    detect_init
    get_arch
    
    get_server_ip
    get_domain
    get_vless_ws_port
    get_vless_ws_path
    get_hysteria2_ports
    get_vless_reality_port
    get_node_names
    
    install_singbox
    generate_uuid
    generate_hy2_password
    generate_reality_keys
    generate_self_signed_cert
    create_config
    create_service
    start_service
    generate_links
}

main "$@"
