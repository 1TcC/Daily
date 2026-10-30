// Daily Relay：让手机上的 AI 助手（Grok，经 MCP）读写日程，并与 Mac 上的 Daily 同步。
// Worker 只负责校验路径里的密钥并转发；所有状态与业务逻辑都在单个 Durable Object 里，保证强一致。

import { Clock, DAY_MS, UserError } from "./clock.ts";
import { parseSms, type SmsEvent, type SmsResult } from "./sms.ts";
import { buildIcs } from "./ics.ts";

// ---------- 最小类型声明（避免依赖 @cloudflare/workers-types） ----------

interface DurableObjectStorageLike {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
}
interface WebSocketLike {
  send(message: string): void;
  close(code?: number, reason?: string): void;
}
interface DurableObjectStateLike {
  storage: DurableObjectStorageLike;
  // WebSocket 休眠 API：空闲连接不计运行时长
  acceptWebSocket(ws: WebSocketLike): void;
  getWebSockets(): WebSocketLike[];
  setWebSocketAutoResponse(pair: unknown): void;
}
declare const WebSocketPair: { new (): Record<string, WebSocketLike> };
declare const WebSocketRequestResponsePair: { new (request: string, response: string): unknown };
interface DurableObjectStubLike {
  fetch(request: Request): Promise<Response>;
}
interface DurableObjectNamespaceLike {
  idFromName(name: string): unknown;
  get(id: unknown): DurableObjectStubLike;
}
interface Env {
  STORE: DurableObjectNamespaceLike;
  RELAY_SECRET?: string;
  UTC_OFFSET?: string;
}

// ---------- 数据类型 ----------

interface AgentEvent {
  id: string;
  title: string;
  start: string;
  end?: string;
  all_day: boolean;
  location?: string;
  notes?: string;
  created_at: string;
  updated_at: string;
  deleted: boolean;
  /** 创建它的 AI（连接器路径 /mcp/<client>）；旧数据没有该字段，视为 grok。 */
  client?: string;
  /** 短信生成的条目类别：parcel 快递 / travel 出行。 */
  kind?: "parcel" | "travel";
  /** 结构化附加信息（取件码、车次、座位等），只有短信条目有。 */
  meta?: Record<string, string>;
}
interface SnapshotEvent {
  title: string;
  start: string;
  end?: string;
  all_day: boolean;
  location?: string;
  notes?: string;
  source?: string;
}
interface Snapshot {
  events: SnapshotEvent[];
  generated_at: string | null;
}
type Json = unknown;
type Args = Record<string, unknown>;

const MAX_SNAPSHOT_EVENTS = 5000;
const MAX_SNAPSHOT_BYTES = 1_900_000; // DO 单个 value 上限约 2MB
const MAX_RANGE_DAYS = 120;
const TOMBSTONE_MS = 30 * DAY_MS;
const SMS_EXPIRE_MS = 7 * DAY_MS; // 短信条目结束 7 天后自动标记删除
const MAX_SMS_BYTES = 20_000;

/** 旧连接器地址 /mcp 对应的调用方。 */
const DEFAULT_CLIENT = "grok";
/** 短信自动生成的条目的 client；任何 AI 都不能改，也不允许作为 /mcp/<名字> 使用。 */
const SMS_CLIENT = "sms";
const CLIENT_NAMES: Record<string, string> = { grok: "Grok", muse: "Muse", [SMS_CLIENT]: "短信" };
const clientOf = (ev: AgentEvent) => ev.client ?? DEFAULT_CLIENT;
const clientName = (client: string) => CLIENT_NAMES[client] ?? client.charAt(0).toUpperCase() + client.slice(1);

// ---------- Worker 入口 ----------

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "*",
  "Access-Control-Expose-Headers": "*",
};

/** 常量时间比较，长度不同也走完整循环。 */
function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

const notFound = () => new Response(null, { status: 404 });

