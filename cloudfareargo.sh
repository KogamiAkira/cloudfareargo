#!/usr/bin/env bash
set -euo pipefail

IS_ROOT=false
if [ "$(id -u)" -eq 0 ]; then
  IS_ROOT=true
fi

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
cyan='\033[1;36m'
bold='\033[1m'
re='\033[0m'

if $IS_ROOT; then
    CRED_DIR="/root/.cloudflared"
else
    CRED_DIR="$HOME/.cloudflared"
fi
CLOUD_BIN="${CRED_DIR}/cloudflared"
TOKEN_FILE="${CRED_DIR}/token"
MODE_FILE="${CRED_DIR}/tunnel_mode"
DOMAIN_FILE="${CRED_DIR}/domain"

check_running() {
    systemctl is-active --quiet cloudflared 2>/dev/null && return 0
    systemctl --user is-active --quiet cloudflared 2>/dev/null && return 0
    return 1
}

get_temp_domain() {
    journalctl -u cloudflared -n 300 --no-pager 2>/dev/null \
        | grep -oE '[a-zA-Z0-9-]+\.trycloudflare\.com' \
        | tail -n 1 || true
}

verify_temp_domain() {
    local d="$1"
    [ -z "$d" ] && return 1
    curl -sI -m 10 "https://${d}" >/dev/null 2>&1
}

show_status_box() {
    echo -e "${cyan}------------------------------------------${re}"
    if [ ! -x "$CLOUD_BIN" ]; then
        echo -e " 当前状态: ${yellow}未安装${re}"
        echo -e " 请安装固定隧道或临时隧道"
    elif ! check_running; then
        echo -e " 当前状态: ${yellow}服务未运行${re}"
    else
        local mode domain
        mode=$(cat "$MODE_FILE" 2>/dev/null || echo "")
        if [ "$mode" = "fixed" ]; then
            echo -e " 当前状态: ${yellow}固定隧道${re}"
            domain=$(cat "$DOMAIN_FILE" 2>/dev/null || echo "")
            if [ -n "$domain" ]; then
                echo -e " 当前域名: ${green}${bold}${domain}${re}"
            else
                echo -e " 当前域名: ${yellow}未记录${re}"
            fi
        elif [ "$mode" = "temp" ]; then
            echo -e " 当前状态: ${yellow}临时隧道${re}"
            domain=$(get_temp_domain)
            if [ -n "$domain" ]; then
                echo -e " 当前域名: ${green}${bold}${domain}${re}"
                if verify_temp_domain "$domain"; then
                    echo -e " 状态: ${green}有效${re}"
                else
                    echo -e " 状态: ${yellow}无效或未就绪${re}"
                fi
            else
                echo -e " 当前域名: ${yellow}未获取到${re}"
            fi
        else
            echo -e " 当前状态: ${green}服务运行中${re}"
        fi
    fi
    echo -e "${cyan}------------------------------------------${re}"
}

install_deps() {
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y wget curl || true
    elif [ -f /etc/redhat-release ]; then
        yum install -y wget curl || true
    fi
}

install_cloudflared() {
    mkdir -p "$CRED_DIR"
    chmod 700 "$CRED_DIR"
    if [ -x "$CLOUD_BIN" ]; then
        echo "→ 已检测到: $CLOUD_BIN"
        return
    fi
    echo "→ 正在安装 cloudflared 到 $CLOUD_BIN ..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) FILE="cloudflared-linux-amd64" ;;
        aarch64|arm64) FILE="cloudflared-linux-arm64" ;;
        *) echo "不支持的架构" >&2; exit 1 ;;
    esac
    wget -q -O "$CLOUD_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/${FILE}"
    chmod +x "$CLOUD_BIN"
    echo "→ ✅ cloudflared 安装完成"
}

