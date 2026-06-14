#!/bin/bash
# author=vless-ws-script
# github=https://github.com/yourname/sing-box-vless-ws

# ======================== 颜色与样式 ========================
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

_red() { echo -e ${red}$@${none}; }
_yellow() { echo -e ${yellow}$@${none}; }
_green() { echo -e ${green}$@${none}; }
_cyan() { echo -e ${cyan}$@${none}; }
_blue() { echo -e ${blue}$@${none}; }
_red_bg() { echo -e "\e[41m$@${none}"; }

is_err=$(_red_bg 错误!)
err() { echo -e "\n$is_err $@\n" && exit 1; }

# ======================== 系统兼容性检测 ========================
# 检查 root 权限
[[ $EUID != 0 ]] && err "当前非 ${yellow}ROOT 用户，请使用 root 执行此脚本。${none}"

# 检测包管理器 (支持 apt、yum、dnf、zypper、apk)
cmd=$(type -P apt-get || type -P yum || type -P dnf || type -P zypper || type -P apk)
[[ ! $cmd ]] && err "此脚本仅支持 ${yellow}(Ubuntu/Debian/CentOS/RHEL/SUSE/Alpine)${none}。"

# 检测 init 系统 (支持 systemd 和 OpenRC)
is_systemd=$(type -P systemctl)
is_openrc=$(type -P rc-service)
[[ ! $is_systemd && ! $is_openrc ]] && {
    err "此系统缺少 ${yellow}(systemctl 或 rc-service)${none}，请安装 systemd 或确认 OpenRC 已启用。"
}

# 检测架构
case $(uname -m) in
    amd64|x86_64) is_arch=amd64 ;;
    aarch64|arm64) is_arch=arm64 ;;
    *) err "此脚本仅支持 64 位系统 (amd64/aarch64)。" ;;
esac

# 检测 wget
is_wget=$(type -P wget)
[[ ! $is_wget ]] && err "请先安装 ${yellow}wget${none} 后再执行此脚本。"

# ======================== 交互式输入 ========================
clear
echo -e "${cyan}========================================${none}"
echo -e "${green}    VLESS + WebSocket 一键安装脚本    ${none}"
echo -e "${cyan}========================================${none}"
echo ""

# 读取自定义域名
read -p "$(echo -e ${yellow}请输入你的域名 (必填): ${none})" custom_domain
[[ -z $custom_domain ]] && err "域名不能为空，请重新运行脚本。"

# 读取端口 (默认随机 10000-50000)
read -p "$(echo -e ${yellow}请输入监听端口 (直接回车随机 10000-50000): ${none})" user_port
if [[ -z $user_port ]]; then
    user_port=$((RANDOM % (50000 - 10000 + 1) + 10000))
    echo -e "${green}已随机分配端口: $user_port${none}"
fi
# 端口格式校验
[[ ! $user_port =~ ^[0-9]+$ || $user_port -lt 1 || $user_port -gt 65535 ]] && err "端口无效，请输入 1-65535 之间的数字。"

# 读取路径 (默认空)
read -p "$(echo -e ${yellow}请输入 WebSocket 路径 (直接回车默认为空): ${none})" user_path
[[ -z $user_path ]] && user_path="/"

# 节点名称
read -p "$(echo -e ${yellow}请输入节点名称 (直接回车默认 VLESS-WS): ${none})" node_name
[[ -z $node_name ]] && node_name="VLESS-WS"

# ======================== 生成 UUID ========================
if [[ $(type -P uuidgen) ]]; then
    uuid=$(uuidgen -r 2>/dev/null || uuidgen)
else
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
fi
[[ -z $uuid ]] && uuid=$(echo -n $RANDOM$RANDOM$RANDOM | md5sum | sed 's/\(..\)/\1-/g;s/-$//' 2>/dev/null)
[[ -z $uuid ]] && err "无法生成 UUID，请手动安装 uuidgen 或检查系统。"

