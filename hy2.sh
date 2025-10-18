#!/usr/bin/env bash
# Hysteria2 终极版部署脚本 v5.0.0
# 融合: 极简输出 + 稳定下载 + 灵活配置 + 高性能优化
set -euo pipefail

# ==================== 配置区 ====================
readonly SCRIPT_VERSION="5.0.0"
readonly WORKDIR="/home/container/hysteria"
readonly BINNAME="hysteria"
readonly NODETXT="/home/container/node.txt"
readonly CERT_FILE="cert.pem"
readonly KEY_FILE="key.pem"

# 默认值
readonly DEFAULT_PORT="8443"
readonly DEFAULT_PASSWORD="$(openssl rand -base64 16 | tr -d '/+=' | head -c 12 2>/dev/null || echo 'ChangeMe123')"
readonly SNI="${SNI:-www.bing.com}"
readonly ALPN="${ALPN:-h3}"

# 网络配置
readonly DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-300}"
readonly MAX_RETRIES="${MAX_RETRIES:-3}"
readonly RETRY_DELAY="${RETRY_DELAY:-3}"
readonly GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Hysteria 版本
readonly HY2_VERSION="${HY2_VERSION:-v2.6.4}"

# ==================== 静默日志 ====================
SILENT_MODE="${SILENT_MODE:-1}"  # 1=静默, 0=显示详细日志

log_info() {
    if [[ "$SILENT_MODE" == "0" ]]; then
        echo "$*" >&2
    fi
}

log_output() {
    # 总是输出(用于最终结果)
    echo "$*" >&2
}

