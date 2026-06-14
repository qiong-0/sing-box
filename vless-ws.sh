#!/usr/bin/env bash
# =====================================================
# Sing-box VLESS-WS (No TLS) 一键安装脚本
# 参考项目: https://github.com/233boy/sing-box
# 特性: 全系兼容, LXC/容器友好, 纯净无依赖
# =====================================================

set -euo pipefail

# ---------- 全局变量 & 颜色 ----------
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; PLAIN='\033[0m'
WORK_DIR="/etc/sing-box"
BIN_DIR="/usr/local/bin"
SERVICE_NAME="sing-box"
CONFIG_FILE="${WORK_DIR}/config.json"
LOG_FILE="${WORK_DIR}/sing-box.log"
PID_FILE="${WORK_DIR}/sing-box.pid"
START_SCRIPT="${BIN_DIR}/sing-box-start.sh"

# ---------- 基础函数 ----------
log_info() { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
log_error() { echo -e "${RED}[ERROR]${PLAIN} $*"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# ---------- 系统/架构检测 ----------
detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) ARCH="amd64" ;;
        aarch64 | arm64) ARCH="arm64" ;;
        armv7l | armv7) ARCH="armv7" ;;
        s390x) ARCH="s390x" ;;
        ppc64le) ARCH="ppc64le" ;;
        riscv64) ARCH="riscv64" ;;
        *) log_error "不支持的架构: $(uname -m)" ;;
    esac
    log_info "检测架构: ${ARCH}"
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID%%.*}"
    else
        log_error "无法检测操作系统版本"
    fi
    log_info "检测系统: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
}

detect_virt() {
    if command_exists systemd-detect-virt; then
        VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")
    elif [[ -f /proc/cpuinfo ]] && grep -q "container\|lxc\|docker" /proc/cpuinfo; then
        VIRT="lxc"
    elif [[ -d /proc/vz ]]; then
        VIRT="openvz"
    else
        VIRT="none"
    fi
    log_info "虚拟化环境: ${VIRT}"
}

detect_init_system() {
    if [[ -d /run/systemd/system ]] && command_exists systemctl; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="nohup"
    fi
    log_info "初始化系统: ${INIT_SYSTEM}"
}

# ---------- 依赖安装 ----------
install_deps() {
    log_info "安装基础依赖 (curl, wget, jq, unzip, tar, iproute2)..."
    if command_exists apt; then
        apt update -y && apt install -y curl wget jq unzip tar iproute2 ca-certificates grep sed gawk coreutils
    elif command_exists yum; then
        yum install -y epel-release && yum install -y curl wget jq unzip tar iproute ca-certificates grep sed gawk coreutils
    elif command_exists dnf; then
        dnf install -y curl wget jq unzip tar iproute ca-certificates grep sed gawk coreutils
    elif command_exists apk; then
        apk add --no-cache curl wget jq unzip tar iproute2 ca-certificates grep sed gawk coreutils
    elif command_exists pacman; then
        pacman -Sy --noconfirm curl wget jq unzip tar iproute2 ca-certificates grep sed gawk coreutils
    elif command_exists zypper; then
        zypper install -y curl wget jq unzip tar iproute2 ca-certificates grep sed gawk coreutils
    else
        log_warn "未知包管理器，请手动安装: curl wget jq unzip tar iproute2"
    fi
}

# ---------- 获取最新版本 & 下载 ----------
get_latest_version() {
    log_info "获取 sing-box 最新版本..."
    local api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local tag_name
    tag_name=$(curl -fsSL "$api_url" | jq -r '.tag_name // empty')
    if [[ -z "$tag_name" ]]; then
        # 备用: 从 233boy 的 release 列表获取 (如果官方 API 限流)
        tag_name=$(curl -fsSL "https://api.github.com/repos/233boy/sing-box/releases/latest" | jq -r '.tag_name // empty')
    fi
    [[ -z "$tag_name" ]] && log_error "获取版本失败，请检查网络或 GitHub API 限制"
    VERSION="${tag_name#v}"
    log_info "最新版本: v${VERSION}"
}

