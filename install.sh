#!/bin/bash

#================================================================================
# Universal WARP Manager (UWM)
# 版本: v1.0.4 (Stable/IPv6-Fix)
# 适用: Debian 10+ / Ubuntu 20.04+
# 更新: 修复 SSH 为 IPv6 地址时导致的启动失败问题
#================================================================================

# --- 全局变量定义 ---
CONFIG_DIR="/etc/uwm"
CONFIG_FILE="$CONFIG_DIR/config"
TUN_CONFIG="$CONFIG_DIR/tun2socks.yaml"
SERVICE_FILE="/etc/systemd/system/uwm-tun2socks.service"
BIN_WARP="/usr/local/bin/warp"
BIN_TUN="/usr/local/bin/tun2socks"
SOCKS5_PORT=40000

# 颜色定义
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
C='\033[0;36m'
N='\033[0m'

# NAT64 DNS 列表 (用于纯IPv6环境)
NAT64_DNS=("2a01:4f8:c2c:123f::1" "2a00:1098:2b::1" "2001:67c:2b0::4")

# --- 基础工具函数 ---

info() { echo -e "${B}[INFO]${N} $1"; }
success() { echo -e "${G}[OK]${N} $1"; }
warn() { echo -e "${Y}[WARN]${N} $1"; }
error() { echo -e "${R}[ERR]${N} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行此脚本: sudo bash $0"
        exit 1
    fi
}

# 动态获取 ip 命令路径
get_ip_cmd() {
    if command -v ip >/dev/null 2>&1; then
        echo "$(command -v ip)"
    else
        error "系统缺少 'ip' 命令，请安装 iproute2"
        exit 1
    fi
}

check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ARCH_TUN="linux-x86_64" ;;
        aarch64) ARCH_TUN="linux-arm64" ;;
        armv7l)  ARCH_TUN="linux-arm" ;;
        *)       error "不支持的系统架构: $ARCH"; exit 1 ;;
    esac
}

# 检查并尝试开启 TUN 设备
check_tun() {
    if [[ ! -c /dev/net/tun ]]; then
        info "检测到 TUN 设备缺失，尝试创建..."
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 600 /dev/net/tun
    fi
    if [[ ! -c /dev/net/tun ]]; then
        error "无法创建 TUN 设备。"
        error "如果这是 OpenVZ 或 LXC 容器，请在 VPS 控制面板中开启 TUN/TAP 功能。"
        exit 1
    fi
}

check_network() {
    HAS_IPV4=false
    HAS_IPV6=false
    if curl -4 -s --max-time 2 ifconfig.me >/dev/null; then HAS_IPV4=true; fi
    if curl -6 -s --max-time 2 ifconfig.me >/dev/null; then HAS_IPV6=true; fi
    
    if $HAS_IPV4 && $HAS_IPV6; then
        NET_TYPE="Dual Stack"
    elif $HAS_IPV4; then
        NET_TYPE="IPv4 Only"
    elif $HAS_IPV6; then
        NET_TYPE="IPv6 Only"
    else
        error "无法连接互联网，请检查网络设置"
        exit 1
    fi
}

