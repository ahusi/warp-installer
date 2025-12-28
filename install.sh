#!/bin/bash
#===============================================
# WARP-CLI 一键安装脚本（支持 IPv4/IPv6 全局代理）
#===============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROXY_PORT=40000
TUN_NAME="warp0"

log_info() { echo -e "${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "${GREEN}[成功]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 运行"
        exit 1
    fi
}

detect_network() {
    log_info "检测网络环境..."
    
    HAS_IPV4=false
    HAS_IPV6=false
    
    if curl -4 -s --max-time 5 ifconfig.me &>/dev/null; then
        HAS_IPV4=true
        log_success "检测到 IPv4 网络"
    fi
    
    if curl -6 -s --max-time 5 ifconfig.me &>/dev/null; then
        HAS_IPV6=true
        log_success "检测到 IPv6 网络"
    fi
    
    if ! $HAS_IPV4 && ! $HAS_IPV6; then
        log_error "无法检测到网络连接"
        exit 1
    fi
    
    if ! $HAS_IPV4 && $HAS_IPV6; then
        log_warn "检测到纯 IPv6 环境"
        setup_github_hosts
    fi
}

setup_github_hosts() {
    log_info "添加 GitHub IPv6 Hosts..."
    
    if ! grep -q "github.com" /etc/hosts; then
        cat >> /etc/hosts << 'EOF'
# GitHub IPv6 Hosts
2a01:4f8:c010:d56::2 github.com
2a01:4f8:c010:d56::3 api.github.com
2a01:4f8:c010:d56::4 codeload.github.com
2a01:4f8:c010:d56::6 ghcr.io
2a01:4f8:c010:d56::7 pkg.github.com npm.pkg.github.com maven.pkg.github.com nuget.pkg.github.com rubygems.pkg.github.com
2a01:4f8:c010:d56::8 uploads.github.com
2606:50c0:8000::133 objects.githubusercontent.com raw.githubusercontent.com
2606:50c0:8000::154 github.githubassets.com
EOF
        log_success "GitHub Hosts 已添加"
    fi
}

setup_ipv4_priority() {
    log_info "设置 IPv4 优先..."
    grep -q "precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null || \
        echo 'precedence ::ffff:0:0/96 100' >> /etc/gai.conf
}

install_dependencies() {
    log_info "安装依赖..."
    apt update
    apt install -y gnupg curl lsb-release iptables iproute2 unzip
}

install_warp_cli() {
    log_info "安装 WARP-CLI..."
    
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | \
        tee /etc/apt/sources.list.d/cloudflare-client.list
    
    apt update && apt install -y cloudflare-warp
    
    log_success "WARP-CLI 安装完成"
}

install_tun2socks() {
    log_info "安装 tun2socks..."
    
    local ARCH=$(uname -m)
    local TUN2SOCKS_URL=""
    
    case $ARCH in
        x86_64|amd64)
            TUN2SOCKS_URL="https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-amd64.zip"
            ;;
        aarch64|arm64)
            TUN2SOCKS_URL="https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-arm64.zip"
            ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    
    cd /tmp
    curl -L -o tun2socks.zip "$TUN2SOCKS_URL"
    unzip -o tun2socks.zip
    mv tun2socks-linux-* /usr/local/bin/tun2socks 2>/dev/null || mv tun2socks /usr/local/bin/tun2socks
    chmod +x /usr/local/bin/tun2socks
    rm -f tun2socks.zip
    
    log_success "tun2socks 安装完成"
}

configure_warp() {
    log_info "配置 WARP..."
    
    sleep 2
    
    warp-cli registration delete 2>/dev/null || true
    echo "y" | warp-cli registration new
    warp-cli mode proxy
    warp-cli proxy port $PROXY_PORT
    warp-cli connect
    
    sleep 3
    
    local retry=0
    while [[ $retry -lt 5 ]]; do
        if warp-cli status 2>/dev/null | grep -q "Connected"; then
            log_success "WARP 已连接"
            return 0
        fi
        retry=$((retry + 1))
        sleep 2
    done
    
    log_warn "WARP 连接状态未知，继续安装..."
}

