#!/usr/bin/env bash
#===============================================================================
# 名称: sing-box_multi_protocol_install.sh
# 功能: 一键安装 sing-box，支持 VLESS+WS (no TLS)、Hysteria2 (TLS + 端口跳跃)、VLESS+Reality
# 环境: 兼容 systemd / OpenRC，自动适配包管理器
# 用法: bash sing-box_multi_protocol_install.sh
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

error() { echo -e "${RED}错误:${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}警告:${NC} $*"; }
info() { echo -e "${CYAN}>>>${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }

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

# 随机端口生成
random_port() {
    echo $((RANDOM % 40001 + 10000))
}

# 配置交互
get_config() {
    echo ""
    info "请选择要安装的协议:"
    echo "  1) VLESS+WS (无 TLS)"
    echo "  2) Hysteria2 (TLS + 端口跳跃)"
    echo "  3) VLESS+Reality"
    read -p "$(echo -e "${CYAN}请选择 [1/2/3] (默认: 1):${NC} ")" PROTOCOL
    [[ -z $PROTOCOL ]] && PROTOCOL=1

    case $PROTOCOL in
        1)
            PROTOCOL_NAME="VLESS-WS"
            get_vless_ws_config
            ;;
        2)
            PROTOCOL_NAME="Hysteria2"
            get_hysteria2_config
            ;;
        3)
            PROTOCOL_NAME="VLESS-Reality"
            get_vless_reality_config
            ;;
        *)
            error "无效选择"
            ;;
    esac
}

get_vless_ws_config() {
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
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo ""
    ok "配置信息"
    echo "  协议: VLESS+WS (无 TLS)"
    echo "  域名: $DOMAIN"
    echo "  端口: $PORT"
    echo "  路径: $WSPATH"
    echo "  UUID: $UUID"
    echo "  节点名: $REMARK"
}

get_hysteria2_config() {
    read -p "$(echo -e "${CYAN}域名 (用于 TLS, 必填):${NC} ")" DOMAIN
    [[ -z $DOMAIN ]] && error "域名不能为空"
    echo -e "${CYAN}请选择 TLS 证书方式:${NC}"
    echo "  1) 自签名证书"
    echo "  2) ACME 证书 (需要 80 端口可用)"
    read -p "$(echo -e "${CYAN}请选择 [1/2] (默认: 1):${NC} ")" CERT_TYPE
    [[ -z $CERT_TYPE ]] && CERT_TYPE=1

    if [[ $CERT_TYPE == "2" ]]; then
        info "申请 ACME 证书..."
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y socat >/dev/null 2>&1 || true
        curl -s https://get.acme.sh | sh -s email=admin@${DOMAIN} >/dev/null 2>&1
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength ec-256 >/dev/null 2>&1
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
            --key-file "$CORE_DIR/${DOMAIN}.key" \
            --fullchain-file "$CORE_DIR/${DOMAIN}.crt" >/dev/null 2>&1
        TLS_KEY="$CORE_DIR/${DOMAIN}.key"
        TLS_CERT="$CORE_DIR/${DOMAIN}.crt"
    else
        info "生成自签名证书..."
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$CORE_DIR/${DOMAIN}.key" -out "$CORE_DIR/${DOMAIN}.crt" \
            -subj "/CN=$DOMAIN" -days 3650 >/dev/null 2>&1
        TLS_KEY="$CORE_DIR/${DOMAIN}.key"
        TLS_CERT="$CORE_DIR/${DOMAIN}.crt"
    fi

    read -p "$(echo -e "${CYAN}监听端口 (必填):${NC} ")" MAIN_PORT
    [[ -z $MAIN_PORT ]] && error "端口不能为空"
    echo -e "${CYAN}请输入端口跳跃范围 (可多个, 用逗号或短横分隔, 如: 10000-20000,30000-40000):${NC}"
    read -p "$(echo -e "${CYAN}端口跳跃范围 (可选, 直接回车跳过):${NC} ")" HOP_PORTS
    if [[ -n $HOP_PORTS ]]; then
        HOP_JSON=$(echo "$HOP_PORTS" | awk -F',' '{
            first=1;
            printf "[";
            for(i=1;i<=NF;i++){
                gsub(/^[ \t]+|[ \t]+$/, "", $i);
                if($i ~ /-/){
                    split($i, range, "-");
                    start=range[1];
                    end=range[2];
                    if(first){first=0}else{printf ","}
                    printf "\"%d-%d\"", start, end;
                } else {
                    if(first){first=0}else{printf ","}
                    printf "\"%s\"", $i;
                }
            }
            printf "]";
        }')
    else
        HOP_JSON="[]"
    fi
    PASSWORD=$(cat /proc/sys/kernel/random/uuid)
    read -p "$(echo -e "${CYAN}节点名称 (默认 Hysteria2):${NC} ")" REMARK
    [[ -z $REMARK ]] && REMARK="Hysteria2"
    echo ""
    ok "配置信息"
    echo "  协议: Hysteria2"
    echo "  域名: $DOMAIN"
    echo "  主端口: $MAIN_PORT"
    echo "  端口跳跃范围: $HOP_PORTS"
    echo "  密码: $PASSWORD"
    echo "  节点名: $REMARK"
}

