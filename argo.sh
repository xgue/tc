#!/bin/bash
# 订阅诊断脚本 - 排查订阅打不开的原因

echo "=========================================="
echo "📋 Argo 订阅诊断工具"
echo "=========================================="
echo ""

# 1. 检查服务是否运行
echo "【第 1 步】检查 Node.js 服务状态"
echo "=================================="
if pgrep -f "node index.js" > /dev/null; then
    echo "✅ Node.js HTTP 服务运行中"
    PID=$(pgrep -f "node index.js")
    echo "   PID: $PID"
    MEMORY=$(ps -p $PID -o rss= | awk '{print int($1/1024)"MB"}')
    echo "   内存: $MEMORY"
else
    echo "❌ Node.js HTTP 服务未运行"
    echo "   需要启动: bash /home/container/argo-lite.sh"
fi
echo ""

# 2. 检查端口是否监听
echo "【第 2 步】检查端口监听状态"
echo "=================================="
if netstat -tulpn 2>/dev/null | grep 3000 > /dev/null || ss -tulpn 2>/dev/null | grep 3000 > /dev/null; then
    echo "✅ 端口 3000 已监听"
else
    echo "❌ 端口 3000 未监听"
    echo "   原因: HTTP 服务未启动或崩溃"
fi
echo ""

# 3. 检查本地访问
echo "【第 3 步】测试本地访问"
echo "=================================="
if curl -s http://localhost:3000/ > /dev/null; then
    echo "✅ 本地访问正常"
    echo "   HTTP 服务可访问"
else
    echo "❌ 本地访问失败"
    echo "   原因: HTTP 服务崩溃或被占用"
fi
echo ""

# 4. 检查订阅端点
echo "【第 4 步】测试订阅端点"
echo "=================================="
RESPONSE=$(curl -s -w "\n%{http_code}" http://localhost:3000/sub)
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ 订阅端点可访问 (HTTP $HTTP_CODE)"
    if [ -n "$BODY" ]; then
        echo "✅ 订阅链接已生成"
        echo "   长度: ${#BODY} 字符"
        echo "   前 50 字符: ${BODY:0:50}..."
    else
        echo "❌ 订阅链接为空"
    fi
else
    echo "❌ 订阅端点访问失败 (HTTP $HTTP_CODE)"
    echo "   可能原因: 服务未启动或路由错误"
fi
echo ""

# 5. 检查 Xray 运行状态
echo "【第 5 步】检查 Xray 服务状态"
echo "=================================="
if pgrep -f "xray" > /dev/null; then
    echo "✅ Xray 服务运行中"
else
    echo "⚠️  Xray 服务未运行"
    echo "   提示: Xray 是后端代理，不影响订阅获取"
    echo "   但会影响连接使用"
fi
echo ""

# 6. 检查 Argo 隧道连接
echo "【第 6 步】检查 Argo 隧道状态"
echo "=================================="
if pgrep -f "cloudflare" > /dev/null; then
    echo "✅ Cloudflare 隧道运行中"
else
    echo "❌ Cloudflare 隧道未运行"
    echo "   问题: 隧道连接失败"
    echo "   检查: ARGO_AUTH 是否正确"
fi
echo ""

# 7. 检查工作目录
echo "【第 7 步】检查工作目录文件"
echo "=================================="
WORKDIR="/home/container/argo"
if [ -d "$WORKDIR" ]; then
    echo "✅ 工作目录存在: $WORKDIR"
    echo "   文件列表:"
    ls -lh "$WORKDIR/" | awk 'NR>1 {printf "     %s %s\n", $9, $5}'
else
    echo "❌ 工作目录不存在"
fi
echo ""

# 8. 查看最新日志
echo "【第 8 步】查看服务日志（最后 20 行）"
echo "=================================="
if [ -f "$WORKDIR/service.log" ]; then
    echo "✅ 日志文件存在"
    echo "   内容:"
    tail -20 "$WORKDIR/service.log" | sed 's/^/     /'
else
    echo "❌ 日志文件不存在"
fi
echo ""

# 9. 检查隧道配置
echo "【第 9 步】检查隧道配置"
echo "=================================="
if [ -f "$WORKDIR/tmp/tunnel.json" ]; then
    echo "✅ 隧道配置文件存在"
    TOKEN=$(cat "$WORKDIR/tmp/tunnel.json" | head -c 30)
    echo "   Token 前 30 字: $TOKEN..."
else
    echo "⚠️  隧道配置文件不存在"
    echo "   可能原因: 使用临时隧道或隧道未初始化"
fi
echo ""

# 10. 检查 Xray 配置
echo "【第 10 步】检查 Xray 配置"
echo "=================================="
if [ -f "$WORKDIR/tmp/config.json" ]; then
    echo "✅ Xray 配置文件存在"
    PORT=$(grep -o '"port":[0-9]*' "$WORKDIR/tmp/config.json" | head -1)
    echo "   主监听端口: $PORT"
else
    echo "❌ Xray 配置文件不存在"
fi
echo ""

# 11. 网络诊断
echo "【第 11 步】网络诊断"
echo "=================================="
echo "容器内 IP 地址:"
hostname -I || echo "   无法获取"

echo ""
echo "DNS 解析测试:"
if nslookup x.gom.qzz.io 8.8.8.8 &>/dev/null; then
    echo "✅ DNS 解析正常"
else
    echo "⚠️  DNS 解析可能有问题"
fi
echo ""

# 12. 总结诊断结果
echo "=========================================="
echo "📊 诊断总结"
echo "=========================================="
echo ""
echo "✅ 正常工作的指标:"
echo "   - HTTP 服务运行"
echo "   - 端口 3000 可访问"
echo "   - 订阅链接可获取"
echo ""
echo "❌ 问题排查:"
echo ""
echo "场景 A: 订阅链接可以获取，但在容器外打不开"
echo "   原因: 容器端口未暴露"
echo "   解决: 在 Pterodactyl 面板中配置端口转发"
echo "        将容器 3000 端口映射到外部"
echo ""
echo "场景 B: 本地能打开，容器外打不开"
echo "   原因: 网络或防火墙问题"
echo "   解决: 检查 Pterodactyl 分配的外部 IP 和端口"
echo ""
echo "场景 C: 订阅链接为空或无法获取"
echo "   原因: Xray 或 Argo 启动失败"
echo "   解决: 检查 service.log，查看错误信息"
echo ""
echo "=========================================="