# ==================== 错误处理 ====================
cleanup() {
    rm -f "$WORKDIR"/*.tmp "$WORKDIR"/*.tar.gz "$WORKDIR"/*.json 2>/dev/null || true
}

trap 'cleanup; exit 1' ERR INT TERM

# ==================== 参数解析 ====================
parse_args() {
    # 支持多种输入方式
    # 方式1: bash script.sh 端口 [密码]
    # 方式2: DOMAIN=xx PORT=xx HY2_PASSWORD=xx bash script.sh
    # 方式3: curl | bash -s -- 端口 [密码]
    
    if [[ $# -ge 1 && -n "${1:-}" ]]; then
        PORT="$1"
        log_info "✅ 使用命令行参数端口: $PORT"
    elif [[ -n "${PORT:-}" ]]; then
        log_info "✅ 使用环境变量 PORT: $PORT"
    elif [[ -n "${SERVER_PORT:-}" ]]; then
        PORT="$SERVER_PORT"
        log_info "✅ 使用环境变量 SERVER_PORT: $PORT"
    else
        PORT="$DEFAULT_PORT"
        log_info "⚙️  使用默认端口: $PORT"
    fi
    
    if [[ $# -ge 2 && -n "${2:-}" ]]; then
        HY2_PASSWORD="$2"
        log_info "✅ 使用命令行参数密码"
    elif [[ -n "${HY2_PASSWORD:-}" ]]; then
        log_info "✅ 使用环境变量 HY2_PASSWORD"
    else
        HY2_PASSWORD="$DEFAULT_PASSWORD"
        log_info "🔑 生成随机密码: $HY2_PASSWORD"
    fi
    
    # 自动检测域名
    if [[ -n "${DOMAIN:-}" ]]; then
        SERVER_DOMAIN="$DOMAIN"
        log_info "✅ 使用自定义域名: $SERVER_DOMAIN"
    else
        SERVER_DOMAIN=$(get_server_ip)
        log_info "🌐 使用服务器 IP: $SERVER_DOMAIN"
    fi
}

# ==================== 架构检测 ====================
detect_arch() {
    local arch
    arch=$(uname -m | tr '[:upper:]' '[:lower:]')
    
    case "$arch" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7|armv7l)  echo "armv7" ;;
        *) 
            log_output "❌ 不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# ==================== 获取服务器 IP ====================
get_server_ip() {
    local ip
    ip=$(curl -s --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || \
         curl -s --connect-timeout 5 --max-time 10 https://ifconfig.me 2>/dev/null || \
         echo "YOUR_SERVER_IP")
    echo "$ip"
}

# ==================== 带重试的下载 ====================
download_with_retry() {
    local url="$1"
    local output="$2"
    local attempt=0
    
    while [ $attempt -lt "$MAX_RETRIES" ]; do
        attempt=$((attempt + 1))
        log_info "⏳ 下载尝试 $attempt/$MAX_RETRIES"
        
        if curl -fLsS --connect-timeout 30 --max-time "$DOWNLOAD_TIMEOUT" \
                ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} \
                "$url" -o "$output" 2>/dev/null; then
            return 0
        fi
        
        log_info "⚠️  下载失败,重试中..."
        [ $attempt -lt "$MAX_RETRIES" ] && sleep "$RETRY_DELAY"
    done
    
    log_output "❌ 下载失败: $url"
    return 1
}

# ==================== 下载 Hysteria 二进制 ====================
download_hysteria() {
    local arch="$1"
    local bin_name="hysteria-linux-${arch}"
    local bin_path="$WORKDIR/$BINNAME"
    
    if [[ -x "$bin_path" ]]; then
        log_info "✅ 二进制已存在,跳过下载"
        return 0
    fi
    
    log_info "📥 下载 Hysteria2 ${HY2_VERSION}..."
    
    local download_url="https://github.com/apernet/hysteria/releases/download/app/${HY2_VERSION}/${bin_name}"
    
    if download_with_retry "$download_url" "$bin_path"; then
        chmod +x "$bin_path"
        log_info "✅ 下载完成: $bin_path"
        return 0
    else
        log_output "❌ 下载失败,请检查网络或手动下载"
        return 1
    fi
}

# ==================== 生成证书 (静默) ====================
generate_cert() {
    if [[ -f "$WORKDIR/$CERT_FILE" && -f "$WORKDIR/$KEY_FILE" ]]; then
        log_info "✅ 证书已存在,跳过生成"
        return 0
    fi
    
    log_info "🔑 生成自签证书 (ECDSA P-256)..."
    
    if ! command -v openssl >/dev/null 2>&1; then
        log_output "❌ openssl 未安装"
        return 1
    fi
    
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$WORKDIR/$KEY_FILE" -out "$WORKDIR/$CERT_FILE" \
        -subj "/CN=${SNI}" >/dev/null 2>&1 || {
            log_output "❌ 证书生成失败"
            return 1
        }
    
    chmod 600 "$WORKDIR/$KEY_FILE"
    chmod 644 "$WORKDIR/$CERT_FILE"
    log_info "✅ 证书生成完成 (有效期: 3650 天)"
    return 0
}

# ==================== 生成配置文件 (高性能优化) ====================
generate_config() {
    cat > "$WORKDIR/config.yaml" <<EOF
# Hysteria2 高性能配置 v${SCRIPT_VERSION}
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

listen: :${PORT}

tls:
  cert: ${WORKDIR}/${CERT_FILE}
  key: ${WORKDIR}/${KEY_FILE}
  alpn:
    - ${ALPN}

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

# 性能优化配置
bandwidth:
  up: 500mbps
  down: 500mbps

quic:
  initStreamReceiveWindow: 8388608      # 8MB
  maxStreamReceiveWindow: 8388608       # 8MB
  initConnReceiveWindow: 20971520       # 20MB
  maxConnReceiveWindow: 20971520        # 20MB
  maxIdleTimeout: 60s
  maxIncomingStreams: 256
  disablePathMTUDiscovery: false
EOF
    
    log_info "✅ 配置文件已生成"
}

# ==================== 生成节点信息 ====================
generate_node_info() {
    local hy2_url="hysteria2://${HY2_PASSWORD}@${SERVER_DOMAIN}:${PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-${SERVER_DOMAIN}"
    
    cat > "$NODETXT" <<EOF
=== Hysteria2 节点信息 ===
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
脚本版本: v${SCRIPT_VERSION}

📱 节点链接:
$hy2_url

📋 手动配置参数:
  协议: Hysteria2
  服务器: ${SERVER_DOMAIN}
  端口: ${PORT}
  密码: ${HY2_PASSWORD}
  SNI: ${SNI}
  ALPN: ${ALPN}
  跳过证书验证: 是 (insecure=1)

📄 客户端配置文件:
server: ${SERVER_DOMAIN}:${PORT}
auth: ${HY2_PASSWORD}
tls:
  sni: ${SNI}
  alpn: [${ALPN}]
  insecure: true
bandwidth:
  up: 500mbps
  down: 500mbps
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080

🎯 支持客户端:
  - v2rayN (推荐,最新版)
  - NekoRay
  - Clash Meta (Premium 核心)
  - sing-box

⚡ 性能优化:
  - 带宽限制: 上传/下载 500Mbps
  - QUIC 窗口: 发送 8MB / 接收 20MB
  - 空闲超时: 60 秒
  - 拥塞控制: BBR (自动)

🔒 安全增强:
  - ALPN 伪装: ${ALPN}
  - 流量伪装: Bing.com
  - 证书类型: ECDSA P-256
  - 密码长度: $(echo -n "$HY2_PASSWORD" | wc -c) 字符

📝 注意事项:
  1. v2rayN 必须启用 "跳过证书验证 (allowInsecure)"
  2. 节点链接已自动配置 insecure=1,直接导入即可
  3. 如遇连接问题,请检查防火墙和端口开放状态
  4. 建议定期更换密码以提高安全性

🚀 启动命令:
  ./hysteria/hysteria server -c ./hysteria/config.yaml

📊 查看实时日志:
  tail -f /home/container/hysteria.log
EOF
    
    echo "$hy2_url"
}

# ==================== 主流程 ====================
main() {
    # 1. 初始化
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    cleanup
    
    # 2. 解析参数
    parse_args "$@"
    
    # 3. 检测架构
    local arch
    arch=$(detect_arch)
    log_info "🔍 系统架构: $arch"
    
    # 4. 下载二进制
    if ! download_hysteria "$arch"; then
        exit 1
    fi
    
    # 5. 生成证书
    if ! generate_cert; then
        exit 1
    fi
    
    # 6. 生成配置
    generate_config
    
    # 7. 生成节点信息
    local hy2_url
    hy2_url=$(generate_node_info)
    
    # 8. 输出最终结果 (总是显示)
    log_output ""
    log_output "=========================================================================="
    log_output "🎉 Hysteria2 部署成功! (极简优化版 v${SCRIPT_VERSION})"
    log_output "=========================================================================="
    log_output ""
    log_output "📋 服务器信息:"
    log_output "   🌐 地址: ${SERVER_DOMAIN}"
    log_output "   🔌 端口: ${PORT}"
    log_output "   🔑 密码: ${HY2_PASSWORD}"
    log_output ""
    log_output "📱 节点链接 (SNI=${SNI}, ALPN=${ALPN}):"
    log_output "$hy2_url"
    log_output ""
    log_output "📄 详细信息已保存至: ${NODETXT}"
    log_output ""
    log_output "⚠️  重要: v2rayN 必须启用 '跳过证书验证'"
    log_output "   节点链接已自动配置 insecure=1,直接导入即可"
    log_output ""
    log_output "=========================================================================="
    log_output ""
    
    # 9. 启动服务 (完全静默)
    log_info "🚀 启动 Hysteria2 服务..."
    exec "$WORKDIR/$BINNAME" server -c "$WORKDIR/config.yaml" >/dev/null 2>&1
}

# ==================== 入口点 ====================
main "$@"
