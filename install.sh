#!/bin/bash

#===============================================
# WARP-CLI 一键安装脚本
#===============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PROXY_PORT=40000

log_info() { echo -e "${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "${GREEN}[成功]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && { log_error "请使用 root 运行"; exit 1; }
}

setup_ipv4_priority() {
    log_info "设置 IPv4 优先..."
    grep -q "precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null || \
        echo 'precedence ::ffff:0:0/96 100' >> /etc/gai.conf
}

install_warp_cli() {
    log_info "更新软件源..."
    apt update
    apt install -y gnupg curl lsb-release

    log_info "添加 Cloudflare 源..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | \
        tee /etc/apt/sources.list.d/cloudflare-client.list

    log_info "安装 WARP-CLI..."
    apt update && apt install -y cloudflare-warp
    log_success "WARP-CLI 安装完成"
}

configure_warp() {
    log_info "配置 WARP..."
    warp-cli registration delete 2>/dev/null || true
    echo "y" | warp-cli registration new
    warp-cli mode proxy
    warp-cli proxy port $PROXY_PORT
    warp-cli connect
    sleep 3
    log_success "WARP 已连接"
}

install_command() {
    log_info "安装 warp 命令..."
    cat > /usr/local/bin/warp << 'EOF'
#!/bin/bash
PORT=40000
CFG="/etc/warp-cli-config"
R='\033[0;31m';G='\033[0;32m';Y='\033[1;33m';B='\033[0;34m';C='\033[0;36m';N='\033[0m'

load(){ [[ -f "$CFG" ]]&&source "$CFG"; }
save(){ echo "WARP_PLUS_KEY=\"$WARP_PLUS_KEY\"">"$CFG"; }

menu(){
    echo -e "\n${C}╔══════════════════════════════════════╗${N}"
    echo -e "${C}║${N}      ${G}WARP 简化命令菜单${N}              ${C}║${N}"
    echo -e "${C}╠══════════════════════════════════════╣${N}"
    echo -e "${C}║${N}  ${Y}warp on${N}          开启 WARP         ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp off${N}         关闭 WARP         ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp change${N}      快速换 IP         ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp change full${N} 彻底换 IP         ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp status${N}      查看状态          ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp ip${N}          查看 IP           ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp account${N}     账户管理          ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp uninstall${N}   卸载              ${C}║${N}"
    echo -e "${C}╚══════════════════════════════════════╝${N}\n"
}

on(){ warp-cli connect;sleep 2;echo -e "${G}✓ 已连接 IP: $(curl -4 -s ifconfig.me)${N}"; }
off(){ warp-cli disconnect;echo -e "${G}✓ 已断开${N}"; }

change(){
    echo -e "${Y}更换 IP...${N}"
    old=$(curl -4 -s ifconfig.me)
    warp-cli disconnect;sleep 1;warp-cli connect;sleep 3
    new=$(curl -4 -s ifconfig.me)
    echo -e "旧: ${Y}$old${N}\n新: ${G}$new${N}"
}

change_full(){
    load
    echo -e "${Y}彻底更换 IP...${N}"
    old=$(curl -4 -s ifconfig.me)
    warp-cli disconnect 2>/dev/null
    warp-cli registration delete 2>/dev/null
    echo "y"|warp-cli registration new
    [[ -n "$WARP_PLUS_KEY" ]]&&warp-cli registration license "$WARP_PLUS_KEY" 2>/dev/null
    warp-cli mode proxy;warp-cli proxy port $PORT;warp-cli connect;sleep 3
    new=$(curl -4 -s ifconfig.me)
    echo -e "旧: ${Y}$old${N}\n新: ${G}$new${N}"
}

status(){
    echo -e "${B}══ 状态 ══${N}"
    warp-cli status
    warp-cli registration show 2>/dev/null
    echo -e "代理: ${G}socks5://127.0.0.1:$PORT${N}"
}

ip(){
    echo -e "直连: ${G}$(curl -4 -s ifconfig.me)${N}"
    echo -e "代理: ${G}$(curl -4 -s ifconfig.me --proxy socks5://127.0.0.1:$PORT 2>/dev/null||echo 未运行)${N}"
}

account(){
    load
    echo -e "\n1) 免费账户\n2) WARP+\n3) 设置密钥\n4) 查看账户\n0) 返回\n"
    read -p "选择: " c
    case $c in
        1) warp-cli disconnect 2>/dev/null;warp-cli registration delete 2>/dev/null
           echo "y"|warp-cli registration new
           warp-cli mode proxy;warp-cli proxy port $PORT;warp-cli connect
           echo -e "${G}✓ 免费账户${N}";;
        2) [[ -z "$WARP_PLUS_KEY" ]]&&{ echo -e "${R}请先设置密钥${N}";return; }
           warp-cli disconnect 2>/dev/null;warp-cli registration delete 2>/dev/null
           echo "y"|warp-cli registration new
           warp-cli registration license "$WARP_PLUS_KEY"
           warp-cli mode proxy;warp-cli proxy port $PORT;warp-cli connect
           echo -e "${G}✓ WARP+${N}";;
        3) read -p "输入密钥(26位): " k
           [[ ${#k} -eq 26 ]]&&{ WARP_PLUS_KEY="$k";save;echo -e "${G}✓ 已保存${N}"; }||echo -e "${R}格式错误${N}";;
        4) warp-cli registration show 2>/dev/null
           [[ -n "$WARP_PLUS_KEY" ]]&&echo -e "密钥: ${G}${WARP_PLUS_KEY:0:8}...${N}";;
    esac
}

uninstall(){
    read -p "确认卸载?(yes): " c
    [[ "$c" != "yes" ]]&&return
    warp-cli disconnect 2>/dev/null
    warp-cli registration delete 2>/dev/null
    apt remove --purge cloudflare-warp -y
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -f "$CFG" /usr/local/bin/warp
    sed -i '/precedence ::ffff:0:0\/96 100/d' /etc/gai.conf 2>/dev/null
    echo -e "${G}✓ 已卸载${N}"
}

load
case "$1" in
    on) on;;
    off) off;;
    change) [[ "$2" == "full" ]]&&change_full||change;;
    status) status;;
    ip) ip;;
    account) account;;
    uninstall) uninstall;;
    *) menu;;
esac
EOF
    chmod +x /usr/local/bin/warp
    log_success "warp 命令已安装"
}

show_result(){
    echo ""
    echo -e "${GREEN}════════════════════════════════════${NC}"
    echo -e "${GREEN}       安装完成！${NC}"
    echo -e "${GREEN}════════════════════════════════════${NC}"
    echo -e "输入 ${YELLOW}warp${NC} 查看命令菜单"
    echo -e "代理地址: ${GREEN}socks5://127.0.0.1:$PROXY_PORT${NC}"
    echo -e "当前 IP: ${GREEN}$(curl -4 -s ifconfig.me)${NC}"
    echo ""
}

main(){
    check_root
    setup_ipv4_priority
    install_warp_cli
    configure_warp
    install_command
    show_result
}

main
