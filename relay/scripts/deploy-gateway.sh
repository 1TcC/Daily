#!/bin/zsh
# 部署 Daily 网关（Pages），并绑定自定义域名。之后在阿里云加 CNAME：<子域名> → daily-gateway.pages.dev
# 用法：deploy-gateway.sh [域名，默认 daily.0netc.com]
set -euo pipefail
DOMAIN="${1:-daily.0netc.com}"
cd "$(dirname "$0")/../gateway"

echo "① 创建 Pages 项目（已存在会跳过）…"
npx wrangler pages project create daily-gateway --production-branch main >/dev/null 2>&1 || true

echo "② 部署网关…"
npx wrangler pages deploy public --project-name daily-gateway --branch main --commit-dirty=true | tail -3

echo "③ 绑定自定义域名 $DOMAIN …"
TOKEN=$(grep -E '^oauth_token' ~/Library/Preferences/.wrangler/config/default.toml | sed -E 's/.*"(.*)".*/\1/')
ACC=$(curl -s -H "Authorization: Bearer $TOKEN" https://api.cloudflare.com/client/v4/accounts | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"][0]["id"])')
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/$ACC/pages/projects/daily-gateway/domains" \
  -d "{\"name\":\"$DOMAIN\"}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("   已绑定" if d.get("success") else "   " + str(d.get("errors")))'

echo
echo "✅ 下一步：在阿里云「云解析 DNS」给 0netc.com 添加一条记录："
echo "   记录类型 CNAME，主机记录 ${DOMAIN%%.0netc.com}，记录值 daily-gateway.pages.dev"