get_vless_reality_config() {
    read -p "$(echo -e "${CYAN}SNI 伪装域名 (例如 www.microsoft.com, 必填):${NC} ")" SNI
    [[ -z $SNI ]] && error "SNI 不能为空"
    read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" PORT
    if [[ -z $PORT ]]; then
        PORT=$(random_port)
        ok "随机端口: $PORT"
    fi
    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 8)
    read -p "$(echo -e "${CYAN}节点名称 (默认 VLESS-Reality):${NC} ")" REMARK
    [[ -z $REMARK ]] && REMARK="VLESS-Reality"
    echo ""
    ok "配置信息"
    echo "  协议: VLESS+Reality"
    echo "  SNI: $SNI"
    echo "  端口: $PORT"
    echo "  UUID: $UUID"
    echo "  公钥: $PUBLIC_KEY"
    echo "  ShortId: $SHORT_ID"
    echo "  节点名: $REMARK"
}

write_config() {
    case $PROTOCOL in
        1) write_vless_ws_config ;;
        2) write_hysteria2_config ;;
        3) write_vless_reality_config ;;
    esac
}

write_vless_ws_config() {
    cat > "$CONFIG_JSON" <<EOF
{
  "log": {
    "disabled": true,
    "level": "warn",
    "output": "/dev/null"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
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
        "path": "$WSPATH",
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
    }
  ]
}
EOF
    ok "配置文件已生成: $CONFIG_JSON"
}

write_hysteria2_config() {
    cat > "$CONFIG_JSON" <<EOF
{
  "log": {
    "disabled": true,
    "level": "warn",
    "output": "/dev/null"
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $MAIN_PORT,
      "listen_ports": $HOP_JSON,
      "users": [
        {
          "password": "$PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "key_path": "$TLS_KEY",
        "certificate_path": "$TLS_CERT"
      },
      "masquerade": "https://www.bing.com"
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

write_vless_reality_config() {
    cat > "$CONFIG_JSON" <<EOF
{
  "log": {
    "disabled": true,
    "level": "warn",
    "output": "/dev/null"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
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
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
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

create_service() {
    if [[ $INIT == "systemd" ]]; then
        cat > /lib/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=$CORE_BIN run -c $CONFIG_JSON
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl restart sing-box
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

output_link() {
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN} 客户端链接 ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    case $PROTOCOL in
        1) output_vless_ws_link ;;
        2) output_hysteria2_link ;;
        3) output_vless_reality_link ;;
    esac
    echo ""
}

output_vless_ws_link() {
    encoded_path=$(echo -n "$WSPATH" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g')
    vless_link="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=none&type=ws&host=$DOMAIN&path=$encoded_path#$REMARK"
    echo -e "${CYAN}$vless_link${NC}"
    echo -e "\n${YELLOW}提示: 复制上述链接到客户端即可使用${NC}"
}

output_hysteria2_link() {
    hysteria2_link="hysteria2://$PASSWORD@$DOMAIN:$MAIN_PORT?insecure=1&sni=$DOMAIN#$REMARK"
    echo -e "${CYAN}$hysteria2_link${NC}"
    echo -e "\n${YELLOW}提示: 复制上述链接到客户端即可使用${NC}"
    if [[ -n $HOP_PORTS ]]; then
        warn "注意: 端口跳跃需要客户端支持，请确保客户端配置了相同端口范围"
    fi
}

output_vless_reality_link() {
    encoded_remark=$(echo -n "$REMARK" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g')
    vless_link="vless://$UUID@$SNI:$PORT?encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#$encoded_remark"
    echo -e "${CYAN}$vless_link${NC}"
    echo -e "\n${YELLOW}提示: 复制上述链接到客户端即可使用${NC}"
}

main() {
    [[ $EUID -ne 0 ]] && error "请以 root 用户执行（使用 sudo -i）"
    detect_pkg_manager
    install_deps
    get_arch
    detect_init
    install_singbox
    get_config
    write_config
    create_service
    output_link
}

main "$@"
