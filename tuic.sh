#!/bin/bash
# TUIC v5 Pterodactyl 容器优化部署脚本 v2.0.0
# 修复: 环境变量支持 + 自动重启 + 日志优化
set -euo pipefail

# ==================== 配置区 ====================
readonly SCRIPT_VERSION="2.0.0"
readonly WORKDIR="/home/container/tuic"
readonly MASQ_DOMAIN="${MASQ_DOMAIN:-www.bing.com}"
readonly SERVER_TOML="server.toml"
readonly CERT_PEM="tuic-cert.pem"
readonly KEY_PEM="tuic-key.pem"
readonly LINK_TXT="tuic_link.txt"
readonly TUIC_BIN="tuic-server"

# ==================== 日志函数 ====================
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
}

# ==================== 环境变量处理 ====================
check_env_vars() {
    # 优先级: 命令行参数 > 环境变量 TUIC_PORT > SERVER_PORT > 手动输入
    if [[ $# -ge 1 && -n "${1:-}" ]]; then
        TUIC_PORT="$1"
        log "INFO" "从命令行参数读取端口: $TUIC_PORT"
        return 0
    fi
    
    if [[ -n "${TUIC_PORT:-}" ]]; then
        log "INFO" "从环境变量 TUIC_PORT 读取端口: $TUIC_PORT"
        return 0
    fi
    
    if [[ -n "${SERVER_PORT:-}" ]]; then
        TUIC_PORT="$SERVER_PORT"
        log "INFO" "从环境变量 SERVER_PORT 读取端口: $TUIC_PORT"
        return 0
    fi
    
    # 手动输入
    local port
    while true; do
        echo "⚙️  请输入 TUIC 端口 (1024-65535):" >&2
        read -rp "> " port
        if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1024 || "$port" -gt 65535 ]]; then
            log "ERROR" "无效端口: $port"
            continue
        fi
        TUIC_PORT="$port"
        break
    done
    
    return 0
}

# ==================== 加载已有配置 ====================
load_existing_config() {
    if [[ -f "$WORKDIR/$SERVER_TOML" ]]; then
        cd "$WORKDIR"
        TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/')
        TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
        TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
        
        log "INFO" "检测到已有配置"
        log "INFO" "端口: $TUIC_PORT"
        log "INFO" "UUID: $TUIC_UUID"
        log "INFO" "密码: $TUIC_PASSWORD"
        return 0
    fi
    return 1
}

# ==================== 证书生成 ====================
generate_cert() {
    if [[ -f "$WORKDIR/$CERT_PEM" && -f "$WORKDIR/$KEY_PEM" ]]; then
        log "INFO" "检测到已有证书,跳过生成"
        return
    fi
    
    log "INFO" "生成自签 ECDSA-P256 证书..."
    
    if ! command -v openssl >/dev/null 2>&1; then
        log "FATAL" "openssl 未安装"
        exit 1
    fi
    
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$WORKDIR/$KEY_PEM" \
        -out "$WORKDIR/$CERT_PEM" \
        -subj "/CN=${MASQ_DOMAIN}" \
        -days 3650 -nodes >/dev/null 2>&1 || {
            log "FATAL" "证书生成失败"
            exit 1
        }
    
    chmod 600 "$WORKDIR/$KEY_PEM"
    chmod 644 "$WORKDIR/$CERT_PEM"
    log "INFO" "✓ 证书生成完成 (有效期: 3650 天)"
}

# ==================== 下载 TUIC Server ====================
download_tuic_server() {
    if [[ -x "$WORKDIR/$TUIC_BIN" ]]; then
        log "INFO" "tuic-server 已存在"
        return
    fi
    
    log "INFO" "下载 tuic-server..."
    
    local arch
    arch=$(uname -m)
    
    local tuic_url
    case "$arch" in
        x86_64)
            tuic_url="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
            ;;
        aarch64)
            tuic_url="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-aarch64-linux"
            ;;
        *)
            log "FATAL" "不支持的架构: $arch"
            exit 1
            ;;
    esac
    
    if curl -L -f --connect-timeout 30 --max-time 300 -o "$WORKDIR/$TUIC_BIN" "$tuic_url"; then
        chmod +x "$WORKDIR/$TUIC_BIN"
        log "INFO" "✓ tuic-server 下载完成"
    else
        log "FATAL" "下载失败: $tuic_url"
        exit 1
    fi
}

# ==================== 生成配置文件 ====================
generate_config() {
    local rest_secret
    rest_secret=$(openssl rand -hex 16 2>/dev/null || echo "default_secret")
    
    cat > "$WORKDIR/$SERVER_TOML" <<EOF
# TUIC v5 配置文件 - 自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

log_level = "warn"
server = "0.0.0.0:${TUIC_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "15s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
self_sign = false
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:$((TUIC_PORT + 1))"
secret = "$rest_secret"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = 1500
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "30s"

[quic.congestion_control]
controller = "bbr"
initial_window = 4194304
EOF
    
    log "INFO" "✓ 配置文件已生成"
}

