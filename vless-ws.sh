#!/usr/bin/env bash

#=================================================
# sing-box 一键安装脚本 (VLESS+WebSocket 无TLS)
# 参考 233boy 设计理念，提供管理功能
# 特性：
#   - 自动检测系统架构，直接下载官方二进制
#   - 交互式配置：域名、端口（随机/自定义）、节点名
#   - 安装后生成 sing-box 或 sb 管理命令
#   - 支持卸载、查看配置、重启服务等
#=================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 检查 root
[[ $EUID -ne 0 ]] && echo -e "${RED}请以 root 权限运行此脚本!${PLAIN}" && exit 1

# 全局变量
SING_BOX_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
MANAGE_CMD="/usr/local/bin/sb"

# 检测架构
get_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        armv6l)  echo "armv6" ;;
        i386|i686) echo "386" ;;
        *)       echo "" ;;
    esac
}

# 检测包管理器
get_package_manager() {
    if command -v apt &>/dev/null; then
        echo "apt"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v apk &>/dev/null; then
        echo "apk"
    else
        echo ""
    fi
}

# 安装依赖工具 (nc, wget, curl等)
install_deps() {
    local pkg_manager=$(get_package_manager)
    if [[ -z "$pkg_manager" ]]; then
        echo -e "${YELLOW}未检测到包管理器，请手动安装 wget, curl, nc 后再运行${PLAIN}"
        exit 1
    fi
    echo -e "${BLUE}==> 安装依赖工具...${PLAIN}"
    case $pkg_manager in
        apt)
            apt update -y
            apt install -y wget curl netcat-openbsd
            ;;
        yum|dnf)
            $pkg_manager install -y wget curl nc
            ;;
        apk)
            apk add --no-cache wget curl netcat-openbsd
            ;;
    esac
}

# 获取未占用端口 (范围 10000-50000)
get_free_port() {
    local port
    local min=10000
    local max=50000
    for i in {1..20}; do
        port=$(( RANDOM % (max - min + 1) + min ))
        # 检测端口是否占用：优先使用 nc, 其次 lsof, 最后检查 /proc/net/tcp
        if command -v nc &>/dev/null; then
            nc -z 127.0.0.1 "$port" &>/dev/null && continue
        elif command -v lsof &>/dev/null; then
            lsof -i :"$port" &>/dev/null && continue
        else
            # 简易检测 /proc/net/tcp
            if [[ -r /proc/net/tcp ]]; then
                local hex_port=$(printf '%04X' "$port")
                if grep -qi ":${hex_port} " /proc/net/tcp; then
                    continue
                fi
            fi
        fi
        echo "$port"
        return
    done
    echo "10086"
}

# 获取公网IP
get_server_ip() {
    local ip
    ip=$(curl -s4m8 ip.sb 2>/dev/null)
    if [[ -n "$ip" && "$ip" != "0.0.0.0" ]]; then
        echo "$ip"
    else
        ip=$(curl -s6m8 ip.sb 2>/dev/null)
        if [[ -n "$ip" ]]; then
            echo "$ip"
        else
            echo "0.0.0.0"
        fi
    fi
}

# 生成 UUID
generate_uuid() {
    if command -v sing-box &>/dev/null; then
        sing-box generate uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        echo "$(printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x' \
            $((RANDOM % 65535)) $((RANDOM % 65535)) \
            $((RANDOM % 65535)) \
            $((RANDOM % 4095 + 16384)) \
            $((RANDOM % 65535)) \
            $((RANDOM % 65535)) $((RANDOM % 65535)) $((RANDOM % 65535)))"
    fi
}

