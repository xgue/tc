#!/bin/bash
# TUIC v5 Pterodactyl 完美优化版 v3.0.0
# 特性: 零日志输出 + 自动配置 + 增强安全性
set -euo pipefail

# ==================== 配置区 ====================
readonly WORKDIR="/home/container/tuic"
readonly MASQ_DOMAIN="${MASQ_DOMAIN:-www.bing.com}"
readonly SERVER_TOML="server.toml"
readonly CERT_PEM="tuic-cert.pem"
readonly KEY_PEM="tuic-key.pem"
readonly LINK_TXT="tuic_link.txt"
readonly TUIC_BIN="tuic-server"

# ==================== 静默日志 (只输出关键信息) ====================
log_silent() {
    # 完全静默,不输出任何内容
    return 0
}

log_info() {
    # 只在初始化时输出关键信息
    if [[ "${SHOW_INIT_LOG:-0}" == "1" ]]; then
        echo "$*" >&2
    fi
}

# ==================== 环境变量处理 ====================
check_env_vars() {
    if [[ $# -ge 1 && -n "${1:-}" ]]; then
        TUIC_PORT="$1"
        return 0
    fi
    
    if [[ -n "${TUIC_PORT:-}" ]]; then
        return 0
    fi
    
    if [[ -n "${SERVER_PORT:-}" ]]; then
        TUIC_PORT="$SERVER_PORT"
        return 0
    fi
    
    # 默认端口
    TUIC_PORT="8443"
    return 0
}

# ==================== 加载已有配置 ====================
load_existing_config() {
    if [[ -f "$WORKDIR/$SERVER_TOML" ]]; then
        cd "$WORKDIR"
        TUIC_PORT=$(grep '^server =' "$SERVER_TOML" 2>/dev/null | sed -E 's/.*:(.*)\"/\1/' || echo "8443")
        TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" 2>/dev/null | tail -n1 | awk '{print $1}' || echo "")
        TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" 2>/dev/null | tail -n1 | awk -F'"' '{print $2}' || echo "")
        
        if [[ -n "$TUIC_UUID" && -n "$TUIC_PASSWORD" ]]; then
            return 0
        fi
    fi
    return 1
}

# ==================== 证书生成 (静默) ====================
generate_cert() {
    if [[ -f "$WORKDIR/$CERT_PEM" && -f "$WORKDIR/$KEY_PEM" ]]; then
        return
    fi
    
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$WORKDIR/$KEY_PEM" \
        -out "$WORKDIR/$CERT_PEM" \
        -subj "/CN=${MASQ_DOMAIN}" \
        -days 3650 -nodes >/dev/null 2>&1 || exit 1
    
    chmod 600 "$WORKDIR/$KEY_PEM"
    chmod 644 "$WORKDIR/$CERT_PEM"
}

# ==================== 下载 TUIC Server (静默) ====================
download_tuic_server() {
    if [[ -x "$WORKDIR/$TUIC_BIN" ]]; then
        return
    fi
    
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
            exit 1
            ;;
    esac
    
    curl -L -f --connect-timeout 30 --max-time 300 -o "$WORKDIR/$TUIC_BIN" "$tuic_url" >/dev/null 2>&1 || exit 1
    chmod +x "$WORKDIR/$TUIC_BIN"
}

# ==================== 生成配置文件 (增强安全性) ====================
generate_config() {
    local rest_secret
    rest_secret=$(openssl rand -hex 32 2>/dev/null || echo "$(date +%s)$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)")
    
    cat > "$WORKDIR/$SERVER_TOML" <<EOF
# TUIC v5 高性能配置 - 优化安全性和隐匿性
log_level = "off"
server = "0.0.0.0:${TUIC_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "15s"
task_negotiation_timeout = "10s"
gc_interval = "30s"
gc_lifetime = "60s"
max_external_packet_size = 1500

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
self_sign = false
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3", "h2", "http/1.1"]

[restful]
addr = "127.0.0.1:$((TUIC_PORT + 10000))"
secret = "$rest_secret"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = 1500
min_mtu = 1200
gso = true
pmtu = true
send_window = 67108864
receive_window = 33554432
max_idle_time = "60s"

[quic.congestion_control]
controller = "bbr"
initial_window = 8388608
EOF
}

# ==================== 获取服务器 IP (静默) ====================
get_server_ip() {
    local ip
    ip=$(curl -s --connect-timeout 3 https://api.ipify.org 2>/dev/null || \
         curl -s --connect-timeout 3 https://ifconfig.me 2>/dev/null || \
         echo "YOUR_SERVER_IP")
    echo "$ip"
}

# ==================== 生成连接链接 (修复 allowInsecure) ====================
generate_link() {
    local ip="$1"
    
    # 关键修复: allowInsecure=1 (不是 allow_insecure)
    local tuic_link="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1#TUIC-${ip}"
    
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
  ALPN: h3, h2, http/1.1
  拥塞控制: BBR
  跳过证书验证: 是 (allowInsecure=1)

支持客户端:
  - v2rayN (最新版, 推荐)
  - NekoRay
  - Clash Meta (Premium 核心)
  - sing-box

性能优化说明:
  - 发送窗口: 64MB (高带宽优化)
  - 接收窗口: 32MB
  - 初始拥塞窗口: 8MB
  - 空闲超时: 60s (稳定性优化)
  
安全性增强:
  - ALPN 伪装: h3, h2, http/1.1 (模拟正常流量)
  - 认证超时: 15s (防暴力破解)
  - 零日志模式 (log_level = off)
  - 随机化 RESTful 密钥

注意事项:
  1. 节点链接已自动配置 allowInsecure=1
  2. v2rayN 中无需手动修改,直接导入即可
  3. 如遇连接问题,请检查服务器端口是否开放
  4. 建议使用最新版客户端以获得最佳性能
EOF
    
    # 只输出连接字符串,其他信息静默
    echo "$tuic_link"
}

# ==================== 主流程 ====================
main() {
    # 初始化
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    
    # 检查是否首次运行
    local is_first_run=0
    if ! load_existing_config; then
        is_first_run=1
        SHOW_INIT_LOG=1
        
        log_info "⚙️  TUIC v5 初始化中..."
        
        check_env_vars "$@"
        
        # 生成随机凭证
        if command -v uuidgen >/dev/null 2>&1; then
            TUIC_UUID="$(uuidgen)"
        else
            TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)"
        fi
        TUIC_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 16)"
        
        log_info "🔑 UUID: $TUIC_UUID"
        log_info "🔑 密码: $TUIC_PASSWORD"
        log_info "🎯 SNI: $MASQ_DOMAIN"
        log_info ""
    fi
    
    # 静默执行所有设置
    generate_cert
    download_tuic_server
    generate_config
    
    # 生成连接信息
    local server_ip
    server_ip=$(get_server_ip)
    local tuic_link
    tuic_link=$(generate_link "$server_ip")
    
    # 只在首次运行时显示完整信息
    if [[ $is_first_run -eq 1 ]]; then
        log_info "==========================================="
        log_info "✅ TUIC 部署完成!"
        log_info "==========================================="
        log_info ""
        log_info "📱 节点连接字符串:"
        log_info "$tuic_link"
        log_info ""
        log_info "📄 详细信息已保存至: $WORKDIR/$LINK_TXT"
        log_info ""
        log_info "⚠️  重要: 已自动配置 allowInsecure=1"
        log_info "   v2rayN 导入后无需修改任何设置"
        log_info ""
        log_info "🚀 服务启动中,控制台将保持静默..."
        log_info "==========================================="
        log_info ""
    fi
    
    # 启动服务 (完全静默,带自动重启)
    while true; do
        "$WORKDIR/$TUIC_BIN" -c "$WORKDIR/$SERVER_TOML" >/dev/null 2>&1 || {
            sleep 3
        }
    done
}

# ==================== 入口点 ====================
main "$@"