download_singbox() {
    local url="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
    local tmp_file="/tmp/sing-box.tar.gz"
    
    log_info "下载 sing-box: ${url}"
    curl -fL# --retry 3 -o "$tmp_file" "$url" || log_error "下载失败"
    
    log_info "解压并安装二进制文件..."
    tar -xzf "$tmp_file" -C /tmp/
    mv "/tmp/sing-box-${VERSION}-linux-${ARCH}/sing-box" "${BIN_DIR}/sing-box"
    chmod +x "${BIN_DIR}/sing-box"
    rm -rf "$tmp_file" "/tmp/sing-box-${VERSION}-linux-${ARCH}"
    
    log_info "sing-box 安装完成: $(${BIN_DIR}/sing-box version | head -1)"
}

# ---------- 用户交互配置 ----------
get_user_input() {
    echo -e "\n${BLUE}=== 请输入配置参数 (直接回车使用默认值) ===${PLAIN}"
    
    # 1. 域名 (必填, 用于 Host 头和生成链接)
    while true; do
        read -rp "$(echo -e "请输入域名 (必填, 用于 Host 头和节点链接): ")" DOMAIN
        [[ -n "$DOMAIN" ]] && break
        log_error "域名不能为空！"
    done

    # 2. 端口
    read -rp "$(echo -e "请输入监听端口 [默认: 随机 10000-50000]: ")" PORT
    if [[ -z "$PORT" ]]; then
        PORT=$(shuf -i 10000-50000 -n 1)
        log_info "随机生成端口: ${PORT}"
    elif ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 ]] || [[ "$PORT" -gt 65535 ]]; then
        log_error "端口无效 (1-65535)"
    fi

    # 3. 路径
    read -rp "$(echo -e "请输入 WebSocket 路径 [默认: /]: ")" WS_PATH
    WS_PATH="${WS_PATH:-/}"
    [[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH" # 确保以 / 开头

    # 4. 节点名称/备注
    read -rp "$(echo -e "请输入节点名称/备注 [默认: VLESS-WS]: ")" REMARK
    REMARK="${REMARK:-VLESS-WS}"

    # 5. UUID (自动生成)
    UUID=$(${BIN_DIR}/sing-box generate uuid)
    log_info "UUID 已自动生成: ${UUID}"
}

# ---------- 生成配置文件 ----------
generate_config() {
    log_info "生成配置文件: ${CONFIG_FILE}"
    mkdir -p "$WORK_DIR"
    
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "output": "${LOG_FILE}",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": {
          "Host": "${DOMAIN}"
        },
        "max_early_data": 0,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "sniff": true,
      "sniff_override_destination": true,
      "domain_strategy": "prefer_ipv4"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" },
    { "type": "dns", "tag": "dns-out" }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "ip_is_private": true, "outbound": "block" }
    ],
    "auto_detect_interface": true
  },
  "dns": {
    "servers": [
      { "tag": "google", "address": "tls://8.8.8.8", "detour": "direct" },
      { "tag": "cloudflare", "address": "tls://1.1.1.1", "detour": "direct" }
    ],
    "strategy": "prefer_ipv4"
  }
}
EOF
    log_info "配置文件生成成功"
}

# ---------- 防火墙放行 ----------
open_port() {
    log_info "尝试开放端口 ${PORT}..."
    if command_exists ufw; then
        ufw allow "${PORT}"/tcp >/dev/null 2>&1 && log_info "UFW 已放行 ${PORT}"
    elif command_exists firewall-cmd; then
        firewall-cmd --permanent --add-port="${PORT}"/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1 && log_info "Firewalld 已放行 ${PORT}"
    elif command_exists iptables; then
        iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null
        ip6tables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null
        # 尝试保存规则
        (command_exists netfilter-persistent && netfilter-persistent save) || \
        (command_exists iptables-save && iptables-save > /etc/iptables/rules.v4 2>/dev/null) || true
        log_info "Iptables 已放行 ${PORT} (规则可能不持久化，建议配置持久化)"
    else
        log_warn "未检测到防火墙工具，请手动放行端口 ${PORT}"
    fi
}

