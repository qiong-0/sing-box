#!/bin/bash
# author: VLESS-WS 一键安装脚本
# 功能：一键安装 sing-box 并配置 VLESS + WebSocket 协议（无 TLS）
# 支持自定义域名、端口、路径、节点名称，自动生成 vless:// 链接

# ==================== 颜色定义 ====================
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

_red() { echo -e "${red}$*${none}"; }
_green() { echo -e "${green}$*${none}"; }
_yellow() { echo -e "${yellow}$*${none}"; }
_cyan() { echo -e "${cyan}$*${none}"; }
_blue() { echo -e "${blue}$*${none}"; }
_red_bg() { echo -e "\e[41m$*\e[0m"; }

is_err=$(_red_bg "错误!")
is_warn=$(_red_bg "警告!")

err() { echo -e "\n$is_err $*\n" && exit 1; }
warn() { echo -e "\n$is_warn $*\n"; }

# ==================== 系统检测（兼容 LXC） ====================
# 检查 root 权限
[[ $EUID != 0 ]] && err "当前非 ${yellow}ROOT 用户，请使用 sudo -i 切换到 root 后执行。"

# 检测包管理器（兼容 apt-get / yum / zypper / apk）
cmd=$(type -P apt-get || type -P yum || type -P zypper || type -P apk)
[[ ! $cmd ]] && err "此脚本仅支持 ${yellow}(Ubuntu/Debian/CentOS/SUSE/Alpine)${none}."

# 检测 init 系统（兼容 systemd 和 OpenRC，LXC 容器通常支持）
is_systemd=$(type -P systemctl)
is_openrc=$(type -P rc-service)
[[ ! $is_systemd && ! $is_openrc ]] && err "此系统缺少 ${yellow}(systemctl 或 rc-service)${none}，请安装 systemd 或确认 OpenRC 已启用。"

# 检测系统架构（仅支持 64 位）
case $(uname -m) in
    amd64 | x86_64) is_arch="amd64" ;;
    *aarch64* | *armv8*) is_arch="arm64" ;;
    *) err "此脚本仅支持 64 位系统 (amd64/arm64)..." ;;
esac

# 检测必要工具
_is_wget=$(type -P wget)
_is_curl=$(type -P curl)
if [[ ! $_is_wget && ! $_is_curl ]]; then
    err "请先安装 wget 或 curl"
fi

# 定义路径
is_core="sing-box"
is_core_dir="/etc/$is_core"
is_core_bin="$is_core_dir/bin/$is_core"
is_conf_dir="$is_core_dir/conf"
is_log_dir="/var/log/$is_core"
is_config_json="$is_core_dir/config.json"

# wget 封装（兼容无证书检查）
_wget() {
    if [[ $_is_wget ]]; then
        wget --no-check-certificate "$@"
    else
        curl -Lk "$@"
    fi
}

# ==================== 辅助函数 ====================
msg() { echo -e "$*"; }
get_uuid() { echo "$(cat /proc/sys/kernel/random/uuid)"; }

# 生成随机端口（10000-50000）
get_random_port() {
    echo $((RANDOM % 40001 + 10000))
}

# 获取服务器公网 IP（兼容 IPv4/IPv6）
get_ip() {
    export IP=$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep ip= | cut -d= -f2)
    [[ ! $IP ]] && export IP=$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep ip= | cut -d= -f2)
    [[ ! $IP ]] && {
        # 备用方案：使用 ip 命令
        IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -n1)
        [[ ! $IP ]] && IP=$(ip -6 addr show | grep -oP '(?<=inet6\s)[a-f0-9:]+' | grep -v '^::1' | head -n1)
    }
    [[ ! $IP ]] && IP="无法自动获取，请手动填写"
}

