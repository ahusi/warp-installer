#!/bin/bash

PROXY_PORT=40000
REDIR_PORT=12345
CONFIG_FILE="/etc/warp-cli-config"
IPTABLES_MARK="/tmp/warp_iptables_active"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
C='\033[0;36m'
N='\033[0m'

load_config() { [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"; }
save_config() { 
    echo "WARP_PLUS_KEY=\"$WARP_PLUS_KEY\"" > "$CONFIG_FILE"
    echo "VPS_IP=\"$VPS_IP\"" >> "$CONFIG_FILE"
}

get_vps_ip() {
    if [[ -n "$VPS_IP" ]]; then
        echo "$VPS_IP"
    else
        local ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
        [[ -z "$ip" ]] && ip=$(ip route get 1 2>/dev/null | awk '{print $7;exit}')
        echo "$ip"
    fi
}

setup_iptables() {
    local vps_ip=$(get_vps_ip)
    
    # 清理旧规则
    iptables -t nat -D OUTPUT -p tcp -j WARP_REDIRECT 2>/dev/null
    iptables -t nat -F WARP_REDIRECT 2>/dev/null
    iptables -t nat -X WARP_REDIRECT 2>/dev/null

    # 创建新链
    iptables -t nat -N WARP_REDIRECT 2>/dev/null

    # 排除本地和保留地址
    iptables -t nat -A WARP_REDIRECT -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 240.0.0.0/4 -j RETURN
    
    # 排除 VPS 自身 IP（防止 SSH 断开）
    [[ -n "$vps_ip" ]] && iptables -t nat -A WARP_REDIRECT -d "$vps_ip" -j RETURN
    
    # 排除 Cloudflare WARP 端点
    iptables -t nat -A WARP_REDIRECT -d 162.159.192.0/24 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 162.159.193.0/24 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 162.159.195.0/24 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 162.159.204.0/24 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 188.114.96.0/24 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 188.114.97.0/24 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 188.114.98.0/24 -j RETURN
    iptables -t nat -A WARP_REDIRECT -d 188.114.99.0/24 -j RETURN

    # 重定向 TCP 流量到 redsocks
    iptables -t nat -A WARP_REDIRECT -p tcp -j REDIRECT --to-ports $REDIR_PORT

    # 应用到 OUTPUT 链
    iptables -t nat -A OUTPUT -p tcp -j WARP_REDIRECT

    touch "$IPTABLES_MARK"
}

clear_iptables() {
    iptables -t nat -D OUTPUT -p tcp -j WARP_REDIRECT 2>/dev/null
    iptables -t nat -F WARP_REDIRECT 2>/dev/null
    iptables -t nat -X WARP_REDIRECT 2>/dev/null
    rm -f "$IPTABLES_MARK"
}

is_global_active() {
    [[ -f "$IPTABLES_MARK" ]] && iptables -t nat -L WARP_REDIRECT &>/dev/null
}

menu() {
    local status="关闭"
    is_global_active && status="开启"
    
    echo ""
    echo -e "${C}╔══════════════════════════════════════════╗${N}"
    echo -e "${C}║${N}        ${G}WARP 全局代理管理${N}                ${C}║${N}"
    echo -e "${C}╠══════════════════════════════════════════╣${N}"
    echo -e "${C}║${N}  全局代理状态: ${G}$status${N}                    ${C}║${N}"
    echo -e "${C}╠══════════════════════════════════════════╣${N}"
    echo -e "${C}║${N}  ${Y}warp on${N}           开启全局代理          ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp off${N}          关闭全局代理          ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp change${N}       快速换 IP             ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp change full${N}  彻底换 IP             ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp status${N}       查看状态              ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp ip${N}           查看 IP               ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp account${N}      账户管理              ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp proxy${N}        仅代理模式(关闭全局)  ${C}║${N}"
    echo -e "${C}║${N}  ${Y}warp uninstall${N}    卸载                  ${C}║${N}"
    echo -e "${C}╚══════════════════════════════════════════╝${N}"
    echo ""
}

warp_on() {
    echo -e "${Y}正在开启全局代理...${N}"
    
    # 确保 WARP 连接
    warp-cli connect 2>/dev/null
    sleep 2
    
    # 启动 redsocks
    pkill redsocks 2>/dev/null
    sleep 1
    redsocks -c /etc/redsocks.conf 2>/dev/null
    sleep 1
    
    # 设置 iptables
    setup_iptables
    
    echo -e "${G}✓ 全局代理已开启${N}"
    echo -e "当前出站 IP: ${G}$(curl -4 -s --max-time 10 ifconfig.me)${N}"
}

warp_off() {
    echo -e "${Y}正在关闭全局代理...${N}"
    
    # 清理 iptables
    clear_iptables
    
    # 停止 redsocks
    pkill redsocks 2>/dev/null
    
    echo -e "${G}✓ 全局代理已关闭${N}"
    echo -e "当前出站 IP: ${G}$(curl -4 -s --max-time 10 ifconfig.me)${N}"
}

warp_proxy() {
    echo -e "${Y}切换到仅代理模式...${N}"
    
    # 关闭全局代理
    clear_iptables
    pkill redsocks 2>/dev/null
    
    # 确保 WARP 连接
    warp-cli connect 2>/dev/null
    
    echo -e "${G}✓ 已切换到仅代理模式${N}"
    echo -e "代理地址: ${G}socks5://127.0.0.1:$PROXY_PORT${N}"
    echo -e "直连 IP: ${G}$(curl -4 -s --max-time 10 ifconfig.me)${N}"
    echo -e "代理 IP: ${G}$(curl -4 -s --max-time 10 ifconfig.me --proxy socks5://127.0.0.1:$PROXY_PORT)${N}"
}

warp_change() {
    echo -e "${Y}正在更换 IP...${N}"
    local old_ip=$(curl -4 -s --max-time 5 ifconfig.me)
    
    # 临时关闭全局代理
    local was_active=false
    if is_global_active; then
        was_active=true
        clear_iptables
        pkill redsocks 2>/dev/null
    fi
    
    # 重连 WARP
    warp-cli disconnect 2>/dev/null
    sleep 1
    warp-cli connect 2>/dev/null
    sleep 3
    
    # 恢复全局代理
    if $was_active; then
        redsocks -c /etc/redsocks.conf 2>/dev/null
        sleep 1
        setup_iptables
    fi
    
    local new_ip=$(curl -4 -s --max-time 10 ifconfig.me)
    echo -e "旧 IP: ${Y}$old_ip${N}"
    echo -e "新 IP: ${G}$new_ip${N}"
}

warp_change_full() {
    load_config
    echo -e "${Y}正在彻底更换 IP（重新注册）...${N}"
    local old_ip=$(curl -4 -s --max-time 5 ifconfig.me)
    
    # 临时关闭全局代理
    local was_active=false
    if is_global_active; then
        was_active=true
        clear_iptables
        pkill redsocks 2>/dev/null
    fi
    
    # 重新注册
    warp-cli disconnect 2>/dev/null
    warp-cli registration delete 2>/dev/null
    sleep 1
    echo "y" | warp-cli registration new
    
    # 绑定 WARP+ 密钥
    if [[ -n "$WARP_PLUS_KEY" ]]; then
        warp-cli registration license "$WARP_PLUS_KEY" 2>/dev/null && \
            echo -e "${G}✓ WARP+ 已绑定${N}"
    fi
    
    warp-cli mode proxy
    warp-cli proxy port $PROXY_PORT
    warp-cli connect
    sleep 3
    
    # 恢复全局代理
    if $was_active; then
        redsocks -c /etc/redsocks.conf 2>/dev/null
        sleep 1
        setup_iptables
    fi
    
    local new_ip=$(curl -4 -s --max-time 10 ifconfig.me)
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
    echo -e "${B}══════════ IP 信息 ══════════${N}"
    echo -e "当前出站 IP: ${G}$(curl -4 -s --max-time 10 ifconfig.me)${N}"
    echo -e "代理 IP:     ${G}$(curl -4 -s --max-time 10 ifconfig.me --proxy socks5://127.0.0.1:$PROXY_PORT 2>/dev/null || echo '代理未运行')${N}"
    
    load_config
    if [[ -n "$VPS_IP" ]]; then
        echo -e "VPS 原始 IP: ${Y}$VPS_IP${N}"
    fi
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
            if is_global_active; then
                was_active=true
                clear_iptables
                pkill redsocks 2>/dev/null
            fi
            
            warp-cli disconnect 2>/dev/null
            warp-cli registration delete 2>/dev/null
            echo "y" | warp-cli registration new
            warp-cli mode proxy
            warp-cli proxy port $PROXY_PORT
            warp-cli connect
            sleep 2
            
            if $was_active; then
                redsocks -c /etc/redsocks.conf 2>/dev/null
                sleep 1
                setup_iptables
            fi
            
            echo -e "${G}✓ 已切换到免费账户${N}"
            ;;
        2)
            if [[ -z "$WARP_PLUS_KEY" ]]; then
                echo -e "${R}请先设置 WARP+ 密钥（选择 3）${N}"
                return
            fi
            
            echo -e "${Y}正在切换到 WARP+...${N}"
            local was_active=false
            if is_global_active; then
                was_active=true
                clear_iptables
                pkill redsocks 2>/dev/null
            fi
            
            warp-cli disconnect 2>/dev/null
            warp-cli registration delete 2>/dev/null
            echo "y" | warp-cli registration new
            warp-cli registration license "$WARP_PLUS_KEY"
            warp-cli mode proxy
            warp-cli proxy port $PROXY_PORT
            warp-cli connect
            sleep 2
            
            if $was_active; then
                redsocks -c /etc/redsocks.conf 2>/dev/null
                sleep 1
                setup_iptables
            fi
            
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
    
    if [[ "$confirm" != "yes" ]]; then
        echo "已取消"
        return
    fi
    
    echo -e "${Y}正在卸载...${N}"
    
    # 关闭全局代理
    clear_iptables
    pkill redsocks 2>/dev/null
    
    # 断开 WARP
    warp-cli disconnect 2>/dev/null
    warp-cli registration delete 2>/dev/null
    
    # 卸载软件
    apt remove --purge cloudflare-warp redsocks -y 2>/dev/null
    
    # 清理文件
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -f /etc/redsocks.conf
    rm -f "$CONFIG_FILE"
    rm -f "$IPTABLES_MARK"
    rm -f /usr/local/bin/warp
    
    sed -i '/precedence ::ffff:0:0\/96 100/d' /etc/gai.conf 2>/dev/null
    
    echo -e "${G}✓ 卸载完成${N}"
}

# 主入口
load_config

case "$1" in
    on|start)
        warp_on
        ;;
    off|stop)
        warp_off
        ;;
    proxy)
        warp_proxy
        ;;
    change|renew)
        if [[ "$2" == "full" ]]; then
            warp_change_full
        else
            warp_change
        fi
        ;;
    status)
        warp_status
        ;;
    ip)
        warp_ip
        ;;
    account)
        warp_account
        ;;
    uninstall|remove)
        warp_uninstall
        ;;
    *)
        menu
        ;;
esac
