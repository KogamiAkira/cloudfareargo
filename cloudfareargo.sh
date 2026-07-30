#!/usr/bin/env bash
set -euo pipefail

# 是否 root
IS_ROOT=false
if [ "$(id -u)" -eq 0 ]; then
  IS_ROOT=true
fi

# 颜色
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
cyan='\033[1;36m'
purple='\033[0;35m'
bold='\033[1m'
re='\033[0m'

while true; do
    clear
    echo -e "${cyan}"
    echo "=========================================="
    echo "          Cloudflare Argo Tunnel"
    echo "=========================================="
    echo -e "${re}"
    echo -e "${bold}${green}1) 安装 Argo Tunnel${re}"
    echo -e "${bold}${red}2) 卸载 Argo Tunnel${re}"
    echo -e "${bold}${yellow}3) 更新临时域名${re}"
    echo -e "${bold}${yellow}4) 查看当前临时域名${re}"
    echo -e "${bold}${cyan}5) 退出脚本${re}"
    echo

    read -r -p "→ 请选择操作 (1/2/3/4/5): " ACTION
    echo

    case "$ACTION" in
        1)
            echo -e "\n🟢 进入安装流程...\n"
            break
            ;;
        2)
            echo -e "\n🔴 开始卸载 Cloudflare Argo Tunnel..."
            if $IS_ROOT; then
                systemctl disable --now cloudflared 2>/dev/null || true
                rm -f /etc/systemd/system/cloudflared.service
                rm -rf /root/.cloudflared /etc/cloudflared
                rm -f /usr/local/bin/cloudflared
                systemctl daemon-reload 2>/dev/null || true
                echo
                echo "✅ 已卸载 Cloudflare Argo Tunnel"
                echo "删除内容："
                echo "  - /etc/systemd/system/cloudflared.service"
                echo "  - /root/.cloudflared"
                echo "  - /usr/local/bin/cloudflared"
            else
                systemctl --user disable --now cloudflared 2>/dev/null || true
                rm -f "$HOME/.config/systemd/user/cloudflared.service"
                rm -rf "$HOME/.cloudflared"
                rm -f "$HOME/.local/bin/cloudflared"
                systemctl --user daemon-reload 2>/dev/null || true
                echo
                echo "✅ 已卸载 Cloudflare Argo Tunnel"
                echo "删除内容："
                echo "  - $HOME/.config/systemd/user/cloudflared.service"
                echo "  - $HOME/.cloudflared"
                echo "  - $HOME/.local/bin/cloudflared"
            fi
            echo
            exit 0
            ;;
        3)
            echo -e "\n${yellow}🔄 正在更新临时域名...${re}"
            systemctl restart cloudflared 2>/dev/null || systemctl --user restart cloudflared 2>/dev/null || true
            echo "服务已重启，正在获取最新临时域名..."
            sleep 6
            TMP_DOMAIN=$(journalctl -u cloudflared -n 100 --no-pager 2>/dev/null | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -n 1 || true)
            if [ -n "$TMP_DOMAIN" ]; then
                echo "=========================================="
                echo -e "🔗 最新临时域名为: \033[1;32m${TMP_DOMAIN#https://}\033[0m"
                echo "=========================================="
            else
                echo "未能抓取到临时域名，请稍后再试或手动查看日志"
            fi
            exit 0
            ;;
        4)
            echo -e "\n🔍 正在获取最新的临时域名...\n"
            sleep 3
            TMP_DOMAIN=$(journalctl -u cloudflared -n 100 --no-pager 2>/dev/null | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -n 1 || true)
            if [ -n "$TMP_DOMAIN" ]; then
                echo "=========================================="
                echo -e "🔗 当前最新的临时域名为: \033[1;32m${TMP_DOMAIN#https://}\033[0m"
                echo "=========================================="
            else
                echo "未能抓取到临时域名，请稍后重试或查看日志"
            fi
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

# 安装依赖
if [ -f /etc/debian_version ]; then
    apt update -y && apt install -y wget curl || true
elif [ -f /etc/redhat-release ]; then
    yum install -y wget curl || true
fi

# 安装 cloudflared
if ! command -v cloudflared >/dev/null 2>&1; then
    echo "→ 正在安装 cloudflared..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) FILE="cloudflared-linux-amd64" ;;
        aarch64|arm64) FILE="cloudflared-linux-arm64" ;;
        *) echo "不支持的架构" >&2; exit 1 ;;
    esac
    if $IS_ROOT; then
        DEST="/usr/local/bin"
    else
        DEST="$HOME/.local/bin"
        mkdir -p "$DEST"
    fi
    wget -q -O "${DEST}/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/${FILE}"
    chmod +x "${DEST}/cloudflared"
    echo "→ ✅ cloudflared 安装完成"
