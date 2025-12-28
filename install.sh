cat > warp.sh << 'EOF'
#!/bin/bash

#================================================================================
# Universal WARP Manager (UWM) - Refactored v2.0
# 核心改变: 采用 up/down 独立脚本分离逻辑，解决 Systemd 时序和语法报错问题
#================================================================================

# --- 配置定义 ---
CONFIG_DIR="/etc/uwm"
TUN_CONFIG="$CONFIG_DIR/tun2socks.yaml"
SCRIPT_UP="$CONFIG_DIR/up.sh"
SCRIPT_DOWN="$CONFIG_DIR/down.sh"
SERVICE_FILE="/etc/systemd/system/uwm-tun2socks.service"
BIN_WARP="/usr/local/bin/warp"
BIN_TUN="/usr/local/bin/tun2socks"
SOCKS5_PORT=40000

# 颜色
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'

# --- 辅助函数 ---
msg() { echo -e "${G}[OK]${N} $1"; }
err() { echo -e "${R}[ERR]${N} $1"; }
check_root() { [[ $EUID -ne 0 ]] && { err "需要 root 权限"; exit 1; }; }

# 1. 环境检查与依赖安装
install_base() {
    msg "安装基础依赖..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl gnupg2 jq iproute2 net-tools >/dev/null 2>&1
    
    # 纯IPv6环境 DNS 补丁
    if ! curl -4 -s -m 1 1.1.1.1 >/dev/null; then
        echo "nameserver 2a01:4f8:c2c:123f::1" > /etc/resolv.conf
    fi

    # 安装 WARP
    if ! command -v warp-cli >/dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
        apt-get update -y >/dev/null 2>&1; apt-get install -y cloudflare-warp >/dev/null 2>&1
    fi

    # 安装 Tun2Socks (固定稳定版)
    msg "安装 Tun2Socks..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) T_ARCH="linux-x86_64" ;;
        aarch64) T_ARCH="linux-arm64" ;;
        *) err "不支持的架构 $ARCH"; exit 1 ;;
    esac
    curl -L -o "$BIN_TUN" "https://github.com/heiher/hev-socks5-tunnel/releases/download/v2.6.1/hev-socks5-tunnel-$T_ARCH" --silent
    chmod +x "$BIN_TUN"
    
    # 检查 TUN 模块
    [[ ! -c /dev/net/tun ]] && { mkdir -p /dev/net; mknod /dev/net/tun c 10 200 2>/dev/null; }
}

