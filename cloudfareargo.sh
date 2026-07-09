#!/usr/bin/env bash
set -euo pipefail

# 1. 强制 root 检查
if [ "$(id -u)" -ne 0 ]; then
    echo "✖ 请先运行 'sudo -i' 切换到 root 用户再执行此脚本！" >&2
    exit 1
fi

clear
echo "=========================================="
echo "          Cloudflare Argo Tunnel"
echo "=========================================="
echo "1) 安装 Argo Tunnel"
echo "2) 卸载 Argo Tunnel"
echo "3) 查看当前临时域名 (仅限临时隧道)"
echo "4) 退出脚本"
echo "=========================================="
echo

read -r -p "→ 请选择操作 (1/2/3/4): " ACTION
ACTION=${ACTION:-1}

case "$ACTION" in
    1)
        echo -e "\n🟢 进入安装流程...\n"
        ;;
    2)
        echo -e "\n🔴 进入卸载流程..."
        echo "⚠️ 开始卸载 Cloudflare Argo Tunnel..."
        
        systemctl disable --now cloudflared 2>/dev/null || true
        rm -f /etc/systemd/system/cloudflared.service /usr/local/bin/cloudflared
        rm -rf /root/.cloudflared /etc/cloudflared
        
        echo
        echo "✅ 已卸载 Cloudflare Argo Tunnel"
        echo "删除内容："
        echo "  - /etc/systemd/system/cloudflared.service"
        echo "  - /root/.cloudflared"
        echo "  - /usr/local/bin/cloudflared"
        echo
        exit 0
        ;;
    3)
        echo -e "\n🔍 正在从系统日志中抓取最新的临时域名...\n"
        # 抓取最近 50 行日志里最新的 trycloudflare 域名
        TMP_DOMAIN=$(journalctl -u cloudflared -n 50 --no-pager | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -n 1 || true)
        if [ -n "$TMP_DOMAIN" ]; then
            FINAL_DOMAIN=$(echo "$TMP_DOMAIN" | sed 's|https://||')
            echo "=========================================="
            echo -e "🔗 当前最新的免费临时域名为:"
            echo -e "   \033[1;32m${FINAL_DOMAIN}\033[0m"
            echo "=========================================="
        else
            echo -e "✖ \033[1;31m未能抓取到临时域名！\033[0m"
            echo "原因可能是：你没有使用免费临时隧道模式（Mode 3），或者服务当前未成功运行。"
            echo "你可以运行 'systemctl status cloudflared' 检查服务状态。"
        fi
        exit 0
        ;;
    *)
        echo "👋 已退出脚本。"
        exit 0
        ;;
esac

# 安装依赖与主程序
[ -f /etc/debian_version ] && (apt update -y && apt install -y wget curl || true)
[ -f /etc/redhat-release ] && (yum install -y wget curl || true)

if ! command -v cloudflared >/dev/null 2>&1; then
    echo "→ 正在安装 cloudflared..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)  FILE="cloudflared-linux-amd64" ;;
        aarch64|arm64) FILE="cloudflared-linux-arm64" ;;
        *) echo "✖ 不支持的架构" >&2; exit 1 ;;
    esac
    wget -q -O "/usr/local/bin/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/${FILE}"
    chmod +x /usr/local/bin/cloudflared
    echo "→ ✅ cloudflared 安装完成： /usr/local/bin/cloudflared"
fi

# ===============================================================
# 凭证/隧道方式选择
# ===============================================================
echo -e "\n请选择凭证/隧道方式："
echo "1) Cloudflare Token（推荐）"
echo "2) credentials JSON（本地文件模式）"
echo "3) 免费临时隧道（免账号，自动获取域名）"
read -r -p "选择 (1/2/3) 默认 1： " MODE
MODE=${MODE:-1}

INPUT_DOMAIN=""
if [ "$MODE" = "1" ] || [ "$MODE" = "2" ]; then
    echo -e "\n=== 配置自定义域名参数 ==="
    read -r -p "请输入要绑定的域名（Public Hostname）： " INPUT_DOMAIN
else
    echo -e "\n=== 配置临时隧道参数（免账号模式） ==="
fi

read -r -p "请输入本地监听端口（默认 443）： " PORT
PORT=${PORT:-443}