fi

CLOUD_BIN=$(command -v cloudflared || echo "$HOME/.local/bin/cloudflared")

# 配置目录
if $IS_ROOT; then
    CRED_DIR="/root/.cloudflared"
else
    CRED_DIR="$HOME/.cloudflared"
fi
mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"
CONFIG_FILE="$CRED_DIR/config.yml"
TOKEN_FILE="$CRED_DIR/token"

# 选择模式
echo -e "\n请选择凭证/隧道方式："
echo "1) Cloudflare Token（推荐）"
echo "2) credentials JSON（本地文件模式）"
echo "3) 免费临时隧道（免账号，自动获取域名）"
read -r -p "选择 (1/2/3) 默认 1： " MODE
MODE=${MODE:-1}

# ==================== 临时隧道模式 ====================
if [ "$MODE" = "3" ]; then
    echo -e "\n=== 配置临时隧道参数 ==="
    read -r -p "请输入本地监听端口（默认 443）： " PORT
    PORT=${PORT:-443}
    
    echo -e "\n请选择传输方式："
    echo "1) WebSocket（默认）"
    echo "2) gRPC"
    echo "3) TCP"
    echo "4) xhttp"
    read -r -p "选择 (1/2/3/4，默认 1)： " STREAM_TYPE
    STREAM_TYPE=${STREAM_TYPE:-1}
    
    WS_PATH="/"
    case "$STREAM_TYPE" in
        1)
            read -r -p "请输入 WebSocket 路径（默认 /）： " WS_PATH
            WS_PATH=${WS_PATH:-/}
            [[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH"
            ;;
        2)
            read -r -p "请输入 gRPC ServiceName（默认 vmess-grpc）： " WS_PATH
            WS_PATH=${WS_PATH:-vmess-grpc}
            ;;
        4)
            read -r -p "请输入 xhttp 路径（默认 /）： " WS_PATH
            WS_PATH=${WS_PATH:-/}
            [[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH"
            ;;
    esac
    
    read -r -p "请输入协议类型 (http/https/tcp，默认 http)： " PROTO
    PROTO=${PROTO:-http}
    
    if [ "$STREAM_TYPE" = "2" ]; then
        EXEC_CMD="$CLOUD_BIN tunnel --no-autoupdate --protocol http2 --url grpc://127.0.0.1:${PORT}"
    elif [ "$STREAM_TYPE" = "3" ]; then
        EXEC_CMD="$CLOUD_BIN tunnel --no-autoupdate --protocol http2 --url tcp://127.0.0.1:${PORT}"
    else
        CLEAN_PATH=$(echo "$WS_PATH" | sed 's|^/||')
        if [ -n "$CLEAN_PATH" ]; then
            EXEC_CMD="$CLOUD_BIN tunnel --no-autoupdate --protocol http2 --url ${PROTO}://127.0.0.1:${PORT}/${CLEAN_PATH}"
        else
            EXEC_CMD="$CLOUD_BIN tunnel --no-autoupdate --protocol http2 --url ${PROTO}://127.0.0.1:${PORT}"
        fi
    fi

# ==================== Token / JSON 模式 ====================
else
    while true; do
        read -r -p "需要配置多少个域名->端口？(例如 1)： " NUM
        if [[ "$NUM" =~ ^[0-9]+$ ]] && [ "$NUM" -gt 0 ]; then
            break
        else
            echo -e "${red}请输入有效数字${re}"
        fi
    done
    
    MAPPINGS=""
    for i in $(seq 1 "$NUM"); do
        echo
        echo "=== 配置第 $i 个域名 ==="
        while true; do
            read -r -p "请输入要绑定的域名（Public Hostname）： " DOMAIN
            [ -n "$DOMAIN" ] && break
            echo -e "${red}域名不能为空${re}"
        done
        read -r -p "请输入本地监听端口（默认 443）： " PORT
        PORT=${PORT:-443}
        
        echo
        echo "请选择传输方式："
        echo "1) WebSocket（默认）"
        echo "2) gRPC"
        echo "3) TCP"
        echo "4) xhttp"
        read -r -p "选择 (1/2/3/4，默认 1)： " STREAM_TYPE
        STREAM_TYPE=${STREAM_TYPE:-1}
        
        WS_PATH="/"
        case "$STREAM_TYPE" in
            1)
                read -r -p "请输入 WebSocket 路径（默认 /）： " WS_PATH
                WS_PATH=${WS_PATH:-/}
                [[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH"
                STREAM_TYPE="ws"
                ;;
            2)
                read -r -p "请输入 gRPC ServiceName（默认 vmess-grpc）： " WS_PATH
                WS_PATH=${WS_PATH:-vmess-grpc}
                STREAM_TYPE="grpc"
                ;;
            3)
                STREAM_TYPE="tcp"
                WS_PATH="-"
                ;;
            4)
                read -r -p "请输入 xhttp 路径（默认 /）： " WS_PATH
                WS_PATH=${WS_PATH:-/}
                [[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH"
                STREAM_TYPE="xhttp"
                ;;
        esac
        
        read -r -p "请输入协议类型 (http/https/tcp，默认 http)： " PROTO
        PROTO=${PROTO:-http}
        MAPPINGS="${MAPPINGS}${DOMAIN},${PORT},${WS_PATH},${PROTO},${STREAM_TYPE}\n"
    done
    
    # 凭证处理
    if [ "$MODE" = "1" ]; then
        while true; do
            read -r -p "请输入 Cloudflare Tunnel Token（以 eyJ 开头）： " TUNNEL_TOKEN
            [ -n "$TUNNEL_TOKEN" ] && break
            echo -e "${red}必须输入 Token${re}"
        done
        printf "%s" "$TUNNEL_TOKEN" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        echo "✅ Token 已保存到 $TOKEN_FILE"
        
        # 新版本优先使用 --token-file
        EXEC_CMD="$CLOUD_BIN tunnel run --token-file ${TOKEN_FILE}"
    else
        echo "请粘贴 credentials JSON 内容（输完按回车两次结束）："
        JSON_CONTENT=""
        while IFS= read -r line; do
            [ -z "$line" ] && break
            JSON_CONTENT="${JSON_CONTENT}${line}\n"
        done
        CREDENTIAL_FILE="$CRED_DIR/$(date +%Y%m%d-%H%M%S)-tunnel.json"
        printf "%b" "$JSON_CONTENT" > "$CREDENTIAL_FILE"
        chmod 600 "$CREDENTIAL_FILE"
        echo "✅ 凭证文件已保存"
        EXEC_CMD="$CLOUD_BIN tunnel run --credentials-file ${CREDENTIAL_FILE}"
    fi
    
    # 生成 config.yml
    {
        echo "# Cloudflare Tunnel Auto Generated"
        echo
        echo "ingress:"
        echo -e "$MAPPINGS" | while IFS=',' read -r HOST PORT PATH PROTO STREAM_TYPE; do
            [ -z "$HOST" ] && continue
            case "$PROTO" in
                tcp) SERVICE="tcp://localhost:${PORT}" ;;
                *) SERVICE="${PROTO}://localhost:${PORT}" ;;
            esac
            echo "  - hostname: ${HOST}"
            echo "    service: ${SERVICE}"
            echo "    originRequest:"
            echo "      noTLSVerify: true"
            echo "      httpHostHeader: ${HOST}"
            if [ "$STREAM_TYPE" = "ws" ]; then
                echo "      headers:"
                echo "        Connection: Upgrade"
                echo "        Upgrade: websocket"
            fi
            echo
        done
        echo "  - service: http_status:404"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "✅ 配置文件已生成：$CONFIG_FILE"
fi

# ==================== 生成 systemd 服务 ====================
if $IS_ROOT; then
    SERVICE_FILE="/etc/systemd/system/cloudflared.service"
    cat > "$SERVICE_FILE" <<EOF
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
    SERVICE_FILE="$HOME/.config/systemd/user/cloudflared.service"
    cat > "$SERVICE_FILE" <<EOF
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

sleep 4

if systemctl is-active --quiet cloudflared 2>/dev/null || systemctl --user is-active --quiet cloudflared 2>/dev/null; then
    echo -e "\n🎉 ✅ Argo Tunnel 启动成功！"
    if [ "$MODE" = "3" ]; then
        sleep 5
        TMP_DOMAIN=$(journalctl -u cloudflared -n 100 --no-pager 2>/dev/null | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -n 1 || true)
        if [ -n "$TMP_DOMAIN" ]; then
            echo -e "🔗 临时域名: \033[1;32m${TMP_DOMAIN#https://}\033[0m"
        else
            echo "临时域名抓取失败，可稍后用选项4查看"
        fi
    fi
    echo "查看日志： journalctl -u cloudflared -f"
    echo "服务状态： systemctl status cloudflared"
else
    echo -e "\n✖ 启动失败，请查看日志： journalctl -u cloudflared -n 30"
fi
