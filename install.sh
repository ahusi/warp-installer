#!/bin/bash

#================================================================================
# Universal WARP Manager (UWM)
# 版本: v1.0.5 (Final/Stability)
# 更新: 增加启动等待机制，防止 tun0 设备未就绪导致的启动失败
#================================================================================

CONFIG_DIR="/etc/uwm"
CONFIG_FILE="$CONFIG_DIR/config"
TUN_CONFIG="$CONFIG_DIR/tun2socks.yaml"
SERVICE_FILE="/etc/systemd/system/uwm-tun2socks.service"
BIN_WARP="/usr/local/bin/warp"
BIN_TUN="/usr/local/bin/tun2socks"
SOCKS5_PORT=40000

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; C='\033[0;36m'; N='\033[0m'
NAT64_DNS=("2a01:4f8:c2c:123f::1" "2a00:1098:2b::1")

info() { echo -e "${B}[INFO]${N} $1"; }
success() { echo -e "${G}[OK]${N} $1"; }
warn() { echo -e "${Y}[WARN]${N} $1"; }
error() { echo -e "${R}[ERR]${N} $1"; }

check_root() { [[ $EUID -ne 0 ]] && { error "需 root 权限"; exit 1; }; }
get_ip_cmd() { command -v ip || { error "缺少 ip 命令"; exit 1; }; }

check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ARCH_TUN="linux-x86_64" ;;
        aarch64) ARCH_TUN="linux-arm64" ;;
        *)       error "不支持架构: $ARCH"; exit 1 ;;
    esac
}

check_tun() {
    [[ ! -c /dev/net/tun ]] && { mkdir -p /dev/net; mknod /dev/net/tun c 10 200 2>/dev/null; chmod 600 /dev/net/tun 2>/dev/null; }
    [[ ! -c /dev/net/tun ]] && { error "TUN 设备缺失 (OpenVZ需在面板开启)"; exit 1; }
}

check_network() {
    curl -4 -s -m 2 ifconfig.me >/dev/null && HAS_IPV4=true || HAS_IPV4=false
    curl -6 -s -m 2 ifconfig.me >/dev/null && HAS_IPV6=true || HAS_IPV6=false
    if $HAS_IPV4 && $HAS_IPV6; then NET_TYPE="Dual"; elif $HAS_IPV4; then NET_TYPE="v4"; elif $HAS_IPV6; then NET_TYPE="v6"; else error "无网络"; exit 1; fi
}