# ---------- 服务管理 (核心兼容性逻辑) ----------
create_start_script() {
    log_info "创建启动脚本: ${START_SCRIPT}"
    cat > "$START_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Sing-box 守护进程启动脚本 (兼容无 Systemd 环境)
CONFIG_FILE="/etc/sing-box/config.json"
LOG_FILE="/etc/sing-box/sing-box.log"
PID_FILE="/etc/sing-box/sing-box.pid"
BIN="/usr/local/bin/sing-box"

start() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Sing-box 正在运行 (PID: $(cat "$PID_FILE"))"
        return 0
    fi
    nohup "$BIN" run -c "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Sing-box 启动成功 (PID: $(cat "$PID_FILE"))"
    else
        echo "Sing-box 启动失败，请检查日志: $LOG_FILE"
        rm -f "$PID_FILE"
        return 1
    fi
}

stop() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        kill "$(cat "$PID_FILE")"
        sleep 1
        if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            kill -9 "$(cat "$PID_FILE")"
        fi
        rm -f "$PID_FILE"
        echo "Sing-box 已停止"
    else
        echo "Sing-box 未运行"
    fi
}

status() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Sing-box 正在运行 (PID: $(cat "$PID_FILE"))"
        return 0
    else
        echo "Sing-box 未运行"
        return 1
    fi
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) status ;;
    *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
    chmod +x "$START_SCRIPT"
}

install_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        log_info "配置 Systemd 服务..."
        cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Sing-box VLESS-WS Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORK_DIR}
ExecStart=${BIN_DIR}/sing-box run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
        systemctl restart "${SERVICE_NAME}"
        sleep 2
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            log_info "Systemd 服务启动成功"
        else
            log_error "Systemd 服务启动失败: journalctl -u ${SERVICE_NAME} -n 20"
        fi
    else
        log_info "检测到无 Systemd 环境 (LXC/OpenVZ/Docker)，使用 Crontab 守护进程模式..."
        create_start_script
        
        # 启动一次
        "$START_SCRIPT" start
        
        # 写入 Crontab 实现开机自启和崩溃自动重启 (每分钟检查)
        (crontab -l 2>/dev/null | grep -v "sing-box-start.sh"; echo "* * * * * ${START_SCRIPT} status >/dev/null 2>&1 || ${START_SCRIPT} start") | crontab -
        log_info "已配置 Crontab 守护进程 (每分钟检查存活)"
    fi
}