choose_edge() {
    echo -e "\n请选择边缘协议："
    echo "1) quic"
    echo "2) http2"
    echo "3) auto"
    read -r -p "选择 (1/2/3，默认 3)： " EDGE_CHOICE
    EDGE_CHOICE=${EDGE_CHOICE:-3}
    case "$EDGE_CHOICE" in
        1) EDGE_PROTO="quic" ;;
        2) EDGE_PROTO="http2" ;;
        *) EDGE_PROTO="auto" ;;
    esac
    echo "→ 边缘协议已设为: ${EDGE_PROTO}"
}

write_service() {
    local EXEC_CMD="$1"
    if $IS_ROOT; then
        cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel Service
After=network-online.target

[Service]
Type=simple
ExecStart=${EXEC_CMD}
Restart=on-failure
RestartSec=5s
User=root
WorkingDirectory=${CRED_DIR}

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now cloudflared
    else
        mkdir -p "$HOME/.config/systemd/user"
        cat > "$HOME/.config/systemd/user/cloudflared.service" <<EOF
[Unit]
Description=Cloudflare Tunnel Service (user)
After=network-online.target

[Service]
Type=simple
ExecStart=${EXEC_CMD}
Restart=on-failure
RestartSec=5s
WorkingDirectory=${CRED_DIR}

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now cloudflared
    fi
}

