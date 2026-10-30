#!/bin/zsh
# 更新已部署的 Daily Relay 代码，不更换密钥（Grok 连接器地址不变）。
set -euo pipefail
cd "$(dirname "$0")/.."
npx wrangler deploy
echo
echo "✅ 已更新。Daily 会在 1 分钟内自动重连。"
