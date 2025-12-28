#!/bin/bash

#================================================================================
# Universal WARP Manager (UWM)
# 版本: v1.0.3 (Stable/Enhanced)
# 适用: Debian 10+ / Ubuntu 20.04+ (x86_64, aarch64)
# 功能: Cloudflare WARP 全局代理 (Tun2Socks 模式)
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

# 动态获取 ip 命令路径 (修复报错的关键)
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
    # 获取下载链接
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
    # 清理旧状态
    if ! warp-cli status | grep -q "Registration missing"; then
        warp-cli disconnect >/dev/null 2>&1
    else
        echo "y" | warp-cli registration new >/dev/null 2>&1
    fi

    # 设置模式
    warp-cli mode proxy >/dev/null 2>&1
    warp-cli proxy port $SOCKS5_PORT >/dev/null 2>&1
    
    # 应用密钥
    load_config
    if [[ -n "$WARP_PLUS_KEY" ]]; then
        info "应用已保存的 WARP+ 密钥..."
        warp-cli registration license "$WARP_PLUS_KEY" >/dev/null 2>&1
    fi
    
    # 连接
    warp-cli connect >/dev/null 2>&1
    
    # 等待连接就绪
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
    
    # 获取 ip 命令的绝对路径
    IP_CMD=$(get_ip_cmd)
    
    # 1. 写入 Tun2Socks 配置
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

    # 2. 生成 Systemd 服务文件 (逐行写入以避免格式错误)
    
    # 基础服务定义
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
    
    # --- 追加路由规则 ---
    
    # [规则1] SSH 防断连保护
    if [[ -n "$SSH_IP" ]]; then
        echo "ExecStartPost=$IP_CMD rule add from $SSH_IP lookup main pref 5" >> "$SERVICE_FILE"
        echo "ExecStop=$IP_CMD rule del from $SSH_IP lookup main pref 5" >> "$SERVICE_FILE"
        info "SSH 保护已启用: $SSH_IP"
    else
        warn "未检测到 SSH 客户端 IP，请小心操作"
    fi

    # [规则2] 排除内网和保留地址
    RESERVED=("0.0.0.0/8" "10.0.0.0/8" "127.0.0.0/8" "169.254.0.0/16" "172.16.0.0/12" "192.168.0.0/16" "224.0.0.0/4" "240.0.0.0/4")
    for net in "${RESERVED[@]}"; do
        echo "ExecStartPost=$IP_CMD rule add to $net lookup main pref 10" >> "$SERVICE_FILE"
        echo "ExecStop=$IP_CMD rule del to $net lookup main pref 10" >> "$SERVICE_FILE"
    done

    # [规则3] 排除 Cloudflare 边缘节点 (防止死循环)
    CF_NETS=("162.159.0.0/16" "188.114.96.0/20")
    for net in "${CF_NETS[@]}"; do
        echo "ExecStartPost=$IP_CMD rule add to $net lookup main pref 12" >> "$SERVICE_FILE"
        echo "ExecStop=$IP_CMD rule del to $net lookup main pref 12" >> "$SERVICE_FILE"
    done

    # [规则4] 全局流量劫持 (Table 100)
    echo "ExecStartPost=$IP_CMD route add default dev tun0 table 100" >> "$SERVICE_FILE"
    echo "ExecStartPost=$IP_CMD rule add lookup 100 pref 20" >> "$SERVICE_FILE"
    
    echo "ExecStop=$IP_CMD route del default dev tun0 table 100" >> "$SERVICE_FILE"
    echo "ExecStop=$IP_CMD rule del lookup 100 pref 20" >> "$SERVICE_FILE"

    # [结束] 安装段
    echo -e "\n[Install]\nWantedBy=multi-user.target" >> "$SERVICE_FILE"

    systemctl daemon-reload
}

