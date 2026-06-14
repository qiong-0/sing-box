#!/usr/bin/env bash

#=============================================
# 一键安装 sing-box (VLESS+WS 无TLS)
# 功能: 交互式配置 VLESS+WebSocket 协议
# 特点: 无TLS、支持自定义域名、自定义端口、路径固定为 /
# 作者: AI Assistant
#=============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 检查是否为 root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}请以 root 权限运行此脚本!${PLAIN}" && exit 1

# 检测系统架构
get_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        armv6l)  echo "armv6" ;;
        i386|i686) echo "386" ;;
        *)       echo "unsupported" ;;
    esac
}

# 生成随机 UUID
generate_uuid() {
    if command -v sing-box &>/dev/null; then
        sing-box generate uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
        if [ $? -ne 0 ]; then
            echo "$(printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x' \
                $((RANDOM % 65535)) $((RANDOM % 65535)) \
                $((RANDOM % 65535)) \
                $((RANDOM % 4095 + 16384)) \
                $((RANDOM % 65535)) \
                $((RANDOM % 65535)) $((RANDOM % 65535)) $((RANDOM % 65535)))"
        fi
    fi
}

# 随机生成未占用端口 (范围: 10000-50000)
get_random_port() {
    local min_port=10000
    local max_port=50000
    local port_range=$((max_port - min_port + 1))
    
    for i in {1..10}; do
        local port=$(( (RANDOM % port_range) + min_port ))
        if ! ss -tuln | grep -q ":$port "; then
            echo "$port"
            return
        fi
    done
    # 若尝试10次后端口仍被占用，返回一个默认值
    echo "10086"
}

# 获取服务器公网 IP
get_server_ip() {
    local ipv4=$(curl -s4m8 ip.sb)
    if [[ -n "$ipv4" ]]; then
        echo "$ipv4"
    else
        echo "0.0.0.0"
    fi
}

# 交互式配置收集
config_input() {
    echo -e "${BLUE}===> 开始配置 VLESS+WS 节点...${PLAIN}\n"

    # 自定义域名
    read -p "请输入域名 (用于 WS Host): " custom_host
    while [[ -z "$custom_host" ]]; do
        echo -e "${RED}域名不能为空！${PLAIN}"
        read -p "请输入域名 (用于 WS Host): " custom_host
    done
    echo -e "域名: ${GREEN}$custom_host${PLAIN}\n"

    # 自定义端口
    read -p "请输入节点端口 (默认随机生成 10000-50000): " input_port
    if [[ -z "$input_port" ]]; then
        server_port=$(get_random_port)
    else
        server_port="$input_port"
    fi
    echo -e "端口: ${GREEN}$server_port${PLAIN}\n"

    # 节点名称
    read -p "请输入节点名称 (默认 VLESS-WS): " node_name
    if [[ -z "$node_name" ]]; then
        node_name="VLESS-WS"
    fi
    echo -e "节点名称: ${GREEN}$node_name${PLAIN}\n"

    # 生成 UUID
    uuid=$(generate_uuid)
    echo -e "UUID: ${GREEN}$uuid${PLAIN}\n"

    # 获取服务器 IP
    server_ip=$(get_server_ip)
    if [[ "$server_ip" == "0.0.0.0" ]]; then
        server_ip=$(curl -s6m8 ip.sb)
    fi
    echo -e "服务器 IP: ${GREEN}$server_ip${PLAIN}\n"

    echo -e "${BLUE}配置确认:${PLAIN}"
    echo -e "协议: ${GREEN}VLESS + WebSocket (无TLS)${PLAIN}"
    echo -e "Host: ${GREEN}$custom_host${PLAIN}"
    echo -e "端口: ${GREEN}$server_port${PLAIN}"
    echo -e "路径: ${GREEN}/ (固定)${PLAIN}"
    echo -e "节点名: ${GREEN}$node_name${PLAIN}"
    echo -e "UUID: ${GREEN}$uuid${PLAIN}"
    echo -e "服务器 IP: ${GREEN}$server_ip${PLAIN}"
    echo ""
    
    read -p "确认以上配置并继续安装? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${RED}安装已取消。${PLAIN}"
        exit 0
    fi
}

# 安装 sing-box
install_singbox() {
    echo -e "${BLUE}===> 开始安装 sing-box...${PLAIN}"

    # 官方安装脚本
    bash <(curl -fsSL https://sing-box.app/install.sh) || {
        echo -e "${RED}sing-box 安装失败，请检查网络。${PLAIN}"
        exit 1
    }

    # 检查 sing-box 是否安装成功
    if ! command -v sing-box &>/dev/null; then
        echo -e "${RED}sing-box 命令未找到，安装失败。${PLAIN}"
        exit 1
    fi

    echo -e "${GREEN}sing-box 安装成功！${PLAIN}"
}

# 生成配置文件和 systemd 服务文件
generate_config() {
    echo -e "${BLUE}===> 生成配置文件...${PLAIN}"

    local config_dir="/etc/sing-box"
    local config_file="${config_dir}/config.json"
    local service_file="/etc/systemd/system/sing-box.service"

    mkdir -p "$config_dir"

    # 写入配置文件
    cat > "$config_file" <<EOF
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
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${server_port},
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
          "Host": "${custom_host}"
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

    # 写入 systemd 服务文件
    cat > "$service_file" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_ADMIN
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_ADMIN
ExecStart=$(which sing-box) run -c ${config_file}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${GREEN}配置文件生成完毕！${PLAIN}"
}

