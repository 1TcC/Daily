# Daily Relay

运行在 Cloudflare Workers 上的小型中转服务，让手机上的 Grok（或其他支持 MCP 的 AI 助手）读写 Daily 的日程：

```
Grok ──MCP──▶ Daily Relay（Cloudflare Worker + Durable Object）◀──同步── Mac 上的 Daily
```

- Grok 通过 MCP 工具查看日程、增删改它自己创建的日程。
- Mac 上的 Daily 定时拉取 Grok 写入的日程，并把自己的日程快照（课程、系统日历等）上传，供 Grok 查询。
- Mac 关机时 Grok 照样能读写；Daily 下次运行时补同步。

## 鉴权

所有路径都以一串随机密钥开头：`https://<worker>/<SECRET>/...`。密钥存在 Worker 的 secret `RELAY_SECRET` 里，不进仓库。路径里的密钥不对一律返回 404。

## 时间格式

- 时区固定为 `Asia/Shanghai`（`+08:00`，无夏令时），由 `wrangler.toml` 的 `UTC_OFFSET` 配置。
- 输入接受：`2026-11-03 19:35`、`2026-11-03T19:35`、`2026-11-03T19:35:00+08:00`、`...Z`；全天日程用 `2026-11-03`。不带时区的时间按 `+08:00` 理解。
- 输出一律为 `2026-11-03T19:35:00+08:00`；全天日程的 `start`/`end` 为 `YYYY-MM-DD`，`end` 为不含的结束日（单日全天：`end` = 次日）。

## 数据模型

Grok 写入的日程（agent event）：

```json
{
  "id": "uuid",
  "title": "Codeforces Round 1000",
  "start": "2026-11-03T22:35:00+08:00",
  "end": "2026-11-04T00:35:00+08:00",   // 可省略
  "all_day": false,
  "location": "线上",                   // 可省略
  "notes": "Div.2",                      // 可省略
  "created_at": "2026-10-30T15:00:00Z",
  "updated_at": "2026-10-30T15:00:00Z",
  "deleted": false                       // 删除时保留 30 天墓碑，供 Daily 同步删除
}
```

Daily 上传的快照条目（只读）：

```json
{ "title": "数据结构", "start": "...+08:00", "end": "...+08:00", "all_day": false,
  "location": "45楼B302", "notes": "李四", "source": "教务课程" }
```

## MCP 端点

`POST /<SECRET>/mcp` — MCP Streamable HTTP，JSON-RPC 2.0，响应 `application/json`（不用 SSE）。
支持 `initialize`、`notifications/*`（返回 202 空响应）、`ping`、`tools/list`、`tools/call`，以及批量请求数组。
`GET`/`DELETE /<SECRET>/mcp` 返回 405。

工具：

| 工具 | 参数 | 说明 |
|---|---|---|
| `list_events` | `start_date`, `end_date`（`YYYY-MM-DD`，含首尾） | 返回该范围内全部日程：Daily 快照 + Grok 写入的（未删除）。每条带 `editable`（仅 Grok 写入的为 true）和 `source`。结果附带 `now`（当前北京时间）和 `snapshot_updated_at`。 |
| `add_event` | `title`, `start`，可选 `end`, `all_day`, `location`, `notes` | 新建；若已有同标题、同开始时间的未删除条目则改为更新。返回该条目。 |
| `update_event` | `id`，以及要修改的字段 | 只能改 Grok 写入的条目。 |
| `delete_event` | `id` | 只能删 Grok 写入的条目（标记 `deleted`）。 |

工具结果放在 `content[0].text`（JSON 字符串），出错时 `isError: true` 并给出中文说明。

## Daily 同步端点

- `GET /<SECRET>/sync/agent-events` → `{ "events": [agent event...（含 deleted）], "now": "..." }`
- `PUT /<SECRET>/sync/snapshot`，body `{ "events": [快照条目...], "generated_at": "ISO" }` → `{ "ok": true, "count": n }`

## 部署

```bash
cd relay
npm install
npx wrangler login
npx wrangler secret put RELAY_SECRET
npx wrangler deploy
```