load_config() { [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"; }
save_config() { mkdir -p "$CONFIG_DIR"; echo "WARP_PLUS_KEY=\"$WARP_PLUS_KEY\"" > "$CONFIG_FILE"; }

setup_dns64() {
    [[ "$NET_TYPE" != "v6" ]] && return
    info "设置 NAT64 DNS..."
    cp /etc/resolv.conf /etc/resolv.conf.bak
    echo "nameserver ${NAT64_DNS[0]}" > /etc/resolv.conf
}
restore_dns() {
    [[ "$NET_TYPE" != "v6" ]] && return
    [[ -f /etc/resolv.conf.bak ]] && mv /etc/resolv.conf.bak /etc/resolv.conf
}

install_base() {
    info "安装依赖..."
    apt-get update -y
    apt-get install -y curl lsb-release gnupg2 jq iproute2 net-tools file
    
    if ! command -v warp-cli >/dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update -y; apt-get install -y cloudflare-warp
    fi
}

install_tun() {
    if [[ -f "$BIN_TUN" ]] && file "$BIN_TUN" | grep -q "ELF"; then success "Tun2Socks 已安装"; return; fi
    info "下载 Tun2Socks..."
    # 使用 v2.6.1 稳定版
    URL="https://github.com/heiher/hev-socks5-tunnel/releases/download/v2.6.1/hev-socks5-tunnel-$ARCH_TUN"
    curl -L -o "$BIN_TUN" "$URL"
    chmod +x "$BIN_TUN"
    # 校验
    if ! file "$BIN_TUN" | grep -q "ELF"; then error "下载失败 (非二进制文件)"; rm -f "$BIN_TUN"; exit 1; fi
}

configure() {
    info "生成配置..."
    mkdir -p "$CONFIG_DIR"
    IP_CMD=$(get_ip_cmd)
    
    # WARP 初始化
    if ! warp-cli status | grep -q "Registration missing"; then warp-cli disconnect >/dev/null 2>&1; else echo "y" | warp-cli registration new >/dev/null 2>&1; fi
    warp-cli mode proxy >/dev/null 2>&1; warp-cli proxy port $SOCKS5_PORT >/dev/null 2>&1
    load_config; [[ -n "$WARP_PLUS_KEY" ]] && warp-cli registration license "$WARP_PLUS_KEY" >/dev/null 2>&1
    warp-cli connect >/dev/null 2>&1
    
    # Tun 配置
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

    # 生成辅助脚本 (用于等待设备就绪)
    # 这解决了 Systemd 启动太快导致找不到设备的问题
    cat > "$CONFIG_DIR/up.sh" <<EOF
#!/bin/bash
# 等待 tun0 设备出现
for i in {1..10}; do
    if ip link show tun0 >/dev/null 2>&1; then break; fi
    sleep 0.5
done
sleep 1
EOF
    chmod +x "$CONFIG_DIR/up.sh"

    # 生成 Service
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=UWM Tun2Socks
After=network.target warp-svc.service

[Service]
Type=simple
User=root
ExecStart=$BIN_TUN -c $TUN_CONFIG
Restart=always
RestartSec=3
EOF
    
    # 追加规则
    SSH_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    
    # 插入等待脚本
    echo "ExecStartPost=$CONFIG_DIR/up.sh" >> "$SERVICE_FILE"

    # SSH 保护 (仅 IPv4)
    if [[ -n "$SSH_IP" ]] && [[ "$SSH_IP" != *":"* ]]; then
        echo "ExecStartPost=$IP_CMD rule add from $SSH_IP lookup main pref 5" >> "$SERVICE_FILE"
        echo "ExecStop=$IP_CMD rule del from $SSH_IP lookup main pref 5" >> "$SERVICE_FILE"
    fi

    # 排除内网
    nets=("0.0.0.0/8" "10.0.0.0/8" "127.0.0.0/8" "169.254.0.0/16" "172.16.0.0/12" "192.168.0.0/16" "224.0.0.0/4" "240.0.0.0/4" "162.159.0.0/16" "188.114.96.0/20")
    for net in "${nets[@]}"; do
        echo "ExecStartPost=$IP_CMD rule add to $net lookup main pref 10" >> "$SERVICE_FILE"
        echo "ExecStop=$IP_CMD rule del to $net lookup main pref 10" >> "$SERVICE_FILE"
    done

    # 全局路由
    echo "ExecStartPost=$IP_CMD route add default dev tun0 table 100" >> "$SERVICE_FILE"
    echo "ExecStartPost=$IP_CMD rule add lookup 100 pref 20" >> "$SERVICE_FILE"
    echo "ExecStop=$IP_CMD route del default dev tun0 table 100" >> "$SERVICE_FILE"
    echo "ExecStop=$IP_CMD rule del lookup 100 pref 20" >> "$SERVICE_FILE"

    echo -e "\n[Install]\nWantedBy=multi-user.target" >> "$SERVICE_FILE"
    systemctl daemon-reload
}

install() {
    check_root; check_arch; check_tun; check_network
    info "安装 UWM ($ARCH)..."
    trap restore_dns EXIT; setup_dns64
    install_base; install_tun
    restore_dns; trap - EXIT
    configure
    [[ -f "$0" ]] && { cp "$0" "$BIN_WARP"; chmod +x "$BIN_WARP"; }
    success "安装完成"
}

# --- 控制 ---
is_on() { systemctl is-active --quiet uwm-tun2socks; }
w_on() {
    if is_on; then warn "已开启"; return; fi
    info "开启..."
    check_tun; warp-cli connect >/dev/null 2>&1
    configure # 刷新配置
    systemctl enable --now uwm-tun2socks
    sleep 3
    if is_on; then success "已开启"; echo "IP: $(curl -4 -s -m 3 ifconfig.me)"; else error "失败"; journalctl -xeu uwm-tun2socks | tail -n 5; fi
}
w_off() {
    if ! is_on; then warn "已关闭"; return; fi
    info "关闭..."
    systemctl stop uwm-tun2socks; systemctl disable uwm-tun2socks
    ip rule flush >/dev/null 2>&1
    success "已关闭"; echo "IP: $(curl -4 -s -m 3 ifconfig.me)"
}
w_chg() { w_off; warp-cli disconnect >/dev/null 2>&1; sleep 1; warp-cli connect >/dev/null 2>&1; sleep 3; w_on; }
w_new() { 
    w_off; load_config
    warp-cli disconnect >/dev/null 2>&1; warp-cli registration delete >/dev/null 2>&1; echo "y" | warp-cli registration new >/dev/null 2>&1
    [[ -n "$WARP_PLUS_KEY" ]] && warp-cli registration license "$WARP_PLUS_KEY" >/dev/null 2>&1
    warp-cli mode proxy >/dev/null 2>&1; warp-cli proxy port $SOCKS5_PORT >/dev/null 2>&1; warp-cli connect >/dev/null 2>&1; sleep 3
    w_on 
}
w_un() {
    read -p "确认卸载? (y/n): " c; [[ "$c" != "y" ]] && return
    systemctl stop uwm-tun2socks 2>/dev/null; systemctl disable uwm-tun2socks 2>/dev/null; rm -f "$SERVICE_FILE"; systemctl daemon-reload
    apt-get remove --purge cloudflare-warp -y; rm -rf "$CONFIG_DIR" "$BIN_WARP" "$BIN_TUN"
    ip rule del pref 5 2>/dev/null; ip rule del pref 10 2>/dev/null; ip rule del pref 20 2>/dev/null
    success "卸载完成"
}
w_acc() {
    load_config; echo -e "\n1) 免费\n2) WARP+\n3) 密钥"
    read -p "选: " c
    case $c in 1) WARP_PLUS_KEY=""; save_config; w_new;; 2) [[ -z "$WARP_PLUS_KEY" ]] && error "无密钥" || { warp-cli registration license "$WARP_PLUS_KEY"; success "OK"; };; 3) read -p "密钥: " k; WARP_PLUS_KEY="$k"; save_config; warp-cli registration license "$k" && success "OK";; esac
}
menu() {
    clear; echo -e "${C}══ UWM v1.0.5 ══${N}"; is_on && s="${G}ON${N}" || s="${R}OFF${N}"
    echo -e "状态: $s | IP: $(curl -4 -s -m 2 ifconfig.me)"
    echo "1.开启 2.关闭 3.换IP 4.新号 5.账户 6.卸载 0.退出"
    read -p "选: " n; case $n in 1) w_on;; 2) w_off;; 3) w_chg;; 4) w_new;; 5) w_acc;; 6) w_un;; 0) exit;; esac
}

[[ ! -f "$BIN_TUN" ]] && [[ -z "$1" ]] && { install; exit; }
case "$1" in on) w_on;; off) w_off;; change) w_chg;; change-full) w_new;; account) w_acc;; uninstall) w_un;; *) menu;; esac
```[done]