# 安装 sing-box 二进制
install_singbox_binary() {
    echo -e "${BLUE}==> 下载 sing-box 二进制文件...${PLAIN}"
    local arch=$(get_arch)
    if [[ -z "$arch" ]]; then
        echo -e "${RED}不支持的架构: $(uname -m)${PLAIN}"
        exit 1
    fi
    local tmp_dir=$(mktemp -d)
    cd "$tmp_dir"
    # 获取最新版本号
    local latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
    if [[ -z "$latest_version" ]]; then
        latest_version="v1.13.13"
    fi
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${latest_version}-linux-${arch}.tar.gz"
    echo -e "下载地址: $download_url"
    wget -q --show-progress -O sing-box.tar.gz "$download_url" || {
        echo -e "${RED}下载失败，尝试使用官方脚本安装...${PLAIN}"
        bash <(curl -fsSL https://sing-box.app/install.sh)
        if command -v sing-box &>/dev/null; then
            echo -e "${GREEN}安装成功${PLAIN}"
            cd / && rm -rf "$tmp_dir"
            return
        else
            echo -e "${RED}安装失败${PLAIN}"
            exit 1
        fi
    }
    tar -xzf sing-box.tar.gz
    cp -f "sing-box-${latest_version}-linux-${arch}/sing-box" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    cd / && rm -rf "$tmp_dir"
    echo -e "${GREEN}sing-box 二进制安装完成${PLAIN}"
}

# 生成配置文件
generate_config() {
    local domain="$1"
    local port="$2"
    local uuid="$3"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "/var/log/sing-box.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        {
          "uuid": "${uuid}",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/",
        "headers": {
          "Host": "${domain}"
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
    echo -e "${GREEN}配置文件已生成: $CONFIG_FILE${PLAIN}"
}

# 创建 systemd 服务
create_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_ADMIN
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_ADMIN
ExecStart=${SING_BOX_BIN} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo -e "${GREEN}systemd 服务已创建${PLAIN}"
}

# 启动服务
start_service() {
    systemctl enable sing-box
    systemctl start sing-box
    if systemctl is-active sing-box &>/dev/null; then
        echo -e "${GREEN}sing-box 服务启动成功${PLAIN}"
    else
        echo -e "${RED}服务启动失败，请检查日志: journalctl -u sing-box -n 20${PLAIN}"
        exit 1
    fi
}

# 开启 BBR
enable_bbr() {
    local kernel_ver=$(uname -r | cut -d. -f1,2)
    if [[ $(echo "$kernel_ver >= 4.9" | bc) -eq 1 ]]; then
        local bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
        if [[ "$bbr" != "bbr" ]]; then
            echo -e "${BLUE}==> 开启 BBR...${PLAIN}"
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p &>/dev/null
            echo -e "${GREEN}BBR 已开启${PLAIN}"
        else
            echo -e "${GREEN}BBR 已启用${PLAIN}"
        fi
    else
        echo -e "${YELLOW}内核版本低于 4.9，跳过 BBR 开启${PLAIN}"
    fi
}

# 输出节点信息
print_node_info() {
    local domain="$1"
    local port="$2"
    local uuid="$3"
    local name="$4"
    local ip=$(get_server_ip)
    local vless_link="vless://${uuid}@${ip}:${port}?encryption=none&security=none&type=ws&host=${domain}&path=%2F#${name}"
    
    echo -e "\n${BLUE}========== 节点信息 ==========${PLAIN}"
    echo -e "名称: ${GREEN}${name}${PLAIN}"
    echo -e "协议: VLESS + WebSocket (无TLS)"
    echo -e "地址: ${GREEN}${ip}${PLAIN}"
    echo -e "端口: ${GREEN}${port}${PLAIN}"
    echo -e "UUID: ${GREEN}${uuid}${PLAIN}"
    echo -e "Host: ${GREEN}${domain}${PLAIN}"
    echo -e "路径: ${GREEN}/${PLAIN}"
    echo -e "${BLUE}================================${PLAIN}"
    
    echo -e "\n${GREEN}VLESS 链接:${PLAIN}"
    echo -e "${YELLOW}${vless_link}${PLAIN}"
    
    if command -v qrencode &>/dev/null; then
        echo -e "\n${GREEN}二维码:${PLAIN}"
        qrencode -t ANSIUTF8 "$vless_link"
    fi
    
    # 保存链接到文件
    echo "$vless_link" > /etc/sing-box/vless-link.txt
    echo -e "\n${GREEN}链接已保存至: /etc/sing-box/vless-link.txt${PLAIN}"
}

# 创建管理命令 sb
create_manage_command() {
    cat > "$MANAGE_CMD" <<'EOF'
#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

show_menu() {
    clear
    echo -e "${BLUE}==================================${PLAIN}"
    echo -e "    sing-box 管理脚本"
    echo -e "${BLUE}==================================${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 查看节点信息"
    echo -e " ${GREEN}2.${PLAIN} 重启服务"
    echo -e " ${GREEN}3.${PLAIN} 停止服务"
    echo -e " ${GREEN}4.${PLAIN} 启动服务"
    echo -e " ${GREEN}5.${PLAIN} 查看日志"
    echo -e " ${GREEN}6.${PLAIN} 卸载 sing-box"
    echo -e " ${GREEN}7.${PLAIN} 修改配置（需重启）"
    echo -e " ${GREEN}0.${PLAIN} 退出"
    echo -e "${BLUE}==================================${PLAIN}"
    read -rp "请输入选项: " choice
    case $choice in
        1) cat /etc/sing-box/vless-link.txt 2>/dev/null || echo "未找到节点信息" ;;
        2) systemctl restart sing-box && echo -e "${GREEN}已重启${PLAIN}" ;;
        3) systemctl stop sing-box && echo -e "${GREEN}已停止${PLAIN}" ;;
        4) systemctl start sing-box && echo -e "${GREEN}已启动${PLAIN}" ;;
        5) journalctl -u sing-box -n 30 --no-pager ;;
        6) uninstall ;;
        7) edit_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
    read -rp "按回车继续..." && show_menu
}