# ==================== 安装 sing-box ====================
install_singbox() {
    _green "\n>>> 正在安装 sing-box ...\n"

    # 创建必要目录
    mkdir -p "$is_core_dir/bin" "$is_conf_dir" "$is_log_dir"

    # 获取最新版本号
    local LATEST_VERSION
    LATEST_VERSION=$(_wget -qO- https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    [[ ! $LATEST_VERSION ]] && LATEST_VERSION="v1.12.1"

    # 下载对应架构的二进制文件
    local DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${LATEST_VERSION#v}-linux-${is_arch}.tar.gz"
    _cyan "下载地址: $DOWNLOAD_URL"

    _wget -O /tmp/sing-box.tar.gz "$DOWNLOAD_URL" || err "下载 sing-box 失败，请检查网络连接"
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/ || err "解压失败"

    # 安装二进制文件
    cp "/tmp/sing-box-${LATEST_VERSION#v}-linux-${is_arch}/sing-box" "$is_core_bin" || err "复制二进制文件失败"
    chmod +x "$is_core_bin"

    # 清理临时文件
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${LATEST_VERSION#v}-linux-${is_arch}"

    # 验证安装
    if [[ -f "$is_core_bin" ]]; then
        _green "sing-box 安装成功: $($is_core_bin version | head -n1)"
    else
        err "sing-box 安装失败"
    fi
}

# ==================== 生成配置文件 ====================
# 交互式获取配置参数
_blue "\n========================================="
_blue "       VLESS + WebSocket 配置向导"
_blue "=========================================\n"

# 1. 域名（必须）
while [[ -z $DOMAIN ]]; do
    read -p "$(_yellow "请输入域名 (必填): ")" DOMAIN
done

# 2. 端口（默认随机 10000-50000）
read -p "$(_yellow "请输入端口 [回车随机 10000-50000]: ")" PORT
if [[ -z $PORT ]]; then
    PORT=$(get_random_port)
    _green "随机端口: $PORT"
fi

# 3. 路径（默认 /）
read -p "$(_yellow "请输入 WebSocket 路径 [默认为 /]: ")" WSPATH
if [[ -z $WSPATH ]]; then
    WSPATH="/"
fi

# 4. 节点名称（默认 VLESS-WS）
read -p "$(_yellow "请输入节点名称 [默认: VLESS-WS]: ")" REMARK
if [[ -z $REMARK ]]; then
    REMARK="VLESS-WS"
fi

# 5. 生成 UUID
UUID=$(get_uuid)

_cyan "\n配置信息："
echo "  域名: $DOMAIN"
echo "  端口: $PORT"
echo "  路径: $WSPATH"
echo "  UUID: $UUID"
echo "  节点名: $REMARK"

# 生成 sing-box 配置文件
_green "\n>>> 正在生成配置文件...\n"

cat > "$is_config_json" <<EOF
{
  "log": {
    "level": "info",
    "output": "$is_log_dir/access.log",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "google",
        "address": "tls://dns.google",
        "detour": "direct"
      },
      {
        "tag": "cloudflare",
        "address": "tls://1.1.1.1",
        "detour": "direct"
      },
      {
        "tag": "local",
        "address": "223.5.5.5",
        "address_resolver": "local",
        "detour": "direct"
      }
    ]
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "VLESS-WS-in",
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
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF

_green "配置文件已生成: $is_config_json"

# ==================== 创建服务（兼容 systemd / OpenRC） ====================
_green "\n>>> 正在创建系统服务...\n"

if [[ $is_systemd ]]; then
    # systemd 服务（兼容 LXC 容器）
    cat > /lib/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Service
After=network.target nss-lookup.target

[Service]
User=root
NoNewPrivileges=true
ExecStart=$is_core_bin run -c $is_config_json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    _green "systemd 服务已创建并启动"

elif [[ $is_openrc ]]; then
    # OpenRC 服务（Alpine 等）
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box proxy service"
command="$is_core_bin"
command_args="run -c $is_config_json"
command_user="root"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true

depend() {
    need net
}
EOF

    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box start
    _green "OpenRC 服务已创建并启动"
fi

# 等待服务启动
sleep 2

# 检查服务状态
if [[ $is_systemd ]]; then
    if systemctl is-active --quiet sing-box; then
        _green "✓ sing-box 服务运行正常"
    else
        warn "sing-box 服务可能未正常启动，请检查日志"
    fi
elif [[ $is_openrc ]]; then
    if rc-service sing-box status | grep -q "started"; then
        _green "✓ sing-box 服务运行正常"
    else
        warn "sing-box 服务可能未正常启动，请检查日志"
    fi
fi

# ==================== 生成 VLESS 链接 ====================
# 获取服务器 IP（备用）
get_ip

# 构建 VLESS 链接格式
# 格式: vless://UUID@域名:端口?encryption=none&security=none&type=ws&host=域名&path=路径#节点名称

# URL 编码路径（处理特殊字符）
ENCODED_PATH=$(echo -n "$WSPATH" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g')

VLESS_LINK="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=none&type=ws&host=$DOMAIN&path=$ENCODED_PATH#$REMARK"

_green "\n========================================="
_green "           安装完成！"
_green "=========================================\n"

_cyan "节点配置信息："
echo "  协议: VLESS + WebSocket (无 TLS)"
echo "  域名: $DOMAIN"
echo "  端口: $PORT"
echo "  路径: $WSPATH"
echo "  UUID: $UUID"
echo "  节点名: $REMARK"

_cyan "\n配置文件路径: $is_config_json"
_cyan "日志路径: $is_log_dir/"

_green "\n========================================="
_green "           VLESS 链接"
_green "=========================================\n"

_cyan "$VLESS_LINK"

_green "\n========================================="
_green "            常用命令"
_green "=========================================\n"

if [[ $is_systemd ]]; then
    echo "  启动服务: systemctl start sing-box"
    echo "  停止服务: systemctl stop sing-box"
    echo "  重启服务: systemctl restart sing-box"
    echo "  查看状态: systemctl status sing-box"
    echo "  查看日志: journalctl -u sing-box -f"
elif [[ $is_openrc ]]; then
    echo "  启动服务: rc-service sing-box start"
    echo "  停止服务: rc-service sing-box stop"
    echo "  重启服务: rc-service sing-box restart"
    echo "  查看状态: rc-service sing-box status"
    echo "  查看日志: cat $is_log_dir/access.log"
fi

echo ""
_cyan "脚本执行完毕！"