# ==================== 获取服务器 IP ====================
get_server_ip() {
    local ip
    ip=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
         curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
         echo "YOUR_SERVER_IP")
    echo "$ip"
}

# ==================== 生成连接链接 ====================
generate_link() {
    local ip="$1"
    
    local tuic_link="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1#TUIC-${ip}"
    
    cat > "$WORKDIR/$LINK_TXT" <<EOF
=== TUIC v5 节点信息 ===
生成时间: $(date '+%Y-%m-%d %H:%M:%S')

连接字符串:
$tuic_link

手动配置参数:
  协议: TUIC v5
  服务器: $ip
  端口: $TUIC_PORT
  UUID: $TUIC_UUID
  密码: $TUIC_PASSWORD
  SNI: $MASQ_DOMAIN
  ALPN: h3
  拥塞控制: BBR
  跳过证书验证: 是

注意事项:
1. 支持的客户端: NekoRay, v2rayN (最新版), Clash Meta
2. 必须启用 "允许不安全连接 (allow_insecure)"
3. TUIC 同样基于 UDP,无法使用 Cloudflare Tunnel

关于 Gemini 地区限制:
推荐使用以下方法之一:
- 方案1: 部署 Cloudflare Pages 反向代理 (见下方说明)
- 方案2: 更换支持 WARP 的 VPS
- 方案3: 使用其他 AI 服务 (Claude, ChatGPT 等)

Cloudflare Pages 代理部署:
1. 访问: https://github.com/你的仓库/gemini-proxy
2. Fork 仓库并部署到 Cloudflare Pages
3. 使用 Pages 域名访问 Gemini: https://your-project.pages.dev/gemini
EOF
    
    echo ""
    log "INFO" "节点信息已保存至: $WORKDIR/$LINK_TXT"
    echo ""
    echo "📱 TUIC 连接链接:"
    echo "$tuic_link"
    echo ""
}

# ==================== 主流程 ====================
main() {
    echo "==========================================" >&2
    log "INFO" "TUIC v5 Pterodactyl 部署脚本 v$SCRIPT_VERSION"
    echo "==========================================" >&2
    echo "" >&2
    
    # 1. 初始化
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    
    # 2. 检查环境变量或加载配置
    if ! load_existing_config; then
        log "INFO" "首次运行,开始初始化..."
        check_env_vars "$@"
        
        # 生成随机凭证
        if command -v uuidgen >/dev/null 2>&1; then
            TUIC_UUID="$(uuidgen)"
        else
            TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)"
        fi
        TUIC_PASSWORD="$(openssl rand -hex 16)"
        
        log "INFO" "UUID: $TUIC_UUID"
        log "INFO" "密码: $TUIC_PASSWORD"
        log "INFO" "SNI: $MASQ_DOMAIN"
    fi
    echo "" >&2
    
    # 3. 生成证书
    log "INFO" "配置 TLS 证书..."
    generate_cert
    echo "" >&2
    
    # 4. 下载二进制
    log "INFO" "下载 tuic-server..."
    download_tuic_server
    echo "" >&2
    
    # 5. 生成配置
    log "INFO" "生成配置文件..."
    generate_config
    echo "" >&2
    
    # 6. 生成连接信息
    log "INFO" "生成节点信息..."
    local server_ip
    server_ip=$(get_server_ip)
    generate_link "$server_ip"
    
    # 7. 输出总结
    echo "==========================================" >&2
    log "INFO" "部署完成!"
    echo "==========================================" >&2
    echo "" >&2
    
    echo "⚠️  重要提示:" >&2
    echo "   TUIC 和 Hysteria2 一样,都基于 UDP 协议" >&2
    echo "   无法使用 Cloudflare Tunnel" >&2
    echo "" >&2
    echo "   如需访问 Gemini,请查看 $LINK_TXT 中的替代方案" >&2
    echo "" >&2
    
    echo "下一步操作:" >&2
    echo "1. 将 Startup Command 修改为:" >&2
    echo "   ./tuic/tuic-server -c ./tuic/server.toml" >&2
    echo "" >&2
    echo "2. 重启容器即可运行 TUIC 服务" >&2
    echo "" >&2
    
    # 8. 启动服务 (带自动重启)
    log "INFO" "脚本执行完毕,即将启动 TUIC 服务..."
    echo "" >&2
    
    while true; do
        log "INFO" "启动 tuic-server..."
        "$WORKDIR/$TUIC_BIN" -c "$WORKDIR/$SERVER_TOML" || {
            log "WARN" "tuic-server 已退出,5秒后重启..."
            sleep 5
        }
    done
}

# ==================== 入口点 ====================
main "$@"
