#!/bin/bash

#================================================================================
# Universal WARP Manager (UWM)
# 版本: v1.0.6 (Refactored/Stable)
# 更新: 移除所有单行缩写语法，修复变量为空导致的执行错误
#================================================================================

# --- 全局变量配置 ---
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

# NAT64 DNS
NAT64_DNS=("2a01:4f8:c2c:123f::1" "2a00:1098:2b::1")

# --- 辅助函数 ---

info() {
    echo -e "${B}[INFO]${N} $1"
}

success() {
    echo -e "${G}[OK]${N} $1"
}

warn() {
    echo -e "${Y}[WARN]${N} $1"
}

error() {
    echo -e "${R}[ERR]${N} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

get_ip_cmd() {
    if command -v ip >/dev/null 2>&1; then
        echo "$(command -v ip)"
    else
        error "未找到 'ip' 命令，请确保已安装 iproute2"
        exit 1
    fi
}

check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH_TUN="linux-x86_64"
            ;;
        aarch64)
            ARCH_TUN="linux-arm64"
            ;;
        *)
            error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
}

check_tun() {
    # 尝试创建 TUN 设备节点
    if [[ ! -c /dev/net/tun ]]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 >/dev/null 2>&1
        chmod 600 /dev/net/tun >/dev/null 2>&1
    fi
    # 再次检查
    if [[ ! -c /dev/net/tun ]]; then
        error "TUN 设备缺失。如果是 OpenVZ/LXC，请在 VPS 面板开启 TUN/TAP 功能"
        exit 1
    fi
}

check_network() {
    HAS_IPV4=false
    HAS_IPV6=false
    
    if curl -4 -s -m 2 ifconfig.me >/dev/null 2>&1; then
        HAS_IPV4=true
    fi
    
    if curl -6 -s -m 2 ifconfig.me >/dev/null 2>&1; then
        HAS_IPV6=true
    fi

    if [[ "$HAS_IPV4" == "true" ]] && [[ "$HAS_IPV6" == "true" ]]; then
        NET_TYPE="Dual"
    elif [[ "$HAS_IPV4" == "true" ]]; then
        NET_TYPE="v4"
    elif [[ "$HAS_IPV6" == "true" ]]; then
        NET_TYPE="v6"
    else
        error "无法连接互联网"
        exit 1
    fi
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    echo "WARP_PLUS_KEY=\"$WARP_PLUS_KEY\"" > "$CONFIG_FILE"
}

# --- 安装函数 ---

setup_dns64() {
    if [[ "$NET_TYPE" == "v6" ]]; then
        info "设置临时 NAT64 DNS..."
        cp /etc/resolv.conf /etc/resolv.conf.bak
        echo "nameserver ${NAT64_DNS[0]}" > /etc/resolv.conf
    fi
}

restore_dns() {
    if [[ "$NET_TYPE" == "v6" ]] && [[ -f /etc/resolv.conf.bak ]]; then
        mv /etc/resolv.conf.bak /etc/resolv.conf
    fi
}

install_base() {
    info "安装基础依赖..."
    apt-get update -y
    apt-get install -y curl lsb-release gnupg2 jq iproute2 net-tools file

    if ! command -v warp-cli >/dev/null; then
        info "安装 Cloudflare WARP..."
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update -y
        apt-get install -y cloudflare-warp
    fi
}

install_tun() {
    if [[ -f "$BIN_TUN" ]]; then
        # 简单校验文件是否可执行且是二进制
        if file "$BIN_TUN" | grep -q "ELF"; then
            success "Tun2Socks 已安装"
            return
        fi
    fi

    info "下载 Tun2Socks ($ARCH_TUN)..."
    # 使用 v2.6.1 稳定版链接
    local URL="https://github.com/heiher/hev-socks5-tunnel/releases/download/v2.6.1/hev-socks5-tunnel-$ARCH_TUN"
    
    # 强制覆盖下载
    curl -L -o "$BIN_TUN" "$URL"
    
    # 检查变量是否为空
    if [[ -z "$BIN_TUN" ]]; then
        error "内部错误: BIN_TUN 变量为空"
        exit 1
    fi

    if [[ ! -f "$BIN_TUN" ]]; then
        error "下载失败: 文件不存在"
        exit 1
    fi

    chmod +x "$BIN_TUN"
    
    # 完整性校验
    if ! file "$BIN_TUN" | grep -q "ELF"; then
        error "下载失败: 文件损坏或非二进制文件"
        rm -f "$BIN_TUN"
        exit 1
    fi
}