create_tun2socks_service() {
    log_info "创建 tun2socks 服务..."
    
    cat > /etc/systemd/system/tun2socks.service << EOF
[Unit]
Description=tun2socks
After=network.target warp-svc.service
Wants=warp-svc.service

[Service]
Type=simple
ExecStart=/usr/local/bin/tun2socks -device $TUN_NAME -proxy socks5://127.0.0.1:$PROXY_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_success "tun2socks 服务已创建"
}

save_network_info() {
    local iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    local gateway=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    local vps_ip=""
    
    if $HAS_IPV4; then
        vps_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
    fi
    
    cat > /etc/warp-network.conf << EOF
DEFAULT_IFACE="$iface"
DEFAULT_GATEWAY="$gateway"
VPS_IP="$vps_ip"
HAS_IPV4=$HAS_IPV4
HAS_IPV6=$HAS_IPV6
EOF
    
    log_success "网络信息已保存"
}

install_warp_command() {
    log_info "安装 warp 命令..."

    cat > /usr/local/bin/warp << 'WARPEOF'
#!/bin/bash

PROXY_PORT=40000
TUN_NAME="warp0"
CONFIG_FILE="/etc/warp-cli-config"
NETWORK_FILE="/etc/warp-network.conf"
GLOBAL_MARK="/tmp/warp_global_active"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
C='\033[0;36m'
N='\033[0m'

load_config() { 
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    [[ -f "$NETWORK_FILE" ]] && source "$NETWORK_FILE"
}

save_config() { 
    echo "WARP_PLUS_KEY=\"$WARP_PLUS_KEY\"" > "$CONFIG_FILE"
}

is_global_active() {
    [[ -f "$GLOBAL_MARK" ]] && ip link show $TUN_NAME &>/dev/null
}

get_current_ip() {
    local ip=""
    ip=$(curl -4 -s --max-time 10 ifconfig.me --proxy socks5://127.0.0.1:$PROXY_PORT 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --max-time 10 ifconfig.me 2>/dev/null)
    fi
    echo "$ip"
}

setup_global_proxy() {
    load_config
    
    systemctl start tun2socks
    sleep 2
    
    local retry=0
    while [[ $retry -lt 10 ]]; do
        if ip link show $TUN_NAME &>/dev/null; then
            break
        fi
        retry=$((retry + 1))
        sleep 1
    done
    
    if ! ip link show $TUN_NAME &>/dev/null; then
        echo -e "${R}TUN 设备创建失败${N}"
        return 1
    fi
    
    ip addr add 10.0.0.1/24 dev $TUN_NAME 2>/dev/null
    ip link set $TUN_NAME up
    
    local gateway="$DEFAULT_GATEWAY"
    local iface="$DEFAULT_IFACE"
    
    if [[ -z "$gateway" ]] || [[ -z "$iface" ]]; then
        gateway=$(ip route show default | awk '/default/ {print $3; exit}')
        iface=$(ip route show default | awk '/default/ {print $5; exit}')
    fi
    
    # 保存原始路由
    ip route show default > /tmp/warp_original_route 2>/dev/null
    
    # WARP 端点走原始网关
    for net in 162.159.192.0/24 162.159.193.0/24 162.159.195.0/24 162.159.204.0/24 \
               188.114.96.0/24 188.114.97.0/24 188.114.98.0/24 188.114.99.0/24; do
        ip route add $net via $gateway dev $iface 2>/dev/null
    done
    
    # VPS IP 走原始网关
    [[ -n "$VPS_IP" ]] && ip route add $VPS_IP via $gateway dev $iface 2>/dev/null
    
    # SSH 客户端走原始网关
    local ssh_client=$(echo $SSH_CLIENT | awk '{print $1}')
    [[ -n "$ssh_client" ]] && ip route add $ssh_client via $gateway dev $iface 2>/dev/null
    
    # 设置默认路由走 TUN
    ip route del default 2>/dev/null
    ip route add default dev $TUN_NAME metric 1
    ip route add default via $gateway dev $iface metric 100 2>/dev/null
    
    touch "$GLOBAL_MARK"
}

clear_global_proxy() {
    load_config
    
    systemctl stop tun2socks 2>/dev/null
    
    local gateway="$DEFAULT_GATEWAY"
    local iface="$DEFAULT_IFACE"
    
    ip route del default dev $TUN_NAME 2>/dev/null
    
    if [[ -n "$gateway" ]] && [[ -n "$iface" ]]; then
        ip route del default 2>/dev/null
        ip route add default via $gateway dev $iface 2>/dev/null
    fi
    
    for net in 162.159.192.0/24 162.159.193.0/24 162.159.195.0/24 162.159.204.0/24 \
               188.114.96.0/24 188.114.97.0/24 188.114.98.0/24 188.114.99.0/24; do
        ip route del $net 2>/dev/null
    done
    
    ip link del $TUN_NAME 2>/dev/null
    
    rm -f "$GLOBAL_MARK"
}

menu() {
    local status="${R}关闭${N}"
    is_global_active && status="${G}开启${N}"
    
    echo ""
    echo -e "${C}╔══════════════════════════════════════════╗${N}"
    echo -e "${C}║${N}        ${G}WARP 全局代理管理${N}                ${C}║${N}"
    echo -e "${C}╠══════════════════════════════════════════╣${N}"
    echo -e "${C}║${N}  全局代理状态: $status                       ${C}║${N}"
    echo -e "${C}╠══════════════════════════════════════════╣${N}"
    echo -e "${C}║${N}  ${Y}warp on${N}           开启全局代理          ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp off${N}          关闭全局代理          ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp change${N}       快速换 IP             ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp change full${N}  彻底换 IP             ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp status${N}       查看状态              ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp ip${N}           查看 IP               ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp account${N}      账户管理              ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp proxy${N}        仅代理模式            ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp uninstall${N}    卸载                  ${C}║${N}"
    echo -e "${C}╚══════════════════════════════════════════╝${N}"
    echo ""
}

warp_on() {
    echo -e "${Y}正在开启全局代理...${N}"
    warp-cli connect 2>/dev/null
    sleep 2
    setup_global_proxy
    sleep 2
    echo -e "${G}✓ 全局代理已开启${N}"
    echo -e "当前出站 IP: ${G}$(get_current_ip)${N}"
}

warp_off() {
    echo -e "${Y}正在关闭全局代理...${N}"
    clear_global_proxy
    sleep 2
    echo -e "${G}✓ 全局代理已关闭${N}"
    local ip=$(curl -s --max-time 10 ifconfig.me 2>/dev/null)
    echo -e "当前出站 IP: ${G}${ip:-获取中...}${N}"
}

warp_proxy() {
    echo -e "${Y}切换到仅代理模式...${N}"
    clear_global_proxy
    warp-cli connect 2>/dev/null
    echo -e "${G}✓ 已切换到仅代理模式${N}"
    echo -e "代理地址: ${G}socks5://127.0.0.1:$PROXY_PORT${N}"
    echo -e "代理 IP: ${G}$(curl -4 -s --max-time 10 ifconfig.me --proxy socks5://127.0.0.1:$PROXY_PORT 2>/dev/null)${N}"
}

warp_change() {
    echo -e "${Y}正在更换 IP...${N}"
    local old_ip=$(get_current_ip)
    
    local was_active=false
    is_global_active && was_active=true
    
    $was_active && clear_global_proxy
    
    warp-cli disconnect 2>/dev/null
    sleep 1
    warp-cli connect 2>/dev/null
    sleep 3
    
    $was_active && setup_global_proxy && sleep 2
    
    local new_ip=$(get_current_ip)
    echo -e "旧 IP: ${Y}$old_ip${N}"
    echo -e "新 IP: ${G}$new_ip${N}"
}

warp_change_full() {
    load_config
    echo -e "${Y}正在彻底更换 IP（重新注册）...${N}"
    local old_ip=$(get_current_ip)
    
    local was_active=false
    is_global_active && was_active=true
    
    $was_active && clear_global_proxy
    
    warp-cli disconnect 2>/dev/null
    warp-cli registration delete 2>/dev/null
    sleep 1
    echo "y" | warp-cli registration new
    
    if [[ -n "$WARP_PLUS_KEY" ]]; then
        warp-cli registration license "$WARP_PLUS_KEY" 2>/dev/null && \
            echo -e "${G}✓ WARP+ 已绑定${N}"
    fi
    
    warp-cli mode proxy
    warp-cli proxy port $PROXY_PORT
    warp-cli connect
    sleep 3
    
    $was_active && setup_global_proxy && sleep 2
    
    local new_ip=$(get_current_ip)
    echo -e "旧 IP: ${Y}$old_ip${N}"
    echo -e "新 IP: ${G}$new_ip${N}"
}

warp_status() {
    echo -e "${B}══════════ WARP 状态 ══════════${N}"
    warp-cli status
    echo ""
    echo -e "${B}══════════ 全局代理 ══════════${N}"
    if is_global_active; then
        echo -e "状态: ${G}已开启${N}"
        echo -e "TUN 设备: ${G}$TUN_NAME${N}"
    else
        echo -e "状态: ${Y}已关闭${N}"
    fi
    echo ""
    echo -e "${B}══════════ 账户信息 ══════════${N}"
    warp-cli registration show 2>/dev/null || echo "未注册"
    echo ""
    echo -e "Socks5 代理: ${G}socks5://127.0.0.1:$PROXY_PORT${N}"
}

warp_ip() {
    load_config
    echo -e "${B}══════════ IP 信息 ══════════${N}"
    echo -e "当前出站 IP: ${G}$(get_current_ip)${N}"
    echo -e "代理 IP:     ${G}$(curl -4 -s --max-time 10 ifconfig.me --proxy socks5://127.0.0.1:$PROXY_PORT 2>/dev/null || echo '获取失败')${N}"
    [[ -n "$VPS_IP" ]] && echo -e "VPS 原始 IP: ${Y}$VPS_IP${N}"
}

warp_account() {
    load_config
    echo ""
    echo -e "${B}══════════ 账户管理 ══════════${N}"
    echo ""
    echo "1) 使用免费账户"
    echo "2) 使用 WARP+"
    echo "3) 设置 WARP+ 密钥"
    echo "4) 查看当前账户"
    echo "0) 返回"
    echo ""
    read -p "选择: " c
    
    case $c in
        1)
            echo -e "${Y}正在切换到免费账户...${N}"
            local was_active=false
            is_global_active && { was_active=true; clear_global_proxy; }
            
            warp-cli disconnect 2>/dev/null
            warp-cli registration delete 2>/dev/null
            echo "y" | warp-cli registration new
            warp-cli mode proxy
            warp-cli proxy port $PROXY_PORT
            warp-cli connect
            sleep 2
            
            $was_active && setup_global_proxy
            echo -e "${G}✓ 已切换到免费账户${N}"
            ;;
        2)
            if [[ -z "$WARP_PLUS_KEY" ]]; then
                echo -e "${R}请先设置 WARP+ 密钥（选择 3）${N}"
                return
            fi
            
            echo -e "${Y}正在切换到 WARP+...${N}"
            local was_active=false
            is_global_active && { was_active=true; clear_global_proxy; }
            
            warp-cli disconnect 2>/dev/null
            warp-cli registration delete 2>/dev/null
            echo "y" | warp-cli registration new
            warp-cli registration license "$WARP_PLUS_KEY"
            warp-cli mode proxy
            warp-cli proxy port $PROXY_PORT
            warp-cli connect
            sleep 2
            
            $was_active && setup_global_proxy
            echo -e "${G}✓ 已切换到 WARP+${N}"
            ;;
        3)
            echo ""
            echo -e "${Y}WARP+ 密钥格式: xxxxxxxx-xxxxxxxx-xxxxxxxx (26位)${N}"
            read -p "输入密钥: " k
            if [[ ${#k} -eq 26 ]]; then
                WARP_PLUS_KEY="$k"
                save_config
                echo -e "${G}✓ 密钥已保存${N}"
            else
                echo -e "${R}格式错误，应为 26 位${N}"
            fi
            ;;
        4)
            echo ""
            warp-cli registration show 2>/dev/null || echo "未注册"
            echo ""
            if [[ -n "$WARP_PLUS_KEY" ]]; then
                echo -e "已保存密钥: ${G}${WARP_PLUS_KEY:0:8}****${WARP_PLUS_KEY: -8}${N}"
            else
                echo "未保存 WARP+ 密钥"
            fi
            ;;
    esac
}

warp_uninstall() {
    echo ""
    echo -e "${R}警告: 即将完全卸载 WARP${N}"
    read -p "确认卸载？(输入 yes): " confirm
    
    [[ "$confirm" != "yes" ]] && { echo "已取消"; return; }
    
    echo -e "${Y}正在卸载...${N}"
    
    clear_global_proxy
    
    systemctl stop tun2socks 2>/dev/null
    systemctl disable tun2socks 2>/dev/null
    
    warp-cli disconnect 2>/dev/null
    warp-cli registration delete 2>/dev/null
    
    apt remove --purge cloudflare-warp -y 2>/dev/null
    
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -f /etc/systemd/system/tun2socks.service
    rm -f /usr/local/bin/tun2socks
    rm -f "$CONFIG_FILE" "$NETWORK_FILE" "$GLOBAL_MARK"
    rm -f /usr/local/bin/warp /usr/bin/warp
    
    systemctl daemon-reload
    sed -i '/precedence ::ffff:0:0\/96 100/d' /etc/gai.conf 2>/dev/null
    
    echo -e "${G}✓ 卸载完成${N}"
}

load_config

case "$1" in
    on|start) warp_on ;;
    off|stop) warp_off ;;
    proxy) warp_proxy ;;
    change|renew) [[ "$2" == "full" ]] && warp_change_full || warp_change ;;
    status) warp_status ;;
    ip) warp_ip ;;
    account) warp_account ;;
    uninstall|remove) warp_uninstall ;;
    *) menu ;;