install_main() {
    check_root
    check_arch
    check_tun
    check_network
    
    info "开始安装 UWM (架构: $ARCH, 网络: $NET_TYPE)..."
    
    # 设置陷阱：如果脚本中途退出，确保恢复 DNS
    trap restore_dns EXIT

    setup_dns64
    install_dependencies
    install_warp_cli
    install_tun2socks
    
    # 恢复 DNS 并解除陷阱
    restore_dns
    trap - EXIT
    
    # 配置软件
    configure_warp
    configure_tun2socks
    
    # 安装快捷命令
    if [[ -f "$0" ]]; then
        cp "$0" "$BIN_WARP"
        chmod +x "$BIN_WARP"
    else
        warn "检测到管道执行，无法自动安装快捷命令。"
        warn "请手动下载脚本保存为 $BIN_WARP 以使用 'warp' 命令。"
    fi
    
    success "安装完成！"
    echo -e "请直接输入 ${G}warp${N} 打开管理菜单"
}

# --- 操作控制函数 ---

is_active() {
    systemctl is-active --quiet uwm-tun2socks
}

warp_on() {
    if is_active; then
        warn "全局代理已经是开启状态"
        return
    fi
    info "正在开启全局代理..."
    
    # 再次检查 TUN (防止重启后丢失)
    check_tun
    
    # 确保 WARP 在线
    warp-cli connect >/dev/null 2>&1
    
    # 重新生成配置 (关键：为了获取最新的 SSH IP)
    configure_tun2socks
    
    systemctl enable --now uwm-tun2socks
    sleep 2
    
    if is_active; then
        success "全局代理已开启"
        echo -e "当前 IP: ${G}$(curl -4 -s --max-time 5 ifconfig.me)${N}"
    else
        error "启动失败，请查看详细日志:"
        echo "journalctl -xeu uwm-tun2socks --no-pager"
    fi
}

warp_off() {
    if ! is_active; then
        warn "全局代理已经是关闭状态"
        return
    fi
    info "正在关闭全局代理..."
    systemctl stop uwm-tun2socks
    systemctl disable uwm-tun2socks
    
    # 强制清理可能残留的路由规则
    ip rule flush >/dev/null 2>&1
    
    success "全局代理已关闭"
    echo -e "当前 IP: ${Y}$(curl -4 -s --max-time 5 ifconfig.me)${N}"
}

warp_change() {
    info "正在快速更换 IP..."
    local was_active=false
    if is_active; then was_active=true; warp_off; fi
    
    warp-cli disconnect >/dev/null 2>&1
    sleep 1
    warp-cli connect >/dev/null 2>&1
    sleep 3
    
    if $was_active; then warp_on; fi
    success "IP 更换流程完成"
}

warp_change_full() {
    info "正在彻底更换 IP (注册新账号)..."
    local was_active=false
    if is_active; then was_active=true; warp_off; fi
    
    load_config
    warp-cli disconnect >/dev/null 2>&1
    warp-cli registration delete >/dev/null 2>&1
    echo "y" | warp-cli registration new >/dev/null 2>&1
    
    if [[ -n "$WARP_PLUS_KEY" ]]; then
        warp-cli registration license "$WARP_PLUS_KEY" >/dev/null 2>&1
    fi
    
    warp-cli mode proxy >/dev/null 2>&1
    warp-cli proxy port $SOCKS5_PORT >/dev/null 2>&1
    warp-cli connect >/dev/null 2>&1
    sleep 3
    
    if $was_active; then warp_on; fi
    success "账户重置及 IP 更换完成"
}

warp_uninstall() {
    echo -e "${R}警告: 即将卸载 UWM 及 Cloudflare WARP${N}"
    read -p "确认执行? (输入 y 确认): " confirm
    [[ "$confirm" != "y" ]] && return
    
    info "开始卸载..."
    systemctl stop uwm-tun2socks 2>/dev/null
    systemctl disable uwm-tun2socks 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    apt-get remove --purge cloudflare-warp -y
    rm -rf "$CONFIG_DIR"
    rm -f "$BIN_WARP"
    rm -f "$BIN_TUN"
    
    # 路由清理
    ip rule del pref 5 2>/dev/null
    ip rule del pref 10 2>/dev/null
    ip rule del pref 12 2>/dev/null
    ip rule del pref 20 2>/dev/null
    
    success "卸载完成"
}

