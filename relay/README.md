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

`POST /<SECRET>/mcp`（Grok）或 `POST /<SECRET>/mcp/<名字>`（其他 AI，如 `/mcp/muse`）— 路径决定调用方身份：
每个 AI 只能修改/删除自己创建的日程，能看到其他 AI 创建的（只读，`source` 为对方名字）；agent event 带 `client` 字段。

MCP Streamable HTTP，JSON-RPC 2.0，响应 `application/json`（不用 SSE）。
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

- `GET /<SECRET>/sync/live` — WebSocket（休眠 API）；有 AI 改了日程就推送 `{"type":"agent-changed"}`，客户端发 `ping` 由运行时自动回 `pong`
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

## 短信接收与日历订阅

两个派生令牌，由 `RELAY_SECRET` 计算，不需要额外配置：

- 写入令牌 `INGEST = sha256("<RELAY_SECRET>:ingest")` 的前 32 个十六进制字符
- 订阅令牌 `FEED = sha256("<RELAY_SECRET>:feed")` 的前 32 个十六进制字符

它们各自只能做一件事，泄露了也拿不到主密钥的读写权限。

### `POST /ingest/<INGEST>/sms`

iPhone 快捷指令在收到命中关键词的短信时调用。body：`{"text": "短信全文", "received_at": "可选 ISO 时间"}`（也接受 `text/plain` 的纯文本 body）。

- 解析后**丢弃原文**，只保存结构化条目；解析不了的短信直接忽略。
- 响应 `{"ok": true, "parsed": "pickup" | "picked_up" | "train" | "train_cancel" | "flight" | null}`；空文本返回 `parsed: null`。
- 生成的条目存为 agent event：`client: "sms"`，并带 `kind` 与 `meta` 字段（见下）。同一条短信重复投递不会重复生成。

条目类型：

| kind | 来源短信 | 条目 |
|---|---|---|
| `parcel` | 驿站 / 快递柜 / 自提点到件通知 | 全天日程，从收到当天起 3 天（`end` 不含）；标题 `取件 <取件码> · <驿站或快递柜>`；`meta`: `pickup_code`, `station`, `carrier` |
| — | 「已取件 / 已签收 / 已取出」 | 按取件码（或驿站）找到对应条目，标记删除 |
| `travel` | 12306 购票 / 改签 | 定时日程，开车时间开始，无结束时间；标题 `<车次> <出发站>`，`location` 为出发站；`meta`: `train`, `seat`, `gate`, `order`。改签：同订单号旧条目删除后新建。退票：按订单号或车次删除 |
| `travel` | 航班通知 | 标题 `<航班号> <出发>→<到达>`；`meta`: `flight` |

年份推断：短信里只有「月日」时，取离当前时间最近、且不早于 30 天前的那一年。

过期：`client: "sms"` 的条目，结束时间（无结束时间则开始时间 + 1 天）早于 7 天前时标记删除；墓碑按原规则 30 天后清理。

MCP 的 `list_events` 照常返回这些条目（`source`：`短信`，带 `kind`、`meta`），`editable` 恒为 false；任何 AI 调用 `update_event` / `delete_event` 都会收到中文错误。`/mcp/sms` 不可用作 AI 身份。`GET /<SECRET>/sync/agent-events` 同样带 `kind`、`meta`。

幂等：条目 id 由内容确定（快递：取件码 + 驿站 + 收到日期；车票：订单号 + 车次 + 日期；航班：航班号 + 日期），重复投递只会更新；已被取走/退票的条目不会因重复投递复活。同码同站且尚未取走的包裹，隔天再收到通知也只更新原条目。

### `GET /feed/<FEED>/daily.ics`

iCalendar 订阅源（`text/calendar`），供 iPhone「日历 → 添加订阅日历」使用：

- 包含：快照里的非「系统日历」条目（课程等）+ 所有未删除的 agent event（Grok / Muse / 短信）。系统日历本来就在手机上，不重复放。
- 范围：过去 7 天到未来 60 天。时间用 UTC（`...Z`），全天用 `VALUE=DATE`。每条有稳定 `UID`，`X-WR-CALNAME:Daily`，`REFRESH-INTERVAL`/`X-PUBLISHED-TTL` 为 15 分钟。