# ---------- 生成分享链接 ----------
generate_link() {
    local ip
    ip=$(curl -fsSL4 ip.sb 2>/dev/null || curl -fsSL4 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    
    # URL Encode 函数 (纯 Bash 实现)
    url_encode() {
        local str="$1" encoded="" i c
        for ((i=0; i<${#str}; i++)); do
            c="${str:i:1}"
            case "$c" in
                [a-zA-Z0-9.~_-]) encoded+="$c" ;;
                *) printf -v c '%%%02X' "'$c"; encoded+="$c" ;;
            esac
        done
        echo "$encoded"
    }

    local remark_encoded
    remark_encoded=$(url_encode "$REMARK")
    
    # vless://uuid@ip:port?type=ws&host=domain&path=path#remark
    local link="vless://${UUID}@${ip}:${PORT}?type=ws&host=$(url_encode "$DOMAIN")&path=$(url_encode "$WS_PATH")#${remark_encoded}"
    
    echo -e "\n${GREEN}=========================================================${PLAIN}"
    echo -e "${GREEN}           VLESS-WS (No TLS) 安装成功！${PLAIN}"
    echo -e "${GREEN}=========================================================${PLAIN}"
    echo -e "地址:     ${YELLOW}${ip}${PLAIN}"
    echo -e "端口:     ${YELLOW}${PORT}${PLAIN}"
    echo -e "UUID:     ${YELLOW}${UUID}${PLAIN}"
    echo -e "传输层:   ${YELLOW}WebSocket (ws)${PLAIN}"
    echo -e "Host:     ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "Path:     ${YELLOW}${WS_PATH}${PLAIN}"
    echo -e "TLS:      ${YELLOW}关闭 (无 TLS)${PLAIN}"
    echo -e "SNI:      ${YELLOW}无${PLAIN}"
    echo -e "指纹:     ${YELLOW}无 (或 chrome)${PLAIN}"
    echo -e "${GREEN}---------------------------------------------------------${PLAIN}"
    echo -e "分享链接 (可直接导入客户端):"
    echo -e "${BLUE}${link}${PLAIN}"
    echo -e "${GREEN}---------------------------------------------------------${PLAIN}"
    
    # 尝试生成二维码
    if command_exists qrencode; then
        echo -e "二维码:"
        qrencode -t ANSIUTF8 "$link"
    elif command_exists python3; then
        python3 -c "import qrcode, sys; qrcode.make(sys.argv[1]).print_ascii()" "$link" 2>/dev/null || true
    fi
    
    echo -e "${GREEN}=========================================================${PLAIN}"
    echo -e "管理命令: "
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        echo -e "  启动: ${YELLOW}systemctl start ${SERVICE_NAME}${PLAIN}"
        echo -e "  停止: ${YELLOW}systemctl stop ${SERVICE_NAME}${PLAIN}"
        echo -e "  重启: ${YELLOW}systemctl restart ${SERVICE_NAME}${PLAIN}"
        echo -e "  状态: ${YELLOW}systemctl status ${SERVICE_NAME}${PLAIN}"
        echo -e "  日志: ${YELLOW}journalctl -u ${SERVICE_NAME} -f${PLAIN}"
    else
        echo -e "  启动: ${YELLOW}${START_SCRIPT} start${PLAIN}"
        echo -e "  停止: ${YELLOW}${START_SCRIPT} stop${PLAIN}"
        echo -e "  重启: ${YELLOW}${START_SCRIPT} restart${PLAIN}"
        echo -e "  状态: ${YELLOW}${START_SCRIPT} status${PLAIN}"
        echo -e "  日志: ${YELLOW}tail -f ${LOG_FILE}${PLAIN}"
    fi
    echo -e "${GREEN}=========================================================${PLAIN}"
}

# ---------- 卸载函数 ----------
uninstall() {
    log_warn "开始卸载 Sing-box VLESS-WS..."
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop "${SERVICE_NAME}" 2>/dev/null
        systemctl disable "${SERVICE_NAME}" 2>/dev/null
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
    else
        "$START_SCRIPT" stop 2>/dev/null
        crontab -l 2>/dev/null | grep -v "sing-box-start.sh" | crontab -
        rm -f "$START_SCRIPT"
    fi
    rm -f "${BIN_DIR}/sing-box"
    rm -rf "$WORK_DIR"
    log_info "卸载完成"
    exit 0
}

# ---------- 主流程 ----------
main() {
    [[ $EUID -ne 0 ]] && log_error "请使用 root 用户运行"
    
    # 参数解析
    case "${1:-}" in
        uninstall) 
            detect_init_system
            uninstall 
            ;;
        *)
            log_info "开始安装 Sing-box VLESS-WS (No TLS)..."
            detect_arch
            detect_os
            detect_virt
            detect_init_system
            install_deps
            get_latest_version
            download_singbox
            get_user_input
            generate_config
            open_port
            install_service
            generate_link
            ;;
    esac
}

main "$@"