# 启动并启用服务
start_service() {
    echo -e "${BLUE}===> 启动 sing-box 服务...${PLAIN}"
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box

    if systemctl is-active sing-box >/dev/null 2>&1; then
        echo -e "${GREEN}sing-box 启动成功！${PLAIN}"
    else
        echo -e "${RED}sing-box 启动失败，请检查日志。${PLAIN}"
        journalctl -u sing-box -n 10 --no-pager
        exit 1
    fi
}

# 开启 BBR 加速
enable_bbr() {
    local kernel_version=$(uname -r | cut -d. -f1)
    if [[ $kernel_version -ge 4 ]]; then
        echo -e "${BLUE}===> 尝试开启 BBR 加速...${PLAIN}"
        local bbr_status=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
        if [[ "$bbr_status" != "bbr" ]]; then
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
            echo -e "${GREEN}BBR 已开启。${PLAIN}"
        else
            echo -e "${GREEN}BBR 已启用，跳过。${PLAIN}"
        fi
    else
        echo -e "${YELLOW}内核版本低于 4.0，无法开启 BBR。${PLAIN}"
    fi
}

# 输出节点信息
print_node_info() {
    # 生成 VLESS 标准链接
    local vless_link="vless://${uuid}@${server_ip}:${server_port}?encryption=none&security=none&type=ws&host=${custom_host}&path=%2F#${node_name}"
    
    # 生成 Clash 和 sing-box 客户端配置片段
    local clash_config="- name: \"${node_name}\"
  type: vless
  server: ${server_ip}
  port: ${server_port}
  uuid: ${uuid}
  network: ws
  tls: false
  ws-opts:
    path: /
    headers:
      Host: ${custom_host}"
    
    local singbox_config="{
  \"type\": \"vless\",
  \"tag\": \"${node_name}\",
  \"server\": \"${server_ip}\",
  \"server_port\": ${server_port},
  \"uuid\": \"${uuid}\",
  \"tls\": {
    \"enabled\": false
  },
  \"transport\": {
    \"type\": \"ws\",
    \"path\": \"/\",
    \"headers\": {
      \"Host\": \"${custom_host}\"
    }
  }
}"

    echo -e "\n${BLUE}========== 节点配置信息 ==========${PLAIN}"
    echo -e "${GREEN}节点名称:${PLAIN} $node_name"
    echo -e "${GREEN}协议:${PLAIN} VLESS + WebSocket (无TLS)"
    echo -e "${GREEN}地址:${PLAIN} $server_ip"
    echo -e "${GREEN}端口:${PLAIN} $server_port"
    echo -e "${GREEN}UUID:${PLAIN} $uuid"
    echo -e "${GREEN}Host:${PLAIN} $custom_host"
    echo -e "${GREEN}路径:${PLAIN} /"
    echo -e "${BLUE}==================================${PLAIN}"

    echo -e "\n${BLUE}========== 分享链接 ==========${PLAIN}"
    echo -e "${GREEN}VLESS 链接:${PLAIN}"
    echo -e "${YELLOW}${vless_link}${PLAIN}\n"

    # 检查 qrencode 命令是否存在
    if command -v qrencode &>/dev/null; then
        echo -e "${GREEN}二维码 (终端显示):${PLAIN}"
        qrencode -t ANSIUTF8 "$vless_link"
    else
        echo -e "${YELLOW}未安装 qrencode 命令，无法显示二维码。${PLAIN}"
        echo -e "${YELLOW}可通过在线工具生成，或使用命令安装: apt install qrencode (Debian/Ubuntu) 或 yum install qrencode (CentOS)${PLAIN}"
    fi

    echo -e "\n${BLUE}========== 备用配置 ==========${PLAIN}"
    echo -e "${GREEN}Clash 配置片段:${PLAIN}"
    echo -e "${YELLOW}${clash_config}${PLAIN}\n"

    echo -e "${GREEN}sing-box 客户端配置片段:${PLAIN}"
    echo -e "${YELLOW}${singbox_config}${PLAIN}"
    
    echo -e "\n${BLUE}==================================${PLAIN}"
}

# 主控制流程
main() {
    clear
    echo -e "${BLUE}==================================${PLAIN}"
    echo -e " ${GREEN}sing-box 一键安装脚本${PLAIN}"
    echo -e " 协议: ${YELLOW}VLESS + WebSocket (无 TLS)${PLAIN}"
    echo -e " 路径: ${YELLOW}/${PLAIN} (固定)"
    echo -e " 端口: ${YELLOW}随机生成 (10000-50000)${PLAIN}"
    echo -e "${BLUE}==================================${PLAIN}\n"

    config_input
    install_singbox
    generate_config
    start_service
    enable_bbr
    print_node_info

    echo -e "\n${GREEN}安装完成！${PLAIN}"
}

# 执行主流程
main