configure() {
    info "生成配置文件..."
    mkdir -p "$CONFIG_DIR"
    IP_CMD=$(get_ip_cmd)
    
    # WARP 初始化
    if ! warp-cli status | grep -q "Registration missing"; then
        warp-cli disconnect >/dev/null 2>&1
    else
        echo "y" | warp-cli registration new >/dev/null 2>&1
    fi
    
    warp-cli mode proxy >/dev/null 2>&1
    warp-cli proxy port $SOCKS5_PORT >/dev/null 2>&1
    
    load_config
    if [[ -n "$WARP_PLUS_KEY" ]]; then
        warp-cli registration license "$WARP_PLUS_KEY" >/dev/null 2>&1
    fi
    
    warp-cli connect >/dev/null 2>&1

    # Tun2Socks 配置
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

    # 生成辅助启动脚本 (等待设备就绪)
    cat > "$CONFIG_DIR/up.sh" <<EOF
#!/bin/bash
# 等待 tun0 设备出现，超时 5 秒
for i in {1..10}; do
    if ip link show tun0 >/dev/null 2>&1; then
        exit 0
    fi
    sleep 0.5
done
exit 0
EOF
    chmod +x "$CONFIG_DIR/up.sh"

    # 生成 Systemd 服务
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
    
    # 获取 SSH IP
    SSH_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    
    # 插入等待脚本
    echo "ExecStartPost=$CONFIG_DIR/up.sh" >> "$SERVICE_FILE"

    # 1. SSH 保护 (仅 IPv4)
    if [[ -n "$SSH_IP" ]]; then
        if [[ "$SSH_IP" == *":"* ]]; then
            info "检测到 SSH 为 IPv6 ($SSH_IP)，跳过 IPv4 白名单"
        else
            echo "ExecStartPost=$IP_CMD rule add from $SSH_IP lookup main pref 5" >> "$SERVICE_FILE"
            echo "ExecStop=$IP_CMD rule del from $SSH_IP lookup main pref 5" >> "$SERVICE_FILE"
            info "SSH 保护已启用 ($SSH_IP)"
        fi
    fi

    # 2. 排除保留地址
    NETS=("0.0.0.0/8" "10.0.0.0/8" "127.0.0.0/8" "169.254.0.0/16" "172.16.0.0/12" "192.168.0.0/16" "224.0.0.0/4" "240.0.0.0/4" "162.159.0.0/16" "188.114.96.0/20")
    for net in "${NETS[@]}"; do
        echo "ExecStartPost=$IP_CMD rule add to $net lookup main pref 10" >> "$SERVICE_FILE"
        echo "ExecStop=$IP_CMD rule del to $net lookup main pref 10" >> "$SERVICE_FILE"
    done

    # 3. 全局路由
    echo "ExecStartPost=$IP_CMD route add default dev tun0 table 100" >> "$SERVICE_FILE"
    echo "ExecStartPost=$IP_CMD rule add lookup 100 pref 20" >> "$SERVICE_FILE"
    echo "ExecStop=$IP_CMD route del default dev tun0 table 100" >> "$SERVICE_FILE"
    echo "ExecStop=$IP_CMD rule del lookup 100 pref 20" >> "$SERVICE_FILE"

    echo -e "\n[Install]\nWantedBy=multi-user.target" >> "$SERVICE_FILE"

    systemctl daemon-reload
}

install() {
    check_root
    check_arch
    check_tun
    check_network
    
    info "开始安装 (架构: $ARCH)..."
    
    trap restore_dns EXIT
    setup_dns64
    install_base
    install_tun
    restore_dns
    trap - EXIT
    
    configure
    
    if [[ -f "$0" ]]; then
        cp "$0" "$BIN_WARP"
        chmod +x "$BIN_WARP"
    fi
    
    success "安装完成！"
    echo -e "请输入 ${G}warp${N} 打开菜单"
}

# --- 运行控制 ---

is_active() {
    systemctl is-active --quiet uwm-tun2socks
}

warp_on() {
    if is_active; then
        warn "已是开启状态"
        return
    fi
    info "开启全局代理..."
    check_tun
    
    # 确保连接
    warp-cli connect >/dev/null 2>&1
    
    # 重新生成配置以获取最新 SSH IP
    configure
    
    systemctl enable --now uwm-tun2socks
    
    # 等待启动
    sleep 3
    
    if is_active; then
        success "已开启"
        echo -e "当前 IPv4: ${G}$(curl -4 -s -m 3 ifconfig.me)${N}"
    else
        error "启动失败，请检查日志:"
        journalctl -xeu uwm-tun2socks --no-pager | tail -n 10
    fi
}

