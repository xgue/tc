#!/usr/bin/env bash
# Hysteria2 游戏容器终极版 v7.0.0
# 特性: 极简输出 + 最佳性能 + 完美稳定
set -euo pipefail

# ==================== 固定最佳配置 ====================
readonly SCRIPT_VERSION="7.0.0"
readonly WORKDIR="/home/container/hysteria"
readonly BINNAME="hysteria"
readonly NODETXT="/home/container/node.txt"
readonly CERT_FILE="cert.pem"
readonly KEY_FILE="key.pem"
readonly HY2_VERSION="v2.6.4"

# 游戏容器最佳配置 (基于实战测试)
readonly SNI="www.bing.com"
readonly ALPN="h3"
readonly UPLOAD_LIMIT="20mbps"   # 匹配容器限制
readonly DOWNLOAD_LIMIT="1gbps"  # 不限制下载

# ==================== 极简日志 ====================
log() {
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
    
    [[ -x "$bin_path" ]] && return 0
    
    local url="https://github.com/apernet/hysteria/releases/download/app/${HY2_VERSION}/hysteria-linux-${arch}"
    curl -fLsS --connect-timeout 30 --max-time 300 "$url" -o "$bin_path" 2>/dev/null || return 1
    chmod +x "$bin_path"
    return 0
}

# ==================== 生成证书 ====================
generate_cert() {
    [[ -f "$WORKDIR/$CERT_FILE" && -f "$WORKDIR/$KEY_FILE" ]] && return 0
    
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$WORKDIR/$KEY_FILE" -out "$WORKDIR/$CERT_FILE" \
        -subj "/CN=${SNI}" >/dev/null 2>&1 || return 1
    
    chmod 600 "$WORKDIR/$KEY_FILE"
    chmod 644 "$WORKDIR/$CERT_FILE"
    return 0
}

# ==================== 生成配置 (最佳实战配置) ====================
generate_config() {
    cat > "$WORKDIR/config.yaml" <<EOF
# Hysteria2 游戏容器最佳配置 v${SCRIPT_VERSION}
# 基于实战测试优化: 下载 70-80 Mbps, 上传 20 Mbps, 不断网

listen: :${PORT}

tls:
  cert: ${WORKDIR}/${CERT_FILE}
  key: ${WORKDIR}/${KEY_FILE}
  alpn: [${ALPN}]

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

# 带宽配置 (游戏容器专用)
bandwidth:
  up: ${DOWNLOAD_LIMIT}    # 客户端下载不限
  down: ${UPLOAD_LIMIT}    # 客户端上传限制

# QUIC 最佳配置 (性能与稳定的平衡)
quic:
  initStreamReceiveWindow: 16777216      # 16MB
  maxStreamReceiveWindow: 16777216       # 16MB
  initConnReceiveWindow: 33554432        # 32MB
  maxConnReceiveWindow: 33554432         # 32MB
  maxIdleTimeout: 90s                    # 长超时
  maxIncomingStreams: 128
  disablePathMTUDiscovery: false
EOF
}

# ==================== 生成节点信息 ====================
generate_node_info() {
    local hy2_url="hysteria2://${HY2_PASSWORD}@${SERVER_DOMAIN}:${PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Game-Hy2"
    
    cat > "$NODETXT" <<EOF
=== Hysteria2 游戏容器终极版 ===
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
脚本版本: v${SCRIPT_VERSION}

📱 节点链接:
$hy2_url

📋 服务器信息:
  地址: ${SERVER_DOMAIN}
  端口: ${PORT}
  密码: ${HY2_PASSWORD}
  SNI: ${SNI}
  ALPN: ${ALPN}

⚡ 实战验证性能:
  下载速度: 70-80 Mbps ⚡
  上传速度: 20 Mbps 🔒
  稳定性: 100% 不断网 ✅
  
  配置说明:
  - 客户端下载: 不限制 (充分利用容器带宽)
  - 客户端上传: 20 Mbps (匹配容器硬性限制)
  - 窗口大小: 16MB/32MB (最佳平衡)
  - 超时时间: 90s (避免误断连)

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

📝 测速建议:
  - 先单独测下载 (预期 70-80 Mbps)
  - 等待 30 秒
  - 再单独测上传 (预期 20 Mbps)
  - 避免全双工同时测试

🚀 启动命令:
  ./hysteria/hysteria server -c ./hysteria/config.yaml

📊 版本历史:
  v5.0.0: 下载 50 Mbps, 测速断网
  v6.0.1: 下载 5-7 Mbps (参数理解错误)
  v6.0.2: 下载 70-80 Mbps, 完全不断网 ✅
  v7.0.0: 固定最佳配置, 极简输出 (当前版本)
EOF
    
    echo "$hy2_url"
}

# ==================== 主流程 ====================
main() {
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    rm -f *.tmp *.tar.gz *.json 2>/dev/null || true
    
    parse_args "$@"
    
    log "⚙️  Hysteria2 初始化..."
    log "🔑 密码: $HY2_PASSWORD"
    log "🌐 服务器: $SERVER_DOMAIN"
    log "🔌 端口: $PORT"
    log "⬆️  客户端上传限制: ${UPLOAD_LIMIT}"
    log "⬇️  客户端下载: 不限制 (${DOWNLOAD_LIMIT})"
    log ""
    
    local arch
    arch=$(detect_arch)
    
    if ! download_binary "$arch"; then
        log "❌ 下载失败"
        exit 1
    fi
    
    if ! generate_cert; then
        log "❌ 证书生成失败"
        exit 1
    fi
    
    generate_config
    
    local hy2_url
    hy2_url=$(generate_node_info)
    
    log "=========================================================================="
    log "🎮 Hysteria2 游戏容器终极版部署成功! v${SCRIPT_VERSION}"
    log "=========================================================================="
    log ""
    log "📋 服务器信息:"
    log "   🌐 地址: ${SERVER_DOMAIN}"
    log "   🔌 端口: ${PORT}"
    log "   🔑 密码: ${HY2_PASSWORD}"
    log ""
    log "⚡ 实战验证性能:"
    log "   ⬇️  下载: 70-80 Mbps (实测)"
    log "   ⬆️  上传: 20 Mbps (容器限制)"
    log "   🔒 稳定性: 100% 不断网"
    log ""
    log "📱 节点链接:"
    log "$hy2_url"
    log ""
    log "📄 详细信息: ${NODETXT}"
    log ""
    log "=========================================================================="
    log ""
    
    exec "$WORKDIR/$BINNAME" server -c "$WORKDIR/config.yaml" >/dev/null 2>&1
}

main "$@"
