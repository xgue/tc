#!/bin/bash
# Argo 隧道一键部署脚本 - 优化版 Gemini 访问
# 用法: bash argo.sh [HTTP_PORT] [UUID] [CFIP] [NAME]
# 示例: bash argo.sh 3000 9afd1229-b893-40c1-84dd-51e7ce204913 cdns.doon.eu.org Gemini-Argo

set -euo pipefail

# ==================== 参数解析 ====================
HTTP_PORT="${1:-3000}"
UUID="${2:-9afd1229-b893-40c1-84dd-51e7ce204913}"
CFIP="${3:-cdns.doon.eu.org}"
NAME="${4:-Gemini-Argo}"
ARGO_PORT="${ARGO_PORT:-8001}"
CFPORT="${CFPORT:-443}"

WORKDIR="/home/container/argo"
FILE_PATH="$WORKDIR/tmp"

# ==================== 日志函数 ====================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_info() {
    echo "ℹ️  $*"
}

log_success() {
    echo "✅ $*"
}

log_error() {
    echo "❌ $*" >&2
}

log_warn() {
    echo "⚠️  $*"
}

# ==================== 显示参数 ====================
show_config() {
    log "=========================================="
    log "🔧 Argo 隧道配置参数"
    log "=========================================="
    log "HTTP 端口:     $HTTP_PORT"
    log "Argo 内部端口: $ARGO_PORT"
    log "UUID:          $UUID"
    log "优选域名:      $CFIP:$CFPORT"
    log "节点名称:      $NAME"
    log "工作目录:      $WORKDIR"
    log "=========================================="
}

# ==================== 环境检查 ====================
check_environment() {
    log "检查环境..."
    
    if ! command -v node &> /dev/null; then
        log_error "Node.js 未安装"
        exit 1
    fi
    
    if ! command -v npm &> /dev/null; then
        log_error "npm 未安装"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        log_error "curl 未安装"
        exit 1
    fi
    
    log_success "环境检查通过"
}

# ==================== 创建目录和文件 ====================
setup_project() {
    log "初始化项目..."
    
    # 创建工作目录
    mkdir -p "$WORKDIR"
    mkdir -p "$FILE_PATH"
    cd "$WORKDIR"
    
    log_success "目录创建完成"
}

# ==================== 生成 package.json ====================
create_package_json() {
    log "生成 package.json..."
    
    cat > "$WORKDIR/package.json" <<'JSONEOF'
{
  "name": "nodejs-argo",
  "version": "1.0.0",
  "description": "Xray + Argo 隧道 + Gemini 访问专用",
  "main": "index.js",
  "author": "your-name",
  "license": "MIT",
  "private": false,
  "scripts": {
    "start": "node index.js"
  },
  "dependencies": {
    "axios": "latest",
    "express": "^4.18.2"
  },
  "engines": {
    "node": ">=14"
  }
}
JSONEOF

    log_success "package.json 已生成"
}