esac
WARPEOF

    chmod +x /usr/local/bin/warp
    ln -sf /usr/local/bin/warp /usr/bin/warp 2>/dev/null
    
    log_success "warp 命令已安装"
}

enable_global_proxy() {
    log_info "启用全局代理..."
    /usr/local/bin/warp on
}

show_result() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}         安装完成！${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo ""
    echo -e "全局代理已自动开启"
    echo ""
    echo -e "当前出站 IP: ${GREEN}$(curl -4 -s --max-time 10 ifconfig.me --proxy socks5://127.0.0.1:$PROXY_PORT 2>/dev/null || echo '获取中...')${NC}"
    echo ""
    echo -e "输入 ${YELLOW}warp${NC} 查看命令菜单"
    echo ""
    echo -e "${BLUE}常用命令:${NC}"
    echo -e "  ${YELLOW}warp on${NC}      - 开启全局代理"
    echo -e "  ${YELLOW}warp off${NC}     - 关闭全局代理"
    echo -e "  ${YELLOW}warp ip${NC}      - 查看当前 IP"
    echo -e "  ${YELLOW}warp change${NC}  - 更换 IP"
    echo -e "  ${YELLOW}warp account${NC} - 设置 WARP+"
    echo ""
}

main() {
    check_root
    detect_network
    setup_ipv4_priority
    install_dependencies
    install_warp_cli
    install_tun2socks
    configure_warp
    create_tun2socks_service
    save_network_info
    install_warp_command
    enable_global_proxy
    show_result
}

main