uninstall() {
    read -rp "确认卸载 sing-box? (y/n) " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    systemctl stop sing-box
    systemctl disable sing-box
    rm -f /usr/local/bin/sing-box
    rm -f /usr/local/bin/sb
    rm -rf /etc/sing-box
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成${PLAIN}"
    exit 0
}

edit_config() {
    if [[ -n "$EDITOR" ]]; then
        $EDITOR /etc/sing-box/config.json
    elif command -v nano &>/dev/null; then
        nano /etc/sing-box/config.json
    elif command -v vi &>/dev/null; then
        vi /etc/sing-box/config.json
    else
        echo -e "${RED}未找到编辑器，请手动修改 /etc/sing-box/config.json${PLAIN}"
    fi
    read -rp "修改后是否重启服务? (y/n) " restart
    if [[ "$restart" == "y" || "$restart" == "Y" ]]; then
        systemctl restart sing-box
        echo -e "${GREEN}已重启${PLAIN}"
    fi
}

show_menu
EOF
    chmod +x "$MANAGE_CMD"
    echo -e "${GREEN}管理命令已创建: sb${PLAIN}"
}

# 交互式配置输入
interactive_config() {
    echo -e "${BLUE}==================================${PLAIN}"
    echo -e "  sing-box 一键安装脚本 (VLESS+WS)"
    echo -e "  路径固定为 / ，无 TLS"
    echo -e "${BLUE}==================================${PLAIN}\n"
    
    read -rp "请输入域名 (用于 WebSocket Host): " domain
    while [[ -z "$domain" ]]; do
        echo -e "${RED}域名不能为空${PLAIN}"
        read -rp "请输入域名: " domain
    done
    
    read -rp "请输入端口 (直接回车随机生成 10000-50000): " port
    if [[ -z "$port" ]]; then
        port=$(get_free_port)
        echo -e "随机端口: ${GREEN}${port}${PLAIN}"
    else
        echo -e "自定义端口: ${GREEN}${port}${PLAIN}"
    fi
    
    read -rp "请输入节点名称 (默认 VLESS-WS): " name
    [[ -z "$name" ]] && name="VLESS-WS"
    
    uuid=$(generate_uuid)
    echo -e "UUID: ${GREEN}${uuid}${PLAIN}"
    
    echo -e "\n${BLUE}配置确认:${PLAIN}"
    echo -e "域名: ${GREEN}${domain}${PLAIN}"
    echo -e "端口: ${GREEN}${port}${PLAIN}"
    echo -e "节点名: ${GREEN}${name}${PLAIN}"
    read -rp "确认无误继续安装? (y/n) " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
}

# 主流程
main() {
    install_deps
    if [[ ! -f "$SING_BOX_BIN" ]]; then
        install_singbox_binary
    else
        echo -e "${GREEN}检测到已安装 sing-box，跳过二进制下载${PLAIN}"
    fi
    
    interactive_config
    generate_config "$domain" "$port" "$uuid"
    create_systemd_service
    start_service
    enable_bbr
    print_node_info "$domain" "$port" "$uuid" "$name"
    create_manage_command
    
    echo -e "\n${GREEN}安装完成！${PLAIN}"
    echo -e "使用 ${BLUE}sb${PLAIN} 命令管理 sing-box"
    echo -e "节点链接已保存至 ${BLUE}/etc/sing-box/vless-link.txt${PLAIN}"
}

main