echo -e "\n请选择传输方式："
echo "1) WebSocket（默认）"
echo "2) gRPC"
echo "3) TCP"
echo "4) xhttp"
read -r -p "选择传输类型 (1/2/3/4，默认 1)： " STREAM_TYPE
STREAM_TYPE=${STREAM_TYPE:-1}

WS_PATH=""
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
    3)
        WS_PATH="-"
        ;;
    4)
        read -r -p "请输入 xhttp 路径（默认 /）： " WS_PATH
        WS_PATH=${WS_PATH:-/}
        [[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH"
        ;;
esac

read -r -p "请输入协议类型 (http/https/tcp，默认 http)： " PROTO
PROTO=${PROTO:-http}

# ===============================================================
# 核心命令拼接
# ===============================================================
if [ "$MODE" = "1" ]; then
    echo -e ""
    read -r -p "请输入 Cloudflare Tunnel Token（以 eyJ 开头）： " ARGO_TOKEN
    EXEC_CMD="/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 run --token ${ARGO_TOKEN}"

elif [ "$MODE" = "2" ]; then
    mkdir -p /etc/cloudflared
    echo -e ""
    echo "请在下方粘贴你的 credentials JSON 完整内容（输完按回车，再按 Ctrl+D 结束保存）："
    cat > /etc/cloudflared/cert.json
    read -r -p "请输入你的 Tunnel 名称或 ID: " TUNNEL_ID
    
    if [ "$STREAM_TYPE" = "3" ] || [ "$PROTO" = "tcp" ]; then
        SERVICE_URL="tcp://127.0.0.1:${PORT}"
    elif [ "$STREAM_TYPE" = "2" ]; then
        SERVICE_URL="grpc://127.0.0.1:${PORT}"
    else
        SERVICE_URL="${PROTO}://127.0.0.1:${PORT}"
    fi

    if [ "$STREAM_TYPE" = "3" ] || [ "$PROTO" = "tcp" ]; then
        cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/cert.json
ingress:
  - hostname: ${INPUT_DOMAIN}
    service: ${SERVICE_URL}
  - service: http_status:404
EOF
    else
        cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/cert.json
ingress:
  - hostname: ${INPUT_DOMAIN}
    service: ${SERVICE_URL}
    originRequest:
      noTLSVerify: true
      httpHostHeader: ${INPUT_DOMAIN}
  - service: http_status:404
EOF
    fi
    EXEC_CMD="/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 --config /etc/cloudflared/config.yml run"

else
    if [ "$STREAM_TYPE" = "2" ] || [ "$PROTO" = "grpc" ]; then
        EXEC_CMD="/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 --url grpc://127.0.0.1:${PORT}"
    elif [ "$STREAM_TYPE" = "3" ] || [ "$PROTO" = "tcp" ]; then
        EXEC_CMD="/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 --url tcp://127.0.0.1:${PORT}"
    else
        if [ "$WS_PATH" != "/" ] && [ "$WS_PATH" != "-" ]; then
            CLEAN_PATH=$(echo "$WS_PATH" | sed 's|^/||')
            EXEC_CMD="/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 --url ${PROTO}://127.0.0.1:${PORT}/${CLEAN_PATH}"
        else
            EXEC_CMD="/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 --url ${PROTO}://127.0.0.1:${PORT}"
        fi
    fi
fi

# ===============================================================
# 写入服务与启动
# ===============================================================
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared

echo -e "\n→ 生成 systemd 服务文件: /etc/systemd/system/cloudflared.service"
sleep 4

if systemctl is-active --quiet cloudflared; then
    echo -e "\n=========================================="
    echo -e "🎉 ✅ Argo Tunnel 核心服务启动成功！"
    echo -e "=========================================="
    
    if [ "$MODE" = "3" ]; then
        sleep 1
        TMP_DOMAIN=$(journalctl -u cloudflared --no-pager | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | head -n 1 || true)
        if [ -n "$TMP_DOMAIN" ]; then
            FINAL_DOMAIN=$(echo "$TMP_DOMAIN" | sed 's|https://||')
            echo -e "🔗 你的免费临时公网域名为:\n   \033[1;32m${FINAL_DOMAIN}\033[0m"
            echo "=========================================="
        else
            echo -e "⚠️ 临时域名未能全自动抓取，请运行 'journalctl -u cloudflared -n 30' 查看。"
            echo "=========================================="
        fi
    fi
else
    echo -e "\n✖ 启动失败，请运行 journalctl -u cloudflared -n 30 --no-pager 查看具体报错。"
fi