# ======================== 获取服务器 IP ========================
get_server_ip() {
    local ip
    ip=$(curl -s4 --max-time 5 https://ip.sb 2>/dev/null)
    [[ -z $ip ]] && ip=$(curl -s4 --max-time 5 https://api.ip.sb/ip 2>/dev/null)
    [[ -z $ip ]] && ip=$(curl -s4 --max-time 5 https://icanhazip.com 2>/dev/null)
    [[ -z $ip ]] && ip=$(curl -s6 --max-time 5 https://ip.sb 2>/dev/null)
    [[ -z $ip ]] && ip=$(curl -s6 --max-time 5 https://api.ip.sb/ip 2>/dev/null)
    echo "$ip"
}

server_ip=$(get_server_ip)
[[ -z $server_ip ]] && err "获取服务器 IP 失败，请检查网络连接。"

# ======================== 安装依赖 ========================
echo -e "${yellow}[信息] 正在更新系统并安装必要依赖...${none}"
if [[ $cmd =~ apk ]]; then
    apk update && apk add --no-cache bash curl tar jq
else
    $cmd update -y
    $cmd install -y curl tar jq
fi

# ======================== 下载并安装 sing-box ========================
echo -e "${yellow}[信息] 正在下载并安装 sing-box...${none}"
LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f4)
[[ -z $LATEST_VERSION ]] && LATEST_VERSION="v1.10.4"
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${LATEST_VERSION#v}-linux-${is_arch}.tar.gz"

TMP_DIR=$(mktemp -d)
cd $TMP_DIR
wget --no-check-certificate -q $DOWNLOAD_URL || curl -L -o sing-box.tar.gz $DOWNLOAD_URL
tar -xzf sing-box-*.tar.gz
cp -f sing-box-*/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box

# 验证安装
sing-box version &>/dev/null || err "sing-box 安装失败"

# ======================== 创建配置目录 ========================
mkdir -p /etc/sing-box
mkdir -p /var/log/sing-box

# ======================== 生成 config.json ========================
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",
    "output": "/var/log/sing-box/access.log"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "VLESS-WS-in",
      "listen": "::",
      "listen_port": $user_port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$user_path",
        "headers": {
          "Host": "$custom_domain"
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

# ======================== 创建 systemd/OpenRC 服务 ========================
if [[ $is_systemd ]]; then
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-Box Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
LimitNOFILE=infinity
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
    sleep 2
    systemctl is-active --quiet sing-box || err "sing-box 服务启动失败，请检查日志"
elif [[ $is_openrc ]]; then
    cat > /etc/init.d/sing-box <<'EOF'
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
    rc-service sing-box restart
    sleep 2
    rc-service sing-box status &>/dev/null || err "sing-box 服务启动失败，请检查日志"
fi

# ======================== 生成客户端配置链接 ========================
# VLESS 分享链接格式: vless://UUID@IP:PORT?encryption=none&security=none&type=ws&host=DOMAIN&path=PATH#节点名称
encoded_path=$(echo -n "$user_path" | sed 's/\//%2F/g')
[[ $user_path == "/" ]] && encoded_path="/"
share_link="vless://$uuid@$server_ip:$user_port?encryption=none&security=none&type=ws&host=$custom_domain&path=$encoded_path#$node_name"

# ======================== 输出结果 ========================
echo ""
echo -e "${green}========================================${none}"
echo -e "${green}   🎉 VLESS+WS 节点安装成功！🎉   ${none}"
echo -e "${green}========================================${none}"
echo -e "${yellow}节点名称:${none}    $node_name"
echo -e "${yellow}服务器 IP:${none}   $server_ip"
echo -e "${yellow}端口:${none}        $user_port"
echo -e "${yellow}UUID:${none}        $uuid"
echo -e "${yellow}协议:${none}        vless"
echo -e "${yellow}传输类型:${none}    ws"
echo -e "${yellow}路径:${none}        $user_path"
echo -e "${yellow}域名 (Host):${none} $custom_domain"
echo -e "${yellow}TLS:${none}         无"
echo ""
echo -e "${cyan}---------- 分享链接 (点击导入) ----------${none}"
echo -e "${green}$share_link${none}"
echo ""
echo -e "${cyan}------------ 手动配置信息 ------------${none}"
echo -e "地址: $server_ip"
echo -e "端口: $user_port"
echo -e "用户ID: $uuid"
echo -e "传输协议: ws"
echo -e "主机名 (Host): $custom_domain"
echo -e "路径 (Path): $user_path"
echo -e "底层传输: tcp"
echo -e "TLS: 关闭"
echo ""
echo -e "${green}服务状态:${none} $(systemctl is-active sing-box 2>/dev/null || rc-service sing-box status 2>/dev/null | grep -q 'started' && echo '运行中')"
echo -e "${yellow}管理命令:${none}"
echo "  - 查看日志: journalctl -u sing-box -f (systemd) 或 tail -f /var/log/sing-box/access.log (OpenRC)"
echo "  - 重启服务: systemctl restart sing-box (systemd) 或 rc-service sing-box restart (OpenRC)"
echo "  - 停止服务: systemctl stop sing-box (systemd) 或 rc-service sing-box stop (OpenRC)"
echo ""

# 清理临时文件
cd /
rm -rf $TMP_DIR