# ==================== 生成 index.js ====================
create_index_js() {
    log "生成 index.js..."
    
    cat > "$WORKDIR/index.js" <<'JSEOF'
const express = require("express");
const app = express();
const axios = require("axios");
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

// ==================== 配置变量 ====================
const PORT = process.env.PORT || process.env.SERVER_PORT || 3000;
const UUID = process.env.UUID || "9afd1229-b893-40c1-84dd-51e7ce204913";
const ARGO_PORT = process.env.ARGO_PORT || 8001;
const CFIP = process.env.CFIP || "cdns.doon.eu.org";
const CFPORT = process.env.CFPORT || 443;
const NAME = process.env.NAME || "Gemini-Argo";
const FILE_PATH = process.env.FILE_PATH || "./tmp";

// 创建临时文件夹
if (!fs.existsSync(FILE_PATH)) {
  fs.mkdirSync(FILE_PATH, { recursive: true });
}

const bootLogPath = path.join(FILE_PATH, "boot.log");
const configPath = path.join(FILE_PATH, "config.json");
const subPath = path.join(FILE_PATH, "sub.txt");

// ==================== Xray 配置 ====================
function generateConfig() {
  const config = {
    log: { access: "/dev/null", error: "/dev/null", loglevel: "none" },
    inbounds: [
      {
        port: ARGO_PORT,
        protocol: "vless",
        settings: {
          clients: [{ id: UUID, flow: "xtls-rprx-vision" }],
          decryption: "none",
          fallbacks: [
            { dest: 3001 },
            { path: "/vless-argo", dest: 3002 },
            { path: "/vmess-argo", dest: 3003 },
            { path: "/trojan-argo", dest: 3004 }
          ]
        },
        streamSettings: { network: "tcp" }
      },
      {
        port: 3001,
        listen: "127.0.0.1",
        protocol: "vless",
        settings: { clients: [{ id: UUID }], decryption: "none" },
        streamSettings: { network: "tcp", security: "none" }
      },
      {
        port: 3002,
        listen: "127.0.0.1",
        protocol: "vless",
        settings: { clients: [{ id: UUID, level: 0 }], decryption: "none" },
        streamSettings: {
          network: "ws",
          security: "none",
          wsSettings: { path: "/vless-argo" }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false }
      },
      {
        port: 3003,
        listen: "127.0.0.1",
        protocol: "vmess",
        settings: { clients: [{ id: UUID, alterId: 0 }] },
        streamSettings: {
          network: "ws",
          wsSettings: { path: "/vmess-argo" }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false }
      },
      {
        port: 3004,
        listen: "127.0.0.1",
        protocol: "trojan",
        settings: { clients: [{ password: UUID }] },
        streamSettings: {
          network: "ws",
          security: "none",
          wsSettings: { path: "/trojan-argo" }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false }
      }
    ],
    dns: { servers: ["https+local://8.8.8.8/dns-query"] },
    outbounds: [
      { protocol: "freedom", tag: "direct" },
      { protocol: "blackhole", tag: "block" }
    ]
  };
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
}

// ==================== 架构检测 ====================
function getArchitecture() {
  const arch = require("os").arch();
  return arch === "arm" || arch === "arm64" || arch === "aarch64" ? "arm" : "amd";
}

// ==================== 下载文件 ====================
async function downloadFile(fileName, fileUrl) {
  const filePath = path.join(FILE_PATH, fileName);
  try {
    const response = await axios({
      method: "get",
      url: fileUrl,
      responseType: "stream",
      timeout: 60000
    });

    return new Promise((resolve, reject) => {
      const writer = fs.createWriteStream(filePath);
      response.data.pipe(writer);
      writer.on("finish", () => {
        fs.chmodSync(filePath, 0o755);
        console.log(`✅ ${fileName} 下载成功`);
        resolve(filePath);
      });
      writer.on("error", (err) => {
        fs.unlinkSync(filePath);
        reject(new Error(`下载 ${fileName} 失败: ${err.message}`));
      });
    });
  } catch (err) {
    throw new Error(`下载 ${fileName} 失败: ${err.message}`);
  }
}

// ==================== 主程序 ====================
async function startService() {
  try {
    console.log("\n🚀 Argo 隧道初始化中...\n");
    
    generateConfig();
    console.log("📝 配置文件已生成");

    const arch = getArchitecture();
    const webUrl = arch === "arm" 
      ? "https://arm64.ssss.nyc.mn/web"
      : "https://amd64.ssss.nyc.mn/web";
    const botUrl = arch === "arm"
      ? "https://arm64.ssss.nyc.mn/bot"
      : "https://amd64.ssss.nyc.mn/bot";

    const webPath = path.join(FILE_PATH, "xray");
    const botPath = path.join(FILE_PATH, "cloudflare");

    if (!fs.existsSync(webPath)) {
      await downloadFile("xray", webUrl);
    }
    if (!fs.existsSync(botPath)) {
      await downloadFile("cloudflare", botUrl);
    }

    try {
      execSync(`nohup ${webPath} -c ${configPath} >/dev/null 2>&1 &`);
      console.log("🔧 Xray 已启动");
    } catch (e) {
      console.error("❌ Xray 启动失败");
    }

    try {
      const args = `tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile ${bootLogPath} --loglevel info --url http://localhost:${ARGO_PORT}`;
      execSync(`nohup ${botPath} ${args} >/dev/null 2>&1 &`);
      console.log("🌐 Cloudflare 隧道已启动");
    } catch (e) {
      console.error("❌ Cloudflare 隧道启动失败");
    }

    await new Promise((resolve) => setTimeout(resolve, 3000));
    await extractDomainsAndGenerateLinks();

  } catch (error) {
    console.error("❌ 启动失败:", error.message);
  }
}

// ==================== 提取域名并生成链接 ====================
async function extractDomainsAndGenerateLinks() {
  const maxRetries = 10;
  let retries = 0;

  while (retries < maxRetries) {
    try {
      if (!fs.existsSync(bootLogPath)) {
        await new Promise((resolve) => setTimeout(resolve, 2000));
        retries++;
        continue;
      }

      const fileContent = fs.readFileSync(bootLogPath, "utf-8");
      const domainMatch = fileContent.match(/https?:\/\/([^ ]*trycloudflare\.com)\/?/);

      if (domainMatch) {
        const argoDomain = domainMatch[1];
        console.log(`\n✅ Argo 域名: ${argoDomain}\n`);
        
        await generateSubscriptionLinks(argoDomain);
        return;
      }

      await new Promise((resolve) => setTimeout(resolve, 2000));
      retries++;
    } catch (error) {
      console.error("提取域名错误:", error.message);
      retries++;
    }
  }

  console.warn("⚠️  无法提取 Argo 域名，请检查日志");
}

// ==================== 生成订阅链接 ====================
async function generateSubscriptionLinks(argoDomain) {
  try {
    let ISP = "CF";
    try {
      ISP = execSync(
        'curl -sm 5 https://speed.cloudflare.com/meta | grep -oP \'(?<="colo":")\\w+(?=")\' 2>/dev/null',
        { encoding: "utf-8", stdio: ["pipe", "pipe", "ignore"] }
      ).trim() || "CF";
    } catch (e) {
      ISP = "CF";
    }

    const nodeName = `${NAME}-${ISP}`;

    const VMESS = {
      v: "2",
      ps: nodeName,
      add: CFIP,
      port: CFPORT,
      id: UUID,
      aid: "0",
      scy: "none",
      net: "ws",
      type: "none",
      host: argoDomain,
      path: "/vmess-argo?ed=2560",
      tls: "tls",
      sni: argoDomain,
      alpn: "",
      fp: "firefox"
    };

    const subTxt = `vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argoDomain}&fp=firefox&type=ws&host=${argoDomain}&path=%2Fvless-argo%3Fed%3D2560#${nodeName}

vmess://${Buffer.from(JSON.stringify(VMESS)).toString("base64")}

trojan://${UUID}@${CFIP}:${CFPORT}?security=tls&sni=${argoDomain}&fp=firefox&type=ws&host=${argoDomain}&path=%2Ftrojan-argo%3Fed%3D2560#${nodeName}`;

    const base64Sub = Buffer.from(subTxt).toString("base64");
    
    fs.writeFileSync(subPath, base64Sub);

    console.log("========================================");
    console.log("📋 订阅链接 (Base64编码):");
    console.log("========================================");
    console.log(base64Sub);
    console.log("========================================\n");

    app.get("/sub", (req, res) => {
      res.set("Content-Type", "text/plain; charset=utf-8");
      res.send(base64Sub);
    });

    console.log(`✅ 订阅端点: http://localhost:${PORT}/sub\n`);

  } catch (error) {
    console.error("生成订阅链接失败:", error.message);
  }
}

app.get("/", (req, res) => {
  res.send("✅ Argo 隧道服务运行中!");
});

app.listen(PORT, () => {
  console.log(`🌐 HTTP 服务运行在端口: ${PORT}`);
  console.log("========================================\n");
});

startService().catch(console.error);
JSEOF

    log_success "index.js 已生成"
}