warp_status() {
    echo -e "${C}════════════════ STATUS ════════════════${N}"
    if is_active; then
        echo -e "代理状态: ${G}● 已开启${N}"
    else
        echo -e "代理状态: ${R}○ 已关闭${N}"
    fi
    
    w_status=$(warp-cli status 2>/dev/null | grep "Status" | cut -d: -f2)
    echo -e "WARP隧道: ${Y}$w_status${N}"
    
    ip_info=$(curl -4 -s --max-time 3 ifconfig.me)
    echo -e "出口 IP : ${G}$ip_info${N}"
    
    type=$(warp-cli registration show 2>/dev/null | grep "Account type" | cut -d: -f2)
    echo -e "账户类型:${B}$type${N}"
    echo -e "${C}════════════════════════════════════════${N}"
}

warp_account_menu() {
    load_config
    echo -e "\n${B}=== 账户管理 ===${N}"
    echo -e "当前类型: $(warp-cli registration show 2>/dev/null | grep "Account type" | cut -d: -f2)"
    echo -e "保存密钥: ${WARP_PLUS_KEY:-无}"
    echo -e "\n1) 切换到免费账户 (重置)"
    echo "2) 切换到 WARP+ (使用已存密钥)"
    echo "3) 输入/更换 WARP+ 密钥"
    echo "0) 返回"
    read -p "选择: " c
    case $c in
        1)
            WARP_PLUS_KEY=""
            save_config
            warp_change_full
            ;;
        2)
            if [[ -z "$WARP_PLUS_KEY" ]]; then
                error "未保存密钥，请先选择 3"
            else
                warp-cli registration license "$WARP_PLUS_KEY" && success "已应用密钥"
            fi
            ;;
        3)
            read -p "输入26位密钥: " k
            if [[ ${#k} -eq 26 ]]; then
                WARP_PLUS_KEY="$k"
                save_config
                warp-cli registration license "$k" && success "密钥已保存并应用"
            else
                error "格式错误 (应为26位)"
            fi
            ;;
    esac
}

show_menu() {
    clear
    echo -e "${C}╔══════════════════════════════════════════════════════════════╗${N}"
    echo -e "${C}║${N}               ${G}Universal WARP Manager (UWM)${N}                   ${C}║${N}"
    echo -e "${C}╠══════════════════════════════════════════════════════════════╣${N}"
    if is_active; then
        echo -e "${C}║${N}  代理状态  : ${G}● 已开启${N}                                        ${C}║${N}"
    else
        echo -e "${C}║${N}  代理状态  : ${R}○ 已关闭${N}                                        ${C}║${N}"
    fi
    echo -e "${C}║${N}  当前 IP   : $(curl -4 -s --max-time 2 ifconfig.me)                         ${C}║${N}"
    echo -e "${C}╠══════════════════════════════════════════════════════════════╣${N}"
    echo -e "${C}║${N}   [1] 开启 WARP 全局代理                                     ${C}║${N}"
    echo -e "${C}║${N}   [2] 关闭 WARP 全局代理                                     ${C}║${N}"
    echo -e "${C}║${N}   [3] 快速更换 IP (重连)                                     ${C}║${N}"
    echo -e "${C}║${N}   [4] 彻底更换 IP (重新注册)                                 ${C}║${N}"
    echo -e "${C}║${N}   [5] 账户管理                                               ${C}║${N}"
    echo -e "${C}║${N}   [6] 查看详细状态                                           ${C}║${N}"
    echo -e "${C}║${N}   [7] 卸载                                                   ${C}║${N}"
    echo -e "${C}║${N}   [0] 退出                                                   ${C}║${N}"
    echo -e "${C}╚══════════════════════════════════════════════════════════════╝${N}"
    read -p " 请选择: " num
    case $num in
        1) warp_on ;;
        2) warp_off ;;
        3) warp_change ;;
        4) warp_change_full ;;
        5) warp_account_menu ;;
        6) warp_status ;;
        7) warp_uninstall ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
}

# --- 主逻辑 ---

# 检查安装状态
if [[ ! -f "$BIN_TUN" ]] && [[ -z "$1" ]]; then
    install_main
    exit 0
fi

# 参数路由
case "$1" in
    on|start)   warp_on ;;
    off|stop)   warp_off ;;
    change)     warp_change ;;
    change-full) warp_change_full ;;
    status)     warp_status ;;
    ip)         curl -4 -s ifconfig.me; echo "" ;;
    account)    warp_account_menu ;;
    uninstall)  warp_uninstall ;;
    *)          show_menu ;;
esac