warp_off() {
    if ! is_active; then
        warn "已是关闭状态"
        return
    fi
    info "关闭全局代理..."
    systemctl stop uwm-tun2socks
    systemctl disable uwm-tun2socks
    
    # 刷新路由
    ip rule flush >/dev/null 2>&1
    
    success "已关闭"
    echo -e "当前 IPv4: ${Y}$(curl -4 -s -m 3 ifconfig.me)${N}"
}

warp_change() {
    info "快速重连换 IP..."
    local was_active=false
    if is_active; then
        was_active=true
        warp_off
    fi
    
    warp-cli disconnect >/dev/null 2>&1
    sleep 1
    warp-cli connect >/dev/null 2>&1
    sleep 3
    
    if $was_active; then
        warp_on
    fi
    success "更换完成"
}

warp_change_full() {
    info "注册新账号换 IP..."
    local was_active=false
    if is_active; then
        was_active=true
        warp_off
    fi
    
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
    
    if $was_active; then
        warp_on
    fi
    success "更换完成"
}

warp_uninstall() {
    echo -e "${R}警告: 即将卸载 UWM${N}"
    read -p "确认? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        return
    fi
    
    systemctl stop uwm-tun2socks 2>/dev/null
    systemctl disable uwm-tun2socks 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    apt-get remove --purge cloudflare-warp -y
    rm -rf "$CONFIG_DIR" "$BIN_WARP" "$BIN_TUN"
    
    ip rule del pref 5 2>/dev/null
    ip rule del pref 10 2>/dev/null
    ip rule del pref 20 2>/dev/null
    
    success "卸载完成"
}

warp_account_menu() {
    load_config
    echo -e "\n1) 切换免费\n2) 切换 WARP+\n3) 设置密钥\n0) 返回"
    read -p "选择: " c
    case $c in
        1)
            WARP_PLUS_KEY=""
            save_config
            warp_change_full
            ;;
        2)
            if [[ -z "$WARP_PLUS_KEY" ]]; then
                error "无密钥"
            else
                warp-cli registration license "$WARP_PLUS_KEY"
                success "OK"
            fi
            ;;
        3)
            read -p "密钥: " k
            if [[ ${#k} -eq 26 ]]; then
                WARP_PLUS_KEY="$k"
                save_config
                warp-cli registration license "$k"
                success "OK"
            else
                error "格式错"
            fi
            ;;
    esac
}

warp_status() {
    echo -e "${C}════ STATUS ════${N}"
    if is_active; then
        echo -e "代理: ${G}ON${N}"
    else
        echo -e "代理: ${R}OFF${N}"
    fi
    
    local w_status=$(warp-cli status 2>/dev/null | grep "Status" | cut -d: -f2)
    echo -e "WARP: ${Y}$w_status${N}"
    echo -e "IPv4: ${G}$(curl -4 -s -m 3 ifconfig.me)${N}"
    echo -e "类型: ${B}$(warp-cli registration show 2>/dev/null | grep "Account type" | cut -d: -f2)${N}"
    echo -e "${C}════════════════${N}"
}

show_menu() {
    clear
    echo -e "${C}╔════ UWM v1.0.6 ════╗${N}"
    if is_active; then
        echo -e "║ 状态: ${G}ON${N}           ║"
    else
        echo -e "║ 状态: ${R}OFF${N}          ║"
    fi
    echo -e "║ IP  : $(curl -4 -s -m 2 ifconfig.me) ║"
    echo -e "╠════════════════════╣"
    echo " [1] 开启代理"
    echo " [2] 关闭代理"
    echo " [3] 快速换IP"
    echo " [4] 彻底换IP"
    echo " [5] 账户管理"
    echo " [6] 状态详情"
    echo " [7] 卸载"
    echo " [0] 退出"
    
    read -p "选: " n
    case $n in
        1) warp_on ;;
        2) warp_off ;;
        3) warp_change ;;
        4) warp_change_full ;;
        5) warp_account_menu ;;
        6) warp_status ;;
        7) warp_uninstall ;;
        0) exit ;;
        *) echo "无效" ;;
    esac
}

# --- 入口逻辑 ---

if [[ ! -f "$BIN_TUN" ]] && [[ -z "$1" ]]; then
    install
    exit
fi

case "$1" in
    on) warp_on ;;
    off) warp_off ;;
    change) warp_change ;;
    change-full) warp_change_full ;;
    account) warp_account_menu ;;
    status) warp_status ;;
    uninstall) warp_uninstall ;;
    *) show_menu ;;
esac