/** 由主密钥派生的子令牌：sha256("<secret>:<purpose>") 的前 32 个十六进制字符。 */
async function deriveToken(secret: string, purpose: "ingest" | "feed"): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${secret}:${purpose}`));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

const methodNotAllowed = (allow: string) => new Response(null, { status: 405, headers: { Allow: allow } });

/** 派生令牌路由：只能写入短信 / 读取订阅源，碰不到其它任何接口。未命中返回 null。 */
async function routeDerived(request: Request, url: URL, secret: string, env: Env): Promise<Response | null> {
  const m = url.pathname.match(/^\/(ingest|feed)\/([^/]+)\/(sms|daily\.ics)\/?$/);
  if (!m) return null;
  const [, kind, given, leaf] = m;
  if ((kind === "ingest") !== (leaf === "sms")) return notFound();
  let token = given;
  try {
    token = decodeURIComponent(given);
  } catch {
    return notFound();
  }
  if (!safeEqual(token, await deriveToken(secret, kind as "ingest" | "feed"))) return notFound();
  const stub = env.STORE.get(env.STORE.idFromName("default"));

  if (kind === "feed") {
    if (request.method !== "GET" && request.method !== "HEAD") return methodNotAllowed("GET, HEAD");
    return stub.fetch(new Request("https://store/feed.ics", { method: request.method }));
  }
  if (request.method !== "POST") return methodNotAllowed("POST");
  const raw = await request.text();
  if (raw.length > MAX_SMS_BYTES) return json({ ok: false, error: "内容太长" }, 413);
  let text = raw;
  let receivedAt: unknown;
  if ((request.headers.get("Content-Type") ?? "").toLowerCase().includes("json")) {
    let body: unknown;
    try {
      body = JSON.parse(raw);
    } catch {
      return json({ ok: false, error: "请求体不是合法 JSON" }, 400);
    }
    const b = body as { text?: unknown; received_at?: unknown } | null;
    if (!b || typeof b !== "object" || typeof b.text !== "string") {
      return json({ ok: false, error: "body 必须是 {text, received_at?}" }, 400);
    }
    text = b.text;
    receivedAt = b.received_at;
  }
  return stub.fetch(
    new Request("https://store/ingest-sms", {
      method: "POST",
      body: JSON.stringify({ text, received_at: typeof receivedAt === "string" ? receivedAt : undefined }),
    }),
  );
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const secret = env.RELAY_SECRET;
    if (!secret) return notFound();

    // 派生令牌路由要先于 /<SECRET>/... 匹配
    const derived = await routeDerived(request, url, secret, env);
    if (derived) return derived;

    // 路径形如 /<SECRET>/<rest>
    const m = url.pathname.match(/^\/([^/]+)(\/.*)?$/);
    if (!m) return notFound();
    let seg = m[1];
    try {
      seg = decodeURIComponent(seg);
    } catch {
      return notFound();
    }
    if (!safeEqual(seg, secret) || !m[2]) return notFound();
    const rest = m[2].replace(/\/+$/, "") || "/";

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }

    const stub = env.STORE.get(env.STORE.idFromName("default"));
    const inner = new Request("https://store" + rest + url.search, request);
    const resp = await stub.fetch(inner);
    // WebSocket 握手响应要原样返回，复制会丢掉 webSocket 字段
    if (resp.status === 101) return resp;
    const out = new Response(resp.body, resp);
    for (const [k, v] of Object.entries(CORS)) out.headers.set(k, v);
    return out;
  },
};


const utcStamp = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

// ---------- 输入校验辅助 ----------

function str(args: Args, key: string, opts: { required?: boolean; max: number }): string | undefined {
  const v = args[key];
  if (v === undefined || v === null) {
    if (opts.required) throw new UserError(`缺少参数 ${key}。`);
    return undefined;
  }
  if (typeof v !== "string") throw new UserError(`参数 ${key} 必须是字符串。`);
  const t = v.trim();
  if (opts.required && !t) throw new UserError(`参数 ${key} 不能为空。`);
  if (t.length > opts.max) throw new UserError(`参数 ${key} 太长（最多 ${opts.max} 字符）。`);
  return t;
}

function bool(args: Args, key: string): boolean | undefined {
  const v = args[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v === "boolean") return v;
  if (v === "true") return true;
  if (v === "false") return false;
  throw new UserError(`参数 ${key} 必须是布尔值。`);
}

// ---------- 工具定义 ----------

const TIME_HELP =
  "时间一律为北京时间（Asia/Shanghai, +08:00）。接受格式：2026-11-03 19:35、2026-11-03T19:35、2026-11-03T19:35:00+08:00、带 Z 的 UTC 时间；全天日程用 2026-11-03。" +
  " Times are Asia/Shanghai (+08:00); naive times are interpreted in that zone.";

const TOOLS = [
  {
    name: "list_events",
    description:
      "查看日程：返回日期范围内（含首尾）的所有日程，包括用户 Daily 里的课程/系统日历（只读）和你创建的日程。安排新日程前先调用它检查时间冲突。每条有 editable 和 source；结果含 now（当前北京时间）。范围最多 120 天。" +
      " List calendar events in an inclusive local-date range (Asia/Shanghai). Call before scheduling to avoid conflicts. Max range 120 days.",
    inputSchema: {
      type: "object",
      properties: {
        start_date: { type: "string", description: "起始日期 YYYY-MM-DD（含）/ start date, inclusive" },
        end_date: { type: "string", description: "结束日期 YYYY-MM-DD（含），省略则只查 start_date 当天 / end date, inclusive; defaults to start_date" },
      },
      required: ["start_date"],
    },
  },
  {
    name: "add_event",
    description:
      "新建日程。若已存在同标题、同开始时间的日程则更新它而不是重复创建。" +
      TIME_HELP +
      " 全天日程：start 用 YYYY-MM-DD（或设 all_day=true），end 为不含的结束日，省略则为次日。非全天日程 end 必须晚于 start，可省略。" +
      " Create an event (dedupes on same title + start).",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "标题 / title" },
        start: { type: "string", description: "开始时间 / start, e.g. 2026-11-03 19:35 or 2026-11-03 (all-day)" },
        end: { type: "string", description: "结束时间（可选；全天日程为不含的结束日）/ end (optional; exclusive date for all-day)" },
        all_day: { type: "boolean", description: "是否全天；start 只有日期时自动为 true / all-day flag" },
        location: { type: "string", description: "地点（可选）/ location" },
        notes: { type: "string", description: "备注（可选）/ notes" },
      },
      required: ["title", "start"],
    },
  },
  {
    name: "update_event",
    description:
      "修改日程，只能修改你自己创建的（editable 为 true）。只需传要改的字段；end、location、notes 传空字符串表示清除。" +
      TIME_HELP +
      " Update an event created by you; only pass fields to change.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "日程 id（来自 list_events / add_event）/ event id" },
        title: { type: "string" },
        start: { type: "string" },
        end: { type: "string", description: "空字符串表示清除 / empty string clears" },
        all_day: { type: "boolean" },
        location: { type: "string", description: "空字符串表示清除 / empty string clears" },
        notes: { type: "string", description: "空字符串表示清除 / empty string clears" },
      },
      required: ["id"],
    },
  },
  {
    name: "delete_event",
    description: "删除日程，只能删除你自己创建的（editable 为 true）。 Delete an event created by you.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", description: "日程 id / event id" } },
      required: ["id"],
    },
  },
];

const INSTRUCTIONS =
  "这是用户的个人日历。所有时间均为北京时间（Asia/Shanghai, +08:00）。" +
  "安排日程之前，先用 list_events 查看相关日期，避免与已有日程（课程、系统日历等）冲突。" +
  "只有你（Grok）创建的日程可以修改或删除（editable=true），其余为只读。";

const SUPPORTED_PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"];

// ---------- Durable Object ----------

const json = (data: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json", ...headers } });

export class DailyStore {
  private clock: Clock;
  constructor(private state: DurableObjectStateLike, env: Env) {
    this.clock = new Clock(env.UTC_OFFSET);
    // Daily 的心跳 "ping" 由运行时直接回 "pong"，不唤醒 DO
    this.state.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    const method = request.method;
    // /mcp 是 Grok 的旧地址；其他 AI 用 /mcp/<名字>（小写字母、数字、连字符），据此区分来源和编辑权限
    const mcp = path.match(/^\/mcp(?:\/([a-z0-9-]{1,20}))?$/);
    if (mcp && mcp[1] !== SMS_CLIENT) {
      if (method === "POST") return this.handleMcp(request, mcp[1] ?? DEFAULT_CLIENT);
      return new Response(null, { status: 405, headers: { Allow: "POST, OPTIONS" } });
    }
    if (path === "/ingest-sms") {
      if (method !== "POST") return methodNotAllowed("POST");
      return this.ingestSms(request);
    }
    if (path === "/feed.ics") {
      if (method !== "GET" && method !== "HEAD") return methodNotAllowed("GET, HEAD");
      return this.feed();
    }
    if (path === "/sync/agent-events") {
      if (method !== "GET") return new Response(null, { status: 405, headers: { Allow: "GET" } });
      const agent = await this.loadAgent();
      return json({ events: Object.values(agent), now: this.clock.format(Date.now()) });
    }
    if (path === "/sync/live") {
      // Daily 保持的长连接：Grok 改了日程就推一条通知，Daily 收到后立即拉取
      if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return new Response("expected websocket", { status: 426 });
      }
      const [client, server] = Object.values(new WebSocketPair());
      this.state.acceptWebSocket(server);
      return new Response(null, { status: 101, webSocket: client } as ResponseInit);
    }
    if (path === "/sync/snapshot") {
      if (method !== "PUT") return new Response(null, { status: 405, headers: { Allow: "PUT" } });
      return this.putSnapshot(request);
    }
    return notFound();
  }

  // ----- 存储 -----

  private async loadAgent(): Promise<Record<string, AgentEvent>> {
    return (await this.state.storage.get<Record<string, AgentEvent>>("agent")) ?? {};
  }
  private async saveAgent(agent: Record<string, AgentEvent>): Promise<void> {
    const now = Date.now();
    // 短信条目：结束（无结束则开始 + 1 天）超过 7 天就标记删除，由 Daily 同步删除
    for (const ev of Object.values(agent)) {
      if (ev.deleted || clientOf(ev) !== SMS_CLIENT) continue;
      const sp = this.clock.span(ev);
      const endMs = sp ? (ev.end || ev.all_day ? sp[1] : sp[0] + DAY_MS) : 0;
      if (endMs < now - SMS_EXPIRE_MS) {
        ev.deleted = true;
        ev.updated_at = utcStamp();
      }
    }
    // 写入时顺便清理超过 30 天的墓碑
    const cutoff = now - TOMBSTONE_MS;
    for (const [id, ev] of Object.entries(agent)) {
      if (ev.deleted && Date.parse(ev.updated_at) < cutoff) delete agent[id];
    }
    await this.state.storage.put("agent", agent);
    this.notifyChanged();
  }

  private notifyChanged(): void {
    const message = JSON.stringify({ type: "agent-changed", at: new Date().toISOString() });
    for (const ws of this.state.getWebSockets()) {
      try {
        ws.send(message);
      } catch {
        // 已断开的连接由运行时清理
      }
    }
  }

  // 休眠 API 的回调：客户端只发心跳（已自动应答），其余消息忽略
  async webSocketMessage(_ws: WebSocketLike, _message: unknown): Promise<void> {}
  async webSocketClose(ws: WebSocketLike, code: number): Promise<void> {
    try {
      ws.close(code === 1005 ? 1000 : code);
    } catch {
      // 忽略
    }
  }
  private async loadSnapshot(): Promise<Snapshot> {
    return (await this.state.storage.get<Snapshot>("snapshot")) ?? { events: [], generated_at: null };
  }

  // ----- 短信接收 -----

  private async ingestSms(request: Request): Promise<Response> {
    let body: { text?: unknown; received_at?: unknown };
    try {
      body = await request.json();
    } catch {
      return json({ ok: false, error: "请求体不是合法 JSON" }, 400);
    }
    const text = typeof body.text === "string" ? body.text : "";
    const now = Date.now();
    // received_at 只在合理范围内采信（用于推断年份、包裹收到日）
    let ref = now;
    if (typeof body.received_at === "string") {
      const t = Date.parse(body.received_at);
      if (!Number.isNaN(t) && t <= now + 3600_000 && t >= now - 30 * DAY_MS) ref = t;
    }
    const result = parseSms(text, ref, this.clock);
    if (!result) return json({ ok: true, parsed: null });

    const agent = await this.loadAgent();
    if (this.applySms(agent, result)) await this.saveAgent(agent);
    return json({ ok: true, parsed: result.type });
  }

  /** 把解析结果应用到 agent 存储；有变化返回 true。 */
  private applySms(agent: Record<string, AgentEvent>, r: NonNullable<SmsResult>): boolean {
    const live = () => Object.values(agent).filter((e) => !e.deleted && clientOf(e) === SMS_CLIENT);
    const remove = (list: AgentEvent[]) => {
      const stamp = utcStamp();
      for (const e of list) {
        e.deleted = true;
        e.updated_at = stamp;
      }
      return list.length > 0;
    };
    switch (r.type) {
      case "pickup":
        // 同码同站的未取件条目视为同一包裹（隔天重复通知），否则按确定性 id 新建
        return this.upsertSms(agent, r.event, live().find((e) => e.kind === "parcel" && e.meta?.pickup_code === r.event.meta.pickup_code && e.meta.station === r.event.meta.station)?.id);
      case "picked_up": {
        const parcels = live().filter((e) => e.kind === "parcel");
        let hit = r.code ? parcels.filter((e) => e.meta?.pickup_code === r.code) : [];
        if (r.code && r.station && hit.length > 1) {
          const same = hit.filter((e) => e.meta?.station === r.station);
          if (same.length) hit = same;
        }
        if (!r.code && r.station) {
          hit = parcels.filter((e) => e.meta?.station && (e.meta.station.includes(r.station!) || r.station!.includes(e.meta.station)));
        }
        return remove(hit);
      }
      case "train": {
        let changed = false;
        // 改签：同订单号的旧车次作废
        if (r.rebook && r.order) {
          changed = remove(live().filter((e) => e.kind === "travel" && e.meta?.train && e.meta.order === r.order && e.id !== r.event.id));
        }
        return this.upsertSms(agent, r.event) || changed;
      }
      case "train_cancel": {
        const trains = live().filter((e) => e.kind === "travel" && e.meta?.train);
        const byOrder = r.order ? trains.filter((e) => e.meta!.order === r.order) : [];
        // 订单里有多张票时优先按车次缩小；没有订单号或找不到订单时，按车次 + 月日兜底
        const sameTrain = byOrder.filter((e) => e.meta!.train === r.train);
        const hit = byOrder.length
          ? sameTrain.length ? sameTrain : byOrder
          : trains.filter((e) => e.meta!.train === r.train && this.clock.ymd(this.clock.span(e)?.[0] ?? 0).slice(5) === r.date.slice(5));
        return remove(hit);
      }
      case "flight":
        return this.upsertSms(agent, r.event);
    }
  }

  /** 按 id 新建或更新短信条目；已被删除的同 id 条目不复活（重复投递不应让取走的包裹回来）。 */
  private upsertSms(agent: Record<string, AgentEvent>, pe: SmsEvent, existingId?: string): boolean {
    const id = existingId ?? pe.id;
    const old = agent[id];
    if (old?.deleted) return false;
    const next: AgentEvent = {
      id,
      title: pe.title,
      start: pe.start,
      ...(pe.end ? { end: pe.end } : {}),
      all_day: pe.all_day,
      ...(pe.location ? { location: pe.location } : {}),
      ...(pe.notes ? { notes: pe.notes } : {}),
      created_at: old?.created_at ?? utcStamp(),
      updated_at: utcStamp(),
      deleted: false,
      client: SMS_CLIENT,
      kind: pe.kind,
      meta: pe.meta,
    };
    const same = (a: AgentEvent, b: AgentEvent) => JSON.stringify({ ...a, updated_at: "", created_at: "" }) === JSON.stringify({ ...b, updated_at: "", created_at: "" });
    if (old && same(old, next)) return false;
    agent[id] = next;
    return true;
  }

  // ----- 日历订阅 -----

  private async feed(): Promise<Response> {
    const ics = buildIcs(await this.loadSnapshot(), Object.values(await this.loadAgent()), Date.now(), this.clock);
    return new Response(ics, {
      headers: { "Content-Type": "text/calendar; charset=utf-8", "Cache-Control": "no-cache" },
    });
  }

  // ----- 同步：快照上传 -----

  private async putSnapshot(request: Request): Promise<Response> {
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json({ ok: false, error: "请求体不是合法 JSON" }, 400);
    }
    const b = body as { events?: unknown; generated_at?: unknown } | null;
    if (!b || typeof b !== "object" || !Array.isArray(b.events)) {
      return json({ ok: false, error: "body 必须是 {events: [...], generated_at}" }, 400);
    }
    if (b.events.length > MAX_SNAPSHOT_EVENTS) {
      return json({ ok: false, error: `最多 ${MAX_SNAPSHOT_EVENTS} 条` }, 413);
    }
    const events: SnapshotEvent[] = [];
    let skipped = 0;
    for (const raw of b.events) {
      const ev = this.normalizeSnapshotEvent(raw);
      if (ev) events.push(ev);
      else skipped++;
    }
    const generatedAt =
      typeof b.generated_at === "string" && !Number.isNaN(Date.parse(b.generated_at)) ? b.generated_at : utcStamp();
    const snapshot: Snapshot = { events, generated_at: generatedAt };
    if (JSON.stringify(snapshot).length > MAX_SNAPSHOT_BYTES) {
      return json({ ok: false, error: "快照太大" }, 413);
    }
    await this.state.storage.put("snapshot", snapshot);
    return json({ ok: true, count: events.length, ...(skipped ? { skipped } : {}) });
  }

  /** 宽松归一化快照条目：时间无效的丢弃，end 不合理则去掉 end。 */
  private normalizeSnapshotEvent(raw: unknown): SnapshotEvent | null {
    if (!raw || typeof raw !== "object") return null;
    const r = raw as Record<string, unknown>;
    if (typeof r.title !== "string" || typeof r.start !== "string" || !r.title.trim()) return null;
    const allDay = typeof r.all_day === "boolean" ? r.all_day : undefined;
    const endIn = typeof r.end === "string" ? r.end : undefined;
    let t: { start: string; end?: string; all_day: boolean };
    try {
      t = this.clock.normalize(r.start, endIn, allDay);
    } catch {
      try {
        t = this.clock.normalize(r.start, undefined, allDay);
      } catch {
        return null;
      }
    }
    const ev: SnapshotEvent = { title: r.title.trim().slice(0, 200), ...t };
    if (typeof r.location === "string" && r.location.trim()) ev.location = r.location.trim().slice(0, 200);
    if (typeof r.notes === "string" && r.notes.trim()) ev.notes = r.notes.trim().slice(0, 500);
    if (typeof r.source === "string" && r.source.trim()) ev.source = r.source.trim().slice(0, 50);
    return ev;
  }

  // ----- MCP -----

  private async handleMcp(request: Request, caller: string): Promise<Response> {
    let body: unknown;
    try {
      body = JSON.parse(await request.text());
    } catch {
      return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
    }
    if (Array.isArray(body)) {
      if (body.length === 0) {
        return json({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid Request" } });
      }
      const out: Json[] = [];
      for (const item of body) {
        const r = await this.handleRpc(item, caller);
        if (r) out.push(r);
      }
      return out.length ? json(out) : new Response(null, { status: 202 });
    }
    const r = await this.handleRpc(body, caller);
    return r ? json(r) : new Response(null, { status: 202 });
  }

  /** 处理单个 JSON-RPC 消息；通知 / 客户端响应返回 null。 */
  private async handleRpc(msg: unknown, caller: string): Promise<Json | null> {
    const err = (id: unknown, code: number, message: string) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });
    if (!msg || typeof msg !== "object" || Array.isArray(msg)) return err(null, -32600, "Invalid Request");
    const m = msg as { id?: unknown; method?: unknown; params?: unknown };
    if (typeof m.method !== "string") {
      // 带 id 无 method：客户端发来的响应，忽略
      return "id" in m && ("result" in m || "error" in m) ? null : err(m.id, -32600, "Invalid Request");
    }
    const hasId = m.id !== undefined && m.id !== null;
    if (!hasId || m.method.startsWith("notifications/")) return null;

    const ok = (result: unknown) => ({ jsonrpc: "2.0", id: m.id, result });
    const params = (m.params && typeof m.params === "object" ? m.params : {}) as Record<string, unknown>;

    switch (m.method) {
      case "initialize": {
        const want = params.protocolVersion;
        const protocolVersion = typeof want === "string" && SUPPORTED_PROTOCOLS.includes(want) ? want : "2025-06-18";
        return ok({
          protocolVersion,
          capabilities: { tools: {} },
          serverInfo: { name: "daily", version: "1.0.0" },
          instructions: `${INSTRUCTIONS}\n你在 Daily 里的身份是「${clientName(caller)}」：只能修改/删除你自己创建的日程，其他 AI 创建的日程只读。`,
        });
      }
      case "ping":
        return ok({});
      case "tools/list":
        return ok({ tools: TOOLS });
      case "tools/call": {
        const name = params.name;
        if (typeof name !== "string" || !TOOLS.some((t) => t.name === name)) {
          return err(m.id, -32602, `未知工具：${String(name)}`);
        }
        const args = (params.arguments && typeof params.arguments === "object" && !Array.isArray(params.arguments)
          ? params.arguments
          : {}) as Args;
        try {
          const result = await this.callTool(name, args, caller);
          return ok({ content: [{ type: "text", text: JSON.stringify(result) }] });
        } catch (e) {
          if (e instanceof UserError) return ok({ content: [{ type: "text", text: e.message }], isError: true });
          console.error(e);
          return ok({ content: [{ type: "text", text: "服务内部错误，请稍后重试。" }], isError: true });
        }
      }
      default:
        return err(m.id, -32601, `Method not found: ${m.method}`);
    }
  }

  // ----- 工具实现 -----

  private async callTool(name: string, args: Args, caller: string): Promise<unknown> {
    switch (name) {
      case "list_events":
        return this.listEvents(args, caller);
      case "add_event":
        return this.addEvent(args, caller);
      case "update_event":
        return this.updateEvent(args, caller);
      default:
        return this.deleteEvent(args, caller);
    }
  }

  private publicAgent(ev: AgentEvent, caller: string, withStamps = false) {
    const out: Record<string, unknown> = { id: ev.id, title: ev.title, start: ev.start };
    if (ev.end) out.end = ev.end;
    out.all_day = ev.all_day;
    if (ev.location) out.location = ev.location;
    if (ev.notes) out.notes = ev.notes;
    out.source = clientName(clientOf(ev));
    out.editable = clientOf(ev) === caller && clientOf(ev) !== SMS_CLIENT;
    if (ev.kind) out.kind = ev.kind;
    if (ev.meta) out.meta = ev.meta;
    if (withStamps) {
      out.created_at = ev.created_at;
      out.updated_at = ev.updated_at;
    }
    return out;
  }

  private async listEvents(args: Args, caller: string) {
    const c = this.clock;
    const sd = str(args, "start_date", { required: true, max: 20 })!;
    const ed = str(args, "end_date", { max: 20 }) || sd;
    const ps = c.parse(sd);
    const pe = c.parse(ed);
    if (ps?.kind !== "date") throw new UserError(`start_date 格式应为 YYYY-MM-DD：「${sd}」。`);
    if (pe?.kind !== "date") throw new UserError(`end_date 格式应为 YYYY-MM-DD：「${ed}」。`);
    if (ed < sd) throw new UserError("end_date 不能早于 start_date。");
    const rs = c.midnight(sd);
    const re = c.midnight(ed) + DAY_MS; // 含 end_date 当天
    if ((re - rs) / DAY_MS > MAX_RANGE_DAYS) throw new UserError(`查询范围最多 ${MAX_RANGE_DAYS} 天，请缩小范围或分多次查询。`);

    const items: { ms: number; ev: Record<string, unknown> }[] = [];
    const push = (e: { start: string; end?: string; all_day: boolean }, out: Record<string, unknown>) => {
      const sp = c.span(e);
      if (sp && sp[0] < re && sp[1] > rs) items.push({ ms: sp[0], ev: out });
    };

    const snapshot = await this.loadSnapshot();
    for (const e of snapshot.events) {
      const out: Record<string, unknown> = { title: e.title, start: e.start };
      if (e.end) out.end = e.end;
      out.all_day = e.all_day;
      if (e.location) out.location = e.location;
      if (e.notes) out.notes = e.notes;
      out.source = e.source || "Daily";
      out.editable = false;
      push(e, out);
    }
    for (const e of Object.values(await this.loadAgent())) {
      if (!e.deleted) push(e, this.publicAgent(e, caller));
    }
    items.sort((a, b) => a.ms - b.ms || String(a.ev.title).localeCompare(String(b.ev.title)));
    return {
      now: c.format(Date.now()),
      snapshot_updated_at: snapshot.generated_at,
      start_date: sd,
      end_date: ed,
      count: items.length,
      events: items.map((i) => i.ev),
    };
  }

  private async addEvent(args: Args, caller: string) {
    const title = str(args, "title", { required: true, max: 200 })!;
    const startIn = str(args, "start", { required: true, max: 40 })!;
    const endIn = str(args, "end", { max: 40 });
    const allDay = bool(args, "all_day");
    const location = str(args, "location", { max: 200 });
    const notes = str(args, "notes", { max: 2000 });
    const t = this.clock.normalize(startIn, endIn, allDay);

    const agent = await this.loadAgent();
    const now = utcStamp();
    // 自己创建的、同标题 + 同开始时间的未删除条目 → 更新
    const dup = Object.values(agent).find(
      (e) => !e.deleted && clientOf(e) === caller && e.title === title && e.start === t.start,
    );
    if (dup) {
      dup.all_day = t.all_day;
      if (endIn !== undefined && endIn !== "") dup.end = t.end;
      if (location) dup.location = location;
      if (notes) dup.notes = notes;
      dup.updated_at = now;
      await this.saveAgent(agent);
      return this.publicAgent(dup, caller, true);
    }
    const ev: AgentEvent = {
      id: crypto.randomUUID(),
      title,
      start: t.start,
      ...(t.end ? { end: t.end } : {}),
      all_day: t.all_day,
      ...(location ? { location } : {}),
      ...(notes ? { notes } : {}),
      created_at: now,
      updated_at: now,
      deleted: false,
      client: caller,
    };
    agent[ev.id] = ev;
    await this.saveAgent(agent);
    return this.publicAgent(ev, caller, true);
  }

  /** 取出可编辑的条目，否则抛出中文错误。 */
  private findEditable(agent: Record<string, AgentEvent>, id: string, caller: string): AgentEvent {
    if (id.startsWith("daily:")) throw new UserError("这条日程来自用户的 Daily（课程/系统日历），只读，不能修改或删除。");
    const ev = agent[id];
    if (!ev || ev.deleted) {
      throw new UserError(`找不到 id 为「${id}」的日程。只能修改/删除你自己创建的日程（editable=true），请先用 list_events 确认 id。`);
    }
    if (clientOf(ev) === SMS_CLIENT) {
      throw new UserError("这条日程由短信自动生成（取件、车票、机票等），只读，任何 AI 都不能修改或删除。");
    }
    if (clientOf(ev) !== caller) {
      throw new UserError(`这条日程是 ${clientName(clientOf(ev))} 创建的，只能由它修改或删除。`);
    }
    return ev;
  }

  private async updateEvent(args: Args, caller: string) {
    const c = this.clock;
    const id = str(args, "id", { required: true, max: 100 })!;
    const agent = await this.loadAgent();
    const ev = this.findEditable(agent, id, caller);

    const title = str(args, "title", { max: 200 });
    if (title === "") throw new UserError("title 不能为空。");
    const startIn = str(args, "start", { max: 40 });
    const endIn = str(args, "end", { max: 40 });
    const allDayIn = bool(args, "all_day");
    const location = str(args, "location", { max: 200 });
    const notes = str(args, "notes", { max: 2000 });
    if ([title, startIn, endIn, allDayIn, location, notes].every((v) => v === undefined)) {
      throw new UserError("没有要修改的字段。");
    }

    // 合并时间：改了 start 又没给 end 时，保持原时长
    const startChanged = startIn !== undefined && startIn !== "";
    const newStart = startChanged ? startIn : ev.start;
    const allDay = allDayIn ?? (startChanged ? c.isDateOnly(newStart) : ev.all_day);
    let newEnd: string | undefined;
    if (endIn !== undefined) {
      newEnd = endIn;
    } else if (ev.end && allDay === ev.all_day) {
      newEnd = ev.end;
      const os = c.span(ev);
      const ns = c.parse(newStart);
      if (startChanged && os && ns) {
        if (allDay) {
          const days = Math.round((os[1] - os[0]) / DAY_MS);
          newEnd = c.addDays(ns.kind === "date" ? ns.ymd : c.ymd(ns.ms), days);
        } else if (ns.kind === "datetime") {
          newEnd = c.format(ns.ms + (c.parse(ev.end) as { ms: number }).ms - (c.parse(ev.start) as { ms: number }).ms);
        }
      }
    }
    const t = c.normalize(newStart, newEnd, allDay);

    if (title !== undefined) ev.title = title;
    ev.start = t.start;
    if (t.end) ev.end = t.end;
    else delete ev.end;
    ev.all_day = t.all_day;
    if (location !== undefined) {
      if (location) ev.location = location;
      else delete ev.location;
    }
    if (notes !== undefined) {
      if (notes) ev.notes = notes;
      else delete ev.notes;
    }
    ev.updated_at = utcStamp();
    await this.saveAgent(agent);
    return this.publicAgent(ev, caller, true);
  }

  private async deleteEvent(args: Args, caller: string) {
    const id = str(args, "id", { required: true, max: 100 })!;
    const agent = await this.loadAgent();
    const ev = this.findEditable(agent, id, caller);
    ev.deleted = true;
    ev.updated_at = utcStamp();
    await this.saveAgent(agent);
    return { ok: true, id, deleted: true, title: ev.title };
  }
}
