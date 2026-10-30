#!/bin/zsh
# 部署 Daily Relay 到 Cloudflare，生成新的随机密钥，并把连接信息写进 Mac 上的 Daily（钥匙串）。
# 全程不显示密钥。重新运行会更换密钥，之后需要在 Grok 里更新连接器地址。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "① 部署 Daily Relay 到 Cloudflare…"
out=$(npx wrangler deploy 2>&1) || { print -r -- "$out"; exit 1; }
url=$(print -r -- "$out" | grep -oE 'https://[A-Za-z0-9.-]+\.workers\.dev' | head -1)
if [[ -z "$url" ]]; then
  print -r -- "$out"
  echo "没有找到部署地址，请把上面的输出发给 Claude。"
  exit 1
fi
echo "   已部署：$url"

echo "② 生成随机密钥并保存到 Cloudflare…"
secret=$(openssl rand -hex 24)
printf '%s' "$secret" | npx wrangler secret put RELAY_SECRET >/dev/null

echo "③ 检查服务…"
ok=0
for i in {1..10}; do
  resp=$(curl -s -X POST "$url/$secret/mcp" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' || true)
  if [[ "$resp" == *add_event* && "$resp" == *list_events* ]]; then ok=1; break; fi
  sleep 3
done
if [[ $ok -ne 1 ]]; then
  echo "服务没有正常响应，请把这段输出发给 Claude。"
  exit 1
fi
echo "   MCP 工具已就绪"

echo "④ 把连接信息写入 Daily…"
open "daily://relay?url=$url/$secret"

echo
echo "✅ 完成。下一步：在 Daily 侧边栏「Agent / Bot 写入」下点「复制 Grok 连接器地址」，"
echo "   打开 grok.com/connectors → 新建 → 自定义，粘贴地址。"