# ==================== 安装依赖 ====================
install_dependencies() {
    log "安装 npm 依赖..."
    
    cd "$WORKDIR"
    npm install --silent 2>/dev/null || {
        log_error "npm 安装失败"
        exit 1
    }
    
    log_success "npm 依赖安装完成"
}

# ==================== 启动服务 ====================
start_service() {
    log "启动 Argo 隧道服务..."
    
    cd "$WORKDIR"
    
    export PORT="$HTTP_PORT"
    export UUID="$UUID"
    export ARGO_PORT="$ARGO_PORT"
    export CFIP="$CFIP"
    export CFPORT="$CFPORT"
    export NAME="$NAME"
    export FILE_PATH="$FILE_PATH"
    
    nohup node index.js > "$WORKDIR/service.log" 2>&1 &
    SERVICE_PID=$!
    
    echo $SERVICE_PID > "$WORKDIR/.service.pid"
    
    log_success "服务已启动 (PID: $SERVICE_PID)"
    
    # 等待服务初始化
    log "等待服务初始化..."
    sleep 2
    
    # 显示日志
    log "=========================================="
    tail -20 "$WORKDIR/service.log"
    log "=========================================="
}

# ==================== 显示使用信息 ====================
show_usage() {
    log_info "Service log: $WORKDIR/service.log"
    log_info "查看日志: tail -f $WORKDIR/service.log"
    log_info "查看订阅链接: curl http://localhost:$HTTP_PORT/sub"
    log_info ""
    log_info "☑️  参数可通过环境变量修改:"
    log_info "   PORT=$HTTP_PORT"
    log_info "   UUID=$UUID"
    log_info "   CFIP=$CFIP"
    log_info "   CFPORT=$CFPORT"
    log_info "   NAME=$NAME"
    log_info "   ARGO_PORT=$ARGO_PORT"
}

# ==================== 主程序 ====================
main() {
    show_config
    check_environment
    setup_project
    create_package_json
    create_index_js
    install_dependencies
    start_service
    show_usage
}

main "$@"