while true; do
    clear
    echo -e "${cyan}"
    echo "=========================================="
    echo "          Cloudflare Argo Tunnel"
    echo "=========================================="
    echo -e "${re}"
    echo -e "${bold}${green}1) 安装 Argo Tunnel 固定隧道${re}"
    echo -e "${bold}${yellow}2) 安装 Argo Tunnel 临时隧道${re}"
    echo -e "${bold}${yellow}3) 重置临时域名${re}"
    echo -e "${bold}${red}4) 卸载 Argo Tunnel${re}"
    echo -e "${bold}${cyan}5) 退出脚本${re}"
    echo
    show_status_box
    echo

    read -r -p "→ 请选择操作 (1/2/3/4/5): " ACTION
    echo

    case "$ACTION" in
        1)
            echo -e "\n🟢 安装固定隧道...\n"
            install_deps
            install_cloudflared

            while true; do
                read -r -p "请输入绑定域名（Public Hostname）： " DOMAIN
                [ -n "$DOMAIN" ] && break
                echo -e "${red}域名不能为空${re}"
            done
            printf "%s" "$DOMAIN" > "$DOMAIN_FILE"

            choose_edge

            echo -e "\n请选择凭证方式："
            echo "1) Cloudflare Token（推荐）"
            echo "2) credentials JSON"
            read -r -p "选择 (1/2) 默认 1： " MODE
            MODE=${MODE:-1}

            if [ "$MODE" = "1" ]; then
                while true; do
                    read -r -p "请输入 Cloudflare Tunnel Token（以 eyJ 开头）： " TUNNEL_TOKEN
                    [ -n "$TUNNEL_TOKEN" ] && break
                    echo -e "${red}必须输入 Token${re}"
                done
                printf "%s" "$TUNNEL_TOKEN" > "$TOKEN_FILE"
                chmod 600 "$TOKEN_FILE"
                echo "✅ Token 已保存到 $TOKEN_FILE"
                EXEC_CMD="$CLOUD_BIN tunnel --no-autoupdate --protocol ${EDGE_PROTO} run --token-file ${TOKEN_FILE}"
            else
                echo "请粘贴 credentials JSON（输完按回车两次结束）："
                JSON_CONTENT=""
                while IFS= read -r line; do
                    [ -z "$line" ] && break
                    JSON_CONTENT="${JSON_CONTENT}${line}\n"
                done
                CREDENTIAL_FILE="$CRED_DIR/$(date +%Y%m%d-%H%M%S)-tunnel.json"
                printf "%b" "$JSON_CONTENT" > "$CREDENTIAL_FILE"
                chmod 600 "$CREDENTIAL_FILE"
                echo "✅ 凭证已保存: $CREDENTIAL_FILE"
                EXEC_CMD="$CLOUD_BIN tunnel --no-autoupdate --protocol ${EDGE_PROTO} run --credentials-file ${CREDENTIAL_FILE}"
            fi

            echo "fixed" > "$MODE_FILE"
            write_service "$EXEC_CMD"
            sleep 4
            if check_running; then
                echo -e "\n🎉 ✅ 固定隧道启动成功！"
                echo "查看日志： journalctl -u cloudflared -f"
            else
                echo -e "\n✖ 启动失败： journalctl -u cloudflared -n 30"
            fi
            exit 0
            ;;
        2)
            echo -e "\n🟢 安装临时隧道...\n"
            install_deps
            install_cloudflared

            read -r -p "请输入本地监听端口（默认 443）： " PORT
            PORT=${PORT:-443}
            choose_edge

            EXEC_CMD="$CLOUD_BIN tunnel --no-autoupdate --protocol ${EDGE_PROTO} --url http://127.0.0.1:${PORT}"
            echo "temp" > "$MODE_FILE"
            rm -f "$DOMAIN_FILE"
            write_service "$EXEC_CMD"
            sleep 10
            if check_running; then
                echo -e "\n🎉 ✅ 临时隧道启动成功！"
                domain=$(get_temp_domain)
                if [ -n "$domain" ]; then
                    echo -e "🔗 临时域名: ${green}${bold}${domain}${re}"
                    if verify_temp_domain "$domain"; then
                        echo -e "状态: ${green}有效${re}"
                    else
                        echo -e "状态: ${yellow}无效或未就绪${re}"
                    fi
                else
                    echo "临时域名获取失败，请用选项 3 重置"
                fi
            else
                echo -e "\n✖ 启动失败： journalctl -u cloudflared -n 30"
            fi
            exit 0
            ;;
        3)
            echo -e "\n${yellow}🔄 重置临时域名...${re}"
            if [ ! -x "$CLOUD_BIN" ]; then
                echo -e "${red}未安装 cloudflared，请先选 2 安装临时隧道${re}"
                exit 1
            fi
            if ! check_running; then
                echo -e "${red}服务未运行，请先选 2 安装临时隧道${re}"
                exit 1
            fi
            mode=$(cat "$MODE_FILE" 2>/dev/null || echo "")
            if [ "$mode" != "temp" ]; then
                echo -e "${yellow}当前不是临时隧道模式，无法重置临时域名${re}"
                exit 1
            fi
            systemctl restart cloudflared 2>/dev/null || systemctl --user restart cloudflared 2>/dev/null || true
            echo "服务已重启，等待新域名..."
            sleep 10
            domain=$(get_temp_domain)
            if [ -n "$domain" ]; then
                echo "=========================================="
                echo -e "🔗 最新临时域名: ${green}${bold}${domain}${re}"
                if verify_temp_domain "$domain"; then
                    echo -e "验证: ${green}有效${re}"
                else
                    echo -e "验证: ${yellow}无效或未就绪${re}"
                fi
                echo "=========================================="
            else
                echo -e "${red}临时域名获取失败，请稍后重试${re}"
            fi
            exit 0
            ;;
        4)
            echo -e "\n🔴 开始卸载..."
            if $IS_ROOT; then
                systemctl disable --now cloudflared 2>/dev/null || true
                rm -f /etc/systemd/system/cloudflared.service
                rm -rf /root/.cloudflared
                systemctl daemon-reload 2>/dev/null || true
                echo
                echo "✅ 已卸载"
                echo "删除内容："
                echo "  - /etc/systemd/system/cloudflared.service"
                echo "  - /root/.cloudflared"
            else
                systemctl --user disable --now cloudflared 2>/dev/null || true
                rm -f "$HOME/.config/systemd/user/cloudflared.service"
                rm -rf "$HOME/.cloudflared"
                systemctl --user daemon-reload 2>/dev/null || true
                echo
                echo "✅ 已卸载"
                echo "删除内容："
                echo "  - $HOME/.config/systemd/user/cloudflared.service"
                echo "  - $HOME/.cloudflared"
            fi
            echo
            exit 0
            ;;
        5)
            echo "👋 已退出"
            exit 0
            ;;
        *)
            echo -e "${red}✖ 无效选择，请输入 1、2、3、4 或 5。${re}"
            sleep 1.5
            ;;
    esac
done