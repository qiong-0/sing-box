#!/usr/bin/env bash

# ----------------------------------------
# Sing-box 一键管理脚本 (修复版)
# 基于 https://github.com/qiong-0/sing-box/blob/main/vless-ws.sh 修复
# 修复内容: 
#   1. 修复 tar: invalid magic / short read 错误
#   2. 兼容 Alpine / LXC 等轻量系统
#   3. 增加下载重试和文件完整性校验
#   4. 使用官方安装脚本优先，确保下载正确的静态编译版本
# ----------------------------------------

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 检测系统类型
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    else
        OS=$(uname -s)
    fi
    echo "$OS"
}

# 检测是否为 Alpine Linux
is_alpine() {
    if [[ "$(detect_os)" == "alpine" ]]; then
        return 0
    else
        return 1
    fi
}

# 安装必要的依赖
install_dependencies() {
    info "检查并安装必要依赖..."
    if is_alpine; then
        # Alpine 系统使用 apk
        apk update
        apk add --no-cache curl wget tar gzip jq openssl coreutils
        # 安装 glibc 兼容层（解决动态链接问题）
        info "Alpine 系统检测到，安装 libc6-compat 兼容层..."
        apk add --no-cache libc6-compat
    elif command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y curl wget tar gzip jq openssl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar gzip jq openssl
    else
        warn "无法识别的包管理器，请手动安装 curl, wget, tar, gzip, jq, openssl"
    fi
    info "依赖安装完成。"
}

# 显示信息
info() {
    echo -e "${GREEN}[信息]${PLAIN} $1"
}

err() {
    echo -e "${RED}[错误]${PLAIN} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[警告]${PLAIN} $1"
}

# 优先使用官方安装脚本
install_with_official_script() {
    info "尝试使用官方安装脚本..."
    if curl -fsSL https://sing-box.app/install.sh | sh -s; then
        info "官方安装脚本执行成功！"
        return 0
    else
        warn "官方安装脚本失败，尝试手动下载..."
        return 1
    fi
}

# 手动下载并安装（带重试和完整性校验）
manual_install() {
    info "开始手动下载安装 sing-box ..."
    
    local arch=$(uname -m)
    local arch_map=""
    case "$arch" in
        x86_64)  arch_map="amd64" ;;
        aarch64) arch_map="arm64" ;;
        armv7l)  arch_map="armv7" ;;
        *)       err "不支持的架构: $arch" ;;
    esac

    # 获取最新版本号
    local latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f4)
    if [[ -z "$latest_version" ]]; then
        err "获取最新版本失败，请检查网络。"
    fi
    info "最新版本: $latest_version"

    # 选择正确的下载文件（优先选择静态编译版本）
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${latest_version}-linux-${arch_map}.tar.gz"
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit

    # 重试下载逻辑
    local max_retries=3
    local retry_count=0
    local download_success=false

    while [[ $retry_count -lt $max_retries ]]; do
        info "下载尝试 $((retry_count+1))/$max_retries"
        # 使用 wget 替代 curl 以获得更好的重试支持
        if wget --tries=3 --timeout=30 --retry-connrefused "$download_url" -O sing-box.tar.gz 2>/dev/null; then
            # 检查下载的文件是否真的是有效的 gzip 文件
            if gzip -t sing-box.tar.gz 2>/dev/null; then
                download_success=true
                break
            else
                warn "下载的文件损坏，重试中..."
                rm -f sing-box.tar.gz
            fi
        else
            warn "下载失败，重试中..."
        fi
        retry_count=$((retry_count + 1))
        sleep 3
    done

    if [[ "$download_success" != true ]]; then
        err "下载失败，请检查网络连接或手动下载安装。"
    fi

    # 解压（兼容 BusyBox tar）
    info "正在解压..."
    if ! gunzip -f sing-box.tar.gz 2>/dev/null; then
        warn "gunzip 失败，尝试使用 tar 直接解压..."
        tar -xzf sing-box.tar.gz 2>/dev/null || {
            err "解压失败，请检查 tar 是否支持 gzip 格式。"
        }
    else
        tar -xf sing-box.tar 2>/dev/null || {
            err "解压失败。"
        }
    fi

    # 拷贝二进制文件
    if [[ -f "sing-box-${latest_version}-linux-${arch_map}/sing-box" ]]; then
        cp "sing-box-${latest_version}-linux-${arch_map}/sing-box" /usr/local/bin/sing-box
    elif [[ -f "./sing-box" ]]; then
        cp ./sing-box /usr/local/bin/sing-box
    else
        err "找不到 sing-box 二进制文件。"
    fi

    chmod +x /usr/local/bin/sing-box
    cd - >/dev/null || exit
    rm -rf "$temp_dir"

    # 验证安装
    if command -v sing-box >/dev/null 2>&1; then
        info "sing-box $(sing-box version 2>&1 | head -n1) 安装成功！"
        return 0
    else
        err "sing-box 安装失败！"
    fi
}

# 主安装流程
main_install() {
    check_root
    install_dependencies
    
    # 优先尝试官方脚本，失败则手动安装
    if ! install_with_official_script; then
        manual_install
    fi
    
    # 验证 sing-box 能否正常运行（测试动态链接）
    info "测试 sing-box 能否正常运行..."
    if sing-box version >/dev/null 2>&1; then
        info "sing-box 运行正常。"
    else
        warn "sing-box 无法运行，可能缺少动态链接库。"
        if is_alpine; then
            info "尝试安装 libc6-compat 兼容层..."
            apk add --no-cache libc6-compat
            if sing-box version >/dev/null 2>&1; then
                info "兼容层安装成功，sing-box 现在可以运行。"
            else
                warn "仍然无法运行，请检查系统环境。"
            fi
        else
            warn "请检查系统是否缺少必要的库文件。"
        fi
    fi
    
    info "sing-box 安装完成！"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请使用 root 用户执行此脚本！"
    fi
}

# 执行安装
main_install
