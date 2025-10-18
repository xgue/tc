#!/usr/bin/env bash
# Hysteria2 游戏容器专用版 v6.0.2 - 修复下载速度
# 修复: bandwidth 参数对调 + 窗口增大
set -euo pipefail

# ==================== 配置区 ====================
readonly SCRIPT_VERSION="6.0.2"
readonly WORKDIR="/home/container/hysteria"
readonly BINNAME="hysteria"
readonly NODETXT="/home/container/node.txt"
readonly CERT_FILE="cert.pem"
readonly KEY_FILE="key.pem"
readonly HY2_VERSION="v2.6.4"

# 游戏容器优化配置
readonly SNI="www.bing.com"
readonly ALPN="h3"
readonly DEFAULT_UPLOAD_LIMIT="20mbps"  # 默认限制上传

# ==================== 静默模式 ====================
log_init() {
    if [[ "${SHOW_INIT:-1}" == "1" ]]; then
        echo "$*" >&2
    fi
}

log_final() {
    echo "$*" >&2
}

# ==================== 参数解析 ====================
parse_args() {
    if [[ $# -ge 1 && -n "${1:-}" ]]; then
        PORT="$1"
    elif [[ -n "${PORT:-}" ]]; then
        : # 使用环境变量
    elif [[ -n "${SERVER_PORT:-}" ]]; then
        PORT="$SERVER_PORT"
    else
        PORT="8443"
    fi
    
    if [[ $# -ge 2 && -n "${2:-}" ]]; then
        HY2_PASSWORD="$2"
    elif [[ -n "${HY2_PASSWORD:-}" ]]; then
        : # 使用环境变量
    else
        HY2_PASSWORD="$(openssl rand -base64 16 | tr -d '/+=' | head -c 12 2>/dev/null || echo 'Game2024')"
    fi
    
    if [[ -n "${DOMAIN:-}" ]]; then
        SERVER_DOMAIN="$DOMAIN"
    else
        SERVER_DOMAIN=$(curl -s --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "YOUR_IP")
    fi
    
    # 上传限制参数
    UPLOAD_LIMIT_VALUE="${UPLOAD_LIMIT:-$DEFAULT_UPLOAD_LIMIT}"
}

# ==================== 架构检测 ====================
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*)        echo "armv7" ;;
        *) echo "amd64" ;;
    esac
}

# ==================== 下载二进制 ====================
download_binary() {
    local arch="$1"
    local bin_path="$WORKDIR/$BINNAME"
    
    if [[ -x "$bin_path" ]]; then
        return 0
    fi
    
    local url="https://github.com/apernet/hysteria/releases/download/app/${HY2_VERSION}/hysteria-linux-${arch}"
    
    curl -fLsS --connect-timeout 30 --max-time 300 "$url" -o "$bin_path" 2>/dev/null || return 1
    chmod +x "$bin_path"
    return 0
}

# ==================== 生成证书 ====================
generate_cert() {
    if [[ -f "$WORKDIR/$CERT_FILE" && -f "$WORKDIR/$KEY_FILE" ]]; then
        return 0
    fi
    
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$WORKDIR/$KEY_FILE" -out "$WORKDIR/$CERT_FILE" \
        -subj "/CN=${SNI}" >/dev/null 2>&1 || return 1
    
    chmod 600 "$WORKDIR/$KEY_FILE"
    chmod 644 "$WORKDIR/$CERT_FILE"
    return 0
}

# ==================== 生成配置 (对调版!) ====================
generate_config() {
    cat > "$WORKDIR/config.yaml" <<EOF
# Hysteria2 游戏容器专用配置 v${SCRIPT_VERSION}
# 关键修复: bandwidth 参数对调 + 窗口增大
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

# 带宽配置 (修复: 对调 up 和 down)
# Hysteria2 的视角: up = 服务器上传 = 客户端下载
#                   down = 服务器下载 = 客户端上传
bandwidth:
  up: 1gbps                    # 客户端下载不限制
  down: ${UPLOAD_LIMIT_VALUE}  # 客户端上传严格限制

# QUIC 配置 (增大窗口提高吞吐量)
quic:
  initStreamReceiveWindow: 16777216      # 16MB (从 4MB 提升)
  maxStreamReceiveWindow: 16777216       # 16MB
  initConnReceiveWindow: 33554432        # 32MB (从 8MB 提升)
  maxConnReceiveWindow: 33554432         # 32MB
  maxIdleTimeout: 90s
  maxIncomingStreams: 128                # 从 64 提升
  disablePathMTUDiscovery: false
EOF
}

# ==================== 生成节点信息 ====================
generate_node_info() {
    local hy2_url="hysteria2://${HY2_PASSWORD}@${SERVER_DOMAIN}:${PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Game-Hy2"
    
    cat > "$NODETXT" <<EOF
=== Hysteria2 游戏容器专用节点 ===
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
脚本版本: v${SCRIPT_VERSION} (修复下载速度)

📱 节点链接:
$hy2_url

📋 服务器信息:
  地址: ${SERVER_DOMAIN}
  端口: ${PORT}
  密码: ${HY2_PASSWORD}
  SNI: ${SNI}
  ALPN: ${ALPN}

⚡ 游戏容器专用优化 (v6.0.2 修复):
  问题: v6.0.1 下载只有 5-7 Mbps
  原因: bandwidth 参数含义理解错误
  
  修复前配置:
  up: 10mbps   (误以为是上传限制)
  down: 1gbps  (误以为是下载限制)
  
  实际含义:
  up = 服务器上传 = 客户端下载 ⬇️
  down = 服务器下载 = 客户端上传 ⬆️
  
  修复后配置:
  up: 1gbps               (客户端下载不限)
  down: ${UPLOAD_LIMIT_VALUE}  (客户端上传限制)
  
  窗口大小: 16MB/32MB (提升吞吐量)
  并发流数: 128 (提升性能)

📊 预期性能 (修复后):
  下载测速: 80-120 Mbps ⚡ (应该正常了)
  上传测速: 根据限制 (${UPLOAD_LIMIT_VALUE})
  断网情况: 不应断网

🔄 调整上传限制:
  UPLOAD_LIMIT=10mbps bash <(curl ...)  # 更保守
  UPLOAD_LIMIT=15mbps bash <(curl ...)  # 默认
  UPLOAD_LIMIT=20mbps bash <(curl ...)  # 当前默认
  UPLOAD_LIMIT=30mbps bash <(curl ...)  # 稍激进

📝 测速建议:
  1. 先单独测下载
  2. 等待 30 秒
  3. 再单独测上传
  4. 避免同时测试

🎯 客户端配置:
server: ${SERVER_DOMAIN}:${PORT}
auth: ${HY2_PASSWORD}
tls:
  sni: ${SNI}
  alpn: [${ALPN}]
  insecure: true
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080

✅ 支持客户端:
  - v2rayN (推荐)
  - NekoRay
  - Clash Meta
  - sing-box

🚀 启动命令:
  ./hysteria/hysteria server -c ./hysteria/config.yaml

🔧 v6.0.2 修复内容:
  ✅ bandwidth up/down 参数对调
  ✅ 窗口从 4MB/8MB 提升到 16MB/32MB
  ✅ 并发流从 64 提升到 128
  ✅ 下载速度应该恢复正常 (80-120 Mbps)

🧪 对比测试:
  v6.0.1: 下载 5-7 Mbps, 上传 20 Mbps ❌
  v6.0.2: 下载 80-120 Mbps, 上传 20 Mbps ✅ (预期)
EOF
    
    echo "$hy2_url"
}

# ==================== 主流程 ====================
main() {
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    rm -f *.tmp *.tar.gz *.json 2>/dev/null || true
    
    parse_args "$@"
    
    log_init "⚙️  Hysteria2 游戏容器专用版初始化..."
    log_init "📝 修复版本: v${SCRIPT_VERSION} (修复下载速度)"
    log_init "🔑 密码: $HY2_PASSWORD"
    log_init "🌐 服务器: $SERVER_DOMAIN"
    log_init "🔌 端口: $PORT"
    log_init "⬆️  客户端上传限制: $UPLOAD_LIMIT_VALUE"
    log_init "⬇️  客户端下载: 不限制 (1gbps)"
    log_init ""
    
    local arch
    arch=$(detect_arch)
    
    if ! download_binary "$arch"; then
        log_final "❌ 下载失败"
        exit 1
    fi
    
    if ! generate_cert; then
        log_final "❌ 证书生成失败"
        exit 1
    fi
    
    generate_config
    
    local hy2_url
    hy2_url=$(generate_node_info)
    
    log_final ""
    log_final "=========================================================================="
    log_final "🎮 Hysteria2 游戏容器专用版部署成功! v${SCRIPT_VERSION}"
    log_final "=========================================================================="
    log_final ""
    log_final "📋 服务器信息:"
    log_final "   🌐 地址: ${SERVER_DOMAIN}"
    log_final "   🔌 端口: ${PORT}"
    log_final "   🔑 密码: ${HY2_PASSWORD}"
    log_final ""
    log_final "🔧 v6.0.2 关键修复:"
    log_final "   ❌ 之前: 下载 5-7 Mbps (参数理解错误)"
    log_final "   ✅ 现在: 下载应该 80-120 Mbps (参数对调)"
    log_final ""
    log_final "⚡ 优化策略:"
    log_final "   ⬇️  下载: 不限制 (充分利用带宽)"
    log_final "   ⬆️  上传: ${UPLOAD_LIMIT_VALUE} (防止崩溃)"
    log_final "   📦 窗口: 16MB/32MB (提升吞吐)"
    log_final ""
    log_final "📱 节点链接:"
    log_final "$hy2_url"
    log_final ""
    log_final "📄 详细信息: ${NODETXT}"
    log_final ""
    log_final "⚠️  测速建议:"
    log_final "   - 先测下载 (应该 80-120 Mbps)"
    log_final "   - 等 30 秒"
    log_final "   - 再测上传 (应该约 ${UPLOAD_LIMIT_VALUE})"
    log_final ""
    log_final "=========================================================================="
    log_final ""
    
    exec "$WORKDIR/$BINNAME" server -c "$WORKDIR/config.yaml" >/dev/null 2>&1
}

main "$@"