# 2. 生成配置文件和控制脚本 (核心修复部分)
generate_config() {
    mkdir -p "$CONFIG_DIR"
    
    # WARP 初始化
    if ! warp-cli status | grep -q "Registration missing"; then warp-cli disconnect >/dev/null 2>&1; else echo "y" | warp-cli registration new >/dev/null 2>&1; fi
    warp-cli mode proxy >/dev/null 2>&1; warp-cli proxy port $SOCKS5_PORT >/dev/null 2>&1
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

    # 获取 SSH IP (用于白名单)
    SSH_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    
    # --- 生成 UP 脚本 (启动后执行) ---
    cat > "$SCRIPT_UP" <<EOF
#!/bin/bash
# 等待 tun0 设备创建 (至多5秒)
for i in {1..50}; do
    if ip link show tun0 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
sleep 0.5

# 基础路由
ip route add default dev tun0 table 100
ip rule add lookup 100 pref 20

# SSH 保护 (仅处理 IPv4, 忽略 IPv6)
if [[ -n "$SSH_IP" ]] && [[ "$SSH_IP" != *":"* ]]; then
    ip rule add from $SSH_IP lookup main pref 5
fi

# 排除内网和 CF 节点
nets=("0.0.0.0/8" "10.0.0.0/8" "127.0.0.0/8" "169.254.0.0/16" "172.16.0.0/12" "192.168.0.0/16" "224.0.0.0/4" "240.0.0.0/4" "162.159.0.0/16" "188.114.96.0/20")
for net in "\${nets[@]}"; do
    ip rule add to \$net lookup main pref 10
done
EOF
    chmod +x "$SCRIPT_UP"

    # --- 生成 DOWN 脚本 (停止后执行) ---
    cat > "$SCRIPT_DOWN" <<EOF
#!/bin/bash
ip rule del pref 5 2>/dev/null
ip rule del pref 10 2>/dev/null
ip rule del pref 20 2>/dev/null
ip route flush table 100 2>/dev/null
EOF
    chmod +x "$SCRIPT_DOWN"

    # --- 生成 Systemd 服务 ---
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Universal WARP Manager
After=network.target

[Service]
Type=simple
User=root
ExecStart=$BIN_TUN -c $TUN_CONFIG
ExecStartPost=$SCRIPT_UP
ExecStopPost=$SCRIPT_DOWN
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# 3. 功能控制
start_vpn() {
    msg "开启全局代理..."
    warp-cli connect >/dev/null 2>&1
    generate_config # 刷新配置以获取最新 SSH IP
    systemctl enable --now uwm-tun2socks
    sleep 3
    if systemctl is-active --quiet uwm-tun2socks; then 
        msg "启动成功"; echo -e "当前 IP: ${G}$(curl -4 -s -m 3 ifconfig.me)${N}"
    else
        err "启动失败"; journalctl -xeu uwm-tun2socks --no-pager | tail -n 5
    fi
}

stop_vpn() {
    msg "关闭全局代理..."
    systemctl stop uwm-tun2socks; systemctl disable uwm-tun2socks
    bash "$SCRIPT_DOWN"
    msg "已关闭"; echo -e "当前 IP: ${Y}$(curl -4 -s -m 3 ifconfig.me)${N}"
}

change_ip() { stop_vpn; warp-cli disconnect >/dev/null; sleep 1; warp-cli connect >/dev/null; sleep 3; start_vpn; }
change_full() { 
    stop_vpn; warp-cli disconnect >/dev/null; warp-cli registration delete >/dev/null
    echo "y" | warp-cli registration new >/dev/null
    warp-cli mode proxy >/dev/null; warp-cli proxy port $SOCKS5_PORT >/dev/null
    warp-cli connect >/dev/null; sleep 3; start_vpn
}

# 4. 菜单系统
show_menu() {
    clear
    echo -e "${G}Universal WARP Manager v2.0${N}"
    if systemctl is-active --quiet uwm-tun2socks; then echo -e "状态: ${G}已开启${N}"; else echo -e "状态: ${R}已关闭${N}"; fi
    echo -e "IP  : $(curl -4 -s -m 2 ifconfig.me)"
    echo "------------------------"
    echo "1. 开启代理"
    echo "2. 关闭代理"
    echo "3. 快速换IP"
    echo "4. 彻底换IP"
    echo "5. 卸载"
    echo "0. 退出"
    read -p "选择: " num
    case $num in 1) start_vpn;; 2) stop_vpn;; 3) change_ip;; 4) change_full;; 5) uninstall;; 0) exit;; esac
}

uninstall() {
    stop_vpn
    rm -f "$SERVICE_FILE" "$BIN_WARP" "$BIN_TUN"
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    apt-get remove --purge cloudflare-warp -y >/dev/null 2>&1
    msg "卸载完成"
}

# 主入口
check_root
if [[ ! -f "$BIN_TUN" ]] && [[ -z "$1" ]]; then
    install_base; generate_config
    cp "$0" "$BIN_WARP"; chmod +x "$BIN_WARP"
    msg "安装完成，输入 warp 使用"
    exit
fi

case "$1" in
    on) start_vpn;; off) stop_vpn;; change) change_ip;; change-full) change_full;; uninstall) uninstall;; *) show_menu;;
esac
EOF

# 赋予权限并执行安装
chmod +x warp.sh
./warp.sh