load_config() { [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"; }

save_config() {
    mkdir -p "$CONFIG_DIR"
    echo "WARP_PLUS_KEY=\"$WARP_PLUS_KEY\"" > "$CONFIG_FILE"
}

# --- 安装流程函数 ---

setup_dns64() {
    [[ "$NET_TYPE" != "IPv6 Only" ]] && return
    info "纯 IPv6 环境: 设置临时 NAT64 DNS 以支持下载..."
    cp /etc/resolv.conf /etc/resolv.conf.bak
    echo "nameserver ${NAT64_DNS[0]}" > /etc/resolv.conf
    # 测试连通性
    if ! curl -s --max-time 3 https://github.com >/dev/null; then
        warn "首选 DNS64 超时，尝试备用节点..."
        echo "nameserver ${NAT64_DNS[1]}" > /etc/resolv.conf
    fi
}

restore_dns() {
    [[ "$NET_TYPE" != "IPv6 Only" ]] && return
    if [[ -f /etc/resolv.conf.bak ]]; then
        mv /etc/resolv.conf.bak /etc/resolv.conf
        info "已恢复原始 DNS 配置"
    fi
}

install_dependencies() {
    info "更新软件源并安装依赖组件..."
    apt-get update -y
    apt-get install -y curl lsb-release gnupg2 jq iproute2 net-tools
}

install_warp_cli() {
    if command -v warp-cli >/dev/null; then
        success "Cloudflare WARP 已安装"
        return
    fi
    info "安装 Cloudflare WARP 客户端..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -y
    apt-get install -y cloudflare-warp
}

install_tun2socks() {
    if [[ -f "$BIN_TUN" ]]; then
        success "Tun2Socks 已安装"
        return
    fi
    info "下载 Tun2Socks ($ARCH_TUN)..."
    LATEST_URL=$(curl -s "https://api.github.com/repos/heiher/hev-socks5-tunnel/releases/latest" | grep "browser_download_url" | grep "$ARCH_TUN" | cut -d '"' -f 4 | head -n 1)
    if [[ -z "$LATEST_URL" ]]; then
        warn "GitHub API 限制，使用备用版本..."
        LATEST_URL="https://github.com/heiher/hev-socks5-tunnel/releases/download/v2.8.2/hev-socks5-tunnel-$ARCH_TUN"
    fi
    curl -L -o "$BIN_TUN" "$LATEST_URL"
    chmod +x "$BIN_TUN"
    if [[ -f "$BIN_TUN" ]]; then
        success "Tun2Socks 安装成功"
    else
        error "Tun2Socks 下载失败"
        exit 1
    fi
}

# --- 配置生成函数 ---

configure_warp() {
    info "初始化 WARP 账户连接..."
    if ! warp-cli status | grep -q "Registration missing"; then
        warp-cli disconnect >/dev/null 2>&1
    else
        echo "y" | warp-cli registration new >/dev/null 2>&1
    fi
    warp-cli mode proxy >/dev/null 2>&1
    warp-cli proxy port $SOCKS5_PORT >/dev/null 2>&1
    load_config
    if [[ -n "$WARP_PLUS_KEY" ]]; then
        info "应用已保存的 WARP+ 密钥..."
        warp-cli registration license "$WARP_PLUS_KEY" >/dev/null 2>&1
    fi
    warp-cli connect >/dev/null 2>&1
    for i in {1..5}; do
        if warp-cli status | grep -q "Status: Connected"; then
            success "WARP 隧道建立成功"
            return
        fi
        sleep 1
    done
    warn "WARP 连接响应较慢，请稍后检查状态"
}

configure_tun2socks() {
    info "生成 Tun2Socks 及路由配置..."
    mkdir -p "$CONFIG_DIR"
    IP_CMD=$(get_ip_cmd)
    
    # 1. 写入 Tun2Socks 配置 (仅接管 IPv4)
    cat > "$TUN_CONFIG" <<EOF
tunnel:
  name: tun0
  mtu: 9000
  multi-queue: true
  ipv4: 198.18.0.1
socks5:
  port: $SOCKS5_PORT
  address: 127.0.0.1
  udp: 'udp'
  mark: 0
EOF

    # 2. 生成 Systemd 服务文件
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Universal WARP Manager - Tun2Socks
After=network.target warp-svc.service

[Service]
Type=simple
User=root
ExecStart=$BIN_TUN -c $TUN_CONFIG
Restart=always
RestartSec=3
EOF

    # 获取 SSH 客户端 IP
    SSH_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    
    # --- 追加路由规则 (关键修复) ---
    
    # [规则1] SSH 防断连保护
    if [[ -n "$SSH_IP" ]]; then
        # 判断 SSH IP 是否包含冒号 (是否为 IPv6)
        if [[ "$SSH_IP" == *":"* ]]; then
            # IPv6 地址：不需要保护，因为我们只劫持 IPv4 路由
            info "检测到 IPv6 SSH 连接 ($SSH_IP)，跳过 IPv4 规则添加。"
        else
            # IPv4 地址：添加保护
            echo "ExecStartPost=$IP_CMD rule add from $SSH_IP lookup main pref 5" >> "$SERVICE_FILE"
            echo "ExecStop=$IP_CMD rule del from $SSH_IP lookup main pref 5" >> "$SERVICE_FILE"
            info "SSH 保护已启用 (IPv4): $SSH_IP"
        fi
    else
        warn "未检测到 SSH 客户端 IP，请小心操作"
    fi

    # [规则2] 排除内网和保留地址 (IPv4)
    RESERVED=("0.0.0.0/8" "10.0.0.0/8" "127.0.0.0/8" "169.254.0.0/16" "172.16.0.0/12" "192.168.0.0/16" "224.0.0.0/4" "240.0.0.0/4")
    for net in "${RESERVED[@]}"; do
        echo "ExecStartPost=$IP_CMD rule add to $net lookup main pref 10" >> "$SERVICE_FILE"
        echo "ExecStop=$IP_CMD rule del to $net lookup main pref 10" >> "$SERVICE_FILE"
    done

    # [规则3] 排除 Cloudflare 边缘节点 (IPv4, 防止死循环)
    CF_NETS=("162.159.0.0/16" "188.114.96.0/20")
    for net in "${CF_NETS[@]}"; do
        echo "ExecStartPost=$IP_CMD rule add to $net lookup main pref 12" >> "$SERVICE_FILE"
        echo "ExecStop=$IP_CMD rule del to $net lookup main pref 12" >> "$SERVICE_FILE"
    done

    # [规则4] 全局流量劫持 (IPv4, Table 100)
    echo "ExecStartPost=$IP_CMD route add default dev tun0 table 100" >> "$SERVICE_FILE"
    echo "ExecStartPost=$IP_CMD rule add lookup 100 pref 20" >> "$SERVICE_FILE"
    
    echo "ExecStop=$IP_CMD route del default dev tun0 table 100" >> "$SERVICE_FILE"
    echo "ExecStop=$IP_CMD rule del lookup 100 pref 20" >> "$SERVICE_FILE"

    echo -e "\n[Install]\nWantedBy=multi-user.target" >> "$SERVICE_FILE"

    systemctl daemon-reload
}

install_main() {
    check_root
    check_arch
    check_tun
    check_network
    
    info "开始安装 UWM (架构: $ARCH, 网络: $NET_TYPE)..."
    
    trap restore_dns EXIT
    setup_dns64
    install_dependencies
    install_warp_cli
    install_tun2socks
    restore_dns
    trap - EXIT
    
    configure_warp
    configure_tun2socks
    
    if [[ -f "$0" ]]; then
        cp "$0" "$BIN_WARP"
        chmod +x "$BIN_WARP"
    else
        warn "管道执行无法自动复制命令，请手动下载。"
    fi
    
    success "安装完成！"
    echo -e "请直接输入 ${G}warp${N} 打开管理菜单"
}

# --- 操作控制 ---

is_active() {
    systemctl is-active --quiet uwm-tun2socks
}

warp_on() {
    if is_active; then warn "已是开启状态"; return; fi
    info "正在开启全局代理..."
    check_tun
    warp-cli connect >/dev/null 2>&1
    configure_tun2socks # 重新生成配置
    systemctl enable --now uwm-tun2socks
    sleep 2
    if is_active; then
        success "全局代理已开启"
        echo -e "当前 IPv4: ${G}$(curl -4 -s --max-time 5 ifconfig.me)${N}"
    else
        error "启动失败，日志:"
        journalctl -xeu uwm-tun2socks --no-pager | tail -n 10
    fi
}

warp_off() {
    if ! is_active; then warn "已是关闭状态"; return; fi
    info "正在关闭全局代理..."
    systemctl stop uwm-tun2socks
    systemctl disable uwm-tun2socks
    ip rule flush >/dev/null 2>&1
    success "全局代理已关闭"
    echo -e "当前 IPv4: ${Y}$(curl -4 -s --max-time 5 ifconfig.me)${N}"
}

warp_change() {
    info "快速更换 IP..."
    local was_active=false
    if is_active; then was_active=true; warp_off; fi
    warp-cli disconnect >/dev/null 2>&1; sleep 1
    warp-cli connect >/dev/null 2>&1; sleep 3
    if $was_active; then warp_on; fi
    success "IP 更换流程完成"
}

warp_change_full() {
    info "彻底更换 IP (新账号)..."
    local was_active=false
    if is_active; then was_active=true; warp_off; fi
    load_config
    warp-cli disconnect >/dev/null 2>&1; warp-cli registration delete >/dev/null 2>&1
    echo "y" | warp-cli registration new >/dev/null 2>&1
    [[ -n "$WARP_PLUS_KEY" ]] && warp-cli registration license "$WARP_PLUS_KEY" >/dev/null 2>&1
    warp-cli mode proxy >/dev/null 2>&1; warp-cli proxy port $SOCKS5_PORT >/dev/null 2>&1
    warp-cli connect >/dev/null 2>&1; sleep 3
    if $was_active; then warp_on; fi
    success "账户重置及 IP 更换完成"
}

warp_uninstall() {
    echo -e "${R}警告: 卸载 UWM 及 WARP${N}"
    read -p "确认? (y/n): " confirm; [[ "$confirm" != "y" ]] && return
    info "卸载中..."
    systemctl stop uwm-tun2socks 2>/dev/null; systemctl disable uwm-tun2socks 2>/dev/null
    rm -f "$SERVICE_FILE"; systemctl daemon-reload
    apt-get remove --purge cloudflare-warp -y
    rm -rf "$CONFIG_DIR" "$BIN_WARP" "$BIN_TUN"
    ip rule del pref 5 2>/dev/null; ip rule del pref 10 2>/dev/null; ip rule del pref 12 2>/dev/null; ip rule del pref 20 2>/dev/null
    success "卸载完成"
}

warp_status() {
    echo -e "${C}════════ STATUS ════════${N}"
    is_active && echo -e "代理: ${G}ON${N}" || echo -e "代理: ${R}OFF${N}"
    echo -e "WARP: ${Y}$(warp-cli status 2>/dev/null | grep "Status" | cut -d: -f2)${N}"
    echo -e "IPv4: ${G}$(curl -4 -s --max-time 3 ifconfig.me)${N}"
    echo -e "类型: ${B}$(warp-cli registration show 2>/dev/null | grep "Account type" | cut -d: -f2)${N}"
    echo -e "${C}════════════════════════${N}"
}

warp_account_menu() {
    load_config; echo -e "\n1) 切换免费\n2) 切换 WARP+\n3) 设置密钥\n0) 返回"
    read -p "选择: " c
    case $c in
        1) WARP_PLUS_KEY=""; save_config; warp_change_full ;;
        2) [[ -z "$WARP_PLUS_KEY" ]] && error "无密钥" || { warp-cli registration license "$WARP_PLUS_KEY" && success "OK"; } ;;
        3) read -p "密钥: " k; [[ ${#k} -eq 26 ]] && { WARP_PLUS_KEY="$k"; save_config; warp-cli registration license "$k" && success "OK"; } || error "格式错"; ;;
    esac
}

show_menu() {
    clear; echo -e "${C}╔════ UWM v1.0.4 ════╗${N}"; is_active && s="${G}ON${N}" || s="${R}OFF${N}"
    echo -e "║ 状态: $s           ║"; echo -e "║ IP  : $(curl -4 -s --max-time 2 ifconfig.me) ║"
    echo -e "╠════════════════════╣"; echo " [1] 开启代理"; echo " [2] 关闭代理"; echo " [3] 快速换IP"; echo " [4] 彻底换IP"; echo " [5] 账户管理"; echo " [6] 状态详情"; echo " [7] 卸载"; echo " [0] 退出"
    read -p "选: " n; case $n in 1) warp_on;; 2) warp_off;; 3) warp_change;; 4) warp_change_full;; 5) warp_account_menu;; 6) warp_status;; 7) warp_uninstall;; 0) exit;; *) echo "X";; esac
}

[[ ! -f "$BIN_TUN" ]] && [[ -z "$1" ]] && { install_main; exit; }
case "$1" in on) warp_on;; off) warp_off;; change) warp_change;; change-full) warp_change_full;; status) warp_status;; ip) curl -4 -s ifconfig.me; echo;; account) warp_account_menu;; uninstall) warp_uninstall;; *) show_menu;; esac
