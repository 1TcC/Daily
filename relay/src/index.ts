// Daily Relay：让手机上的 AI 助手（Grok，经 MCP）读写日程，并与 Mac 上的 Daily 同步。
// Worker 只负责校验路径里的密钥并转发；所有状态与业务逻辑都在单个 Durable Object 里，保证强一致。

// ---------- 最小类型声明（避免依赖 @cloudflare/workers-types） ----------

interface DurableObjectStorageLike {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
}
interface DurableObjectStateLike {
  storage: DurableObjectStorageLike;
}
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

/** 面向调用方的输入错误（中文说明），在 tools/call 里转成 isError。 */
class UserError extends Error {}

const MAX_SNAPSHOT_EVENTS = 5000;
const MAX_SNAPSHOT_BYTES = 1_900_000; // DO 单个 value 上限约 2MB
const MAX_RANGE_DAYS = 120;
const TOMBSTONE_MS = 30 * 24 * 3600 * 1000;
const DAY_MS = 24 * 3600 * 1000;

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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const secret = env.RELAY_SECRET;
    if (!secret) return notFound();

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
    const out = new Response(resp.body, resp);
    for (const [k, v] of Object.entries(CORS)) out.headers.set(k, v);
    return out;
  },
};

// ---------- 时间处理（固定偏移，无夏令时） ----------

function parseOffsetMinutes(s: string | undefined): number {
  const m = (s ?? "+08:00").match(/^([+-])(\d{2}):?(\d{2})$/);
  if (!m) return 480;
  return (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3]));
}

const pad = (n: number, w = 2) => String(n).padStart(w, "0");

type Parsed = { kind: "date"; ymd: string } | { kind: "datetime"; ms: number };

class Clock {
  readonly offsetMs: number;
  readonly offsetStr: string;
  constructor(utcOffset: string | undefined) {
    const min = parseOffsetMinutes(utcOffset);
    this.offsetMs = min * 60000;
    const a = Math.abs(min);
    this.offsetStr = `${min < 0 ? "-" : "+"}${pad(Math.floor(a / 60))}:${pad(a % 60)}`;
  }

  /** 解析输入；失败返回 null。 */
  parse(input: string): Parsed | null {
    const s = input.trim();
    const d = s.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (d) {
      const [y, mo, da] = [Number(d[1]), Number(d[2]), Number(d[3])];
      const t = new Date(Date.UTC(y, mo - 1, da));
      if (t.getUTCFullYear() !== y || t.getUTCMonth() !== mo - 1 || t.getUTCDate() !== da) return null;
      return { kind: "date", ymd: s };
    }
    const m = s.match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?$/i);
    if (!m) return null;
    const [y, mo, da, h, mi] = [m[1], m[2], m[3], m[4], m[5]].map(Number);
    const sec = m[6] ? Number(m[6]) : 0;
    if (h > 23 || mi > 59 || sec > 59) return null;
    const t = new Date(Date.UTC(y, mo - 1, da, h, mi, sec));
    if (t.getUTCFullYear() !== y || t.getUTCMonth() !== mo - 1 || t.getUTCDate() !== da) return null;
    const off = m[7] ? (m[7].toUpperCase() === "Z" ? 0 : parseOffsetMinutes(m[7]) * 60000) : this.offsetMs;
    return { kind: "datetime", ms: t.getTime() - off };
  }

  /** ms → 2026-11-03T19:35:00+08:00 */
  format(ms: number): string {
    return this.ymd(ms) + "T" + this.hms(ms) + this.offsetStr;
  }
  private local(ms: number): Date {
    return new Date(ms + this.offsetMs);
  }
  ymd(ms: number): string {
    const t = this.local(ms);
    return `${pad(t.getUTCFullYear(), 4)}-${pad(t.getUTCMonth() + 1)}-${pad(t.getUTCDate())}`;
  }
  private hms(ms: number): string {
    const t = this.local(ms);
    return `${pad(t.getUTCHours())}:${pad(t.getUTCMinutes())}:${pad(t.getUTCSeconds())}`;
  }
  /** 本地日期 00:00 对应的 UTC 毫秒。 */
  midnight(ymd: string): number {
    const [y, m, d] = ymd.split("-").map(Number);
    return Date.UTC(y, m - 1, d) - this.offsetMs;
  }
  addDays(ymd: string, n: number): string {
    const [y, m, d] = ymd.split("-").map(Number);
    const t = new Date(Date.UTC(y, m - 1, d + n));
    return `${pad(t.getUTCFullYear(), 4)}-${pad(t.getUTCMonth() + 1)}-${pad(t.getUTCDate())}`;
  }
  isDateOnly(s: string): boolean {
    return this.parse(s)?.kind === "date";
  }

  /**
   * 归一化起止时间。
   * 全天：start/end 为 YYYY-MM-DD，end 不含（默认次日；end 不晚于 start 时按单日处理）。
   * 非全天：输出带偏移的 ISO，end 必须晚于 start。
   */
  normalize(startIn: string, endIn: string | undefined, allDayIn: boolean | undefined) {
    const s = this.parse(startIn);
    if (!s) throw new UserError(`start 格式不对：「${startIn}」。可用 2026-11-03 19:35、2026-11-03T19:35、2026-11-03T19:35:00+08:00，全天日程用 2026-11-03。`);
    let e: Parsed | null = null;
    if (endIn !== undefined && endIn !== "") {
      e = this.parse(endIn);
      if (!e) throw new UserError(`end 格式不对：「${endIn}」。格式同 start。`);
    }
    const allDay = allDayIn ?? s.kind === "date";
    if (allDay) {
      const sd = s.kind === "date" ? s.ymd : this.ymd(s.ms);
      let ed = e ? (e.kind === "date" ? e.ymd : this.ymd(e.ms)) : this.addDays(sd, 1);
      if (ed < sd) throw new UserError("end 不能早于 start。");
      if (ed === sd) ed = this.addDays(sd, 1);
      return { start: sd, end: ed, all_day: true };
    }
    if (s.kind === "date") throw new UserError("非全天日程的 start 需要具体时间（如 2026-11-03 19:35）；若是全天日程请设置 all_day=true。");
    const sms = s.ms;
    const out: { start: string; end?: string; all_day: boolean } = { start: this.format(sms), all_day: false };
    if (e) {
      const ems = e.kind === "date" ? this.midnight(e.ymd) : e.ms;
      if (ems <= sms) throw new UserError("end 必须晚于 start。");
      out.end = this.format(ems);
    }
    return out;
  }

  /** 事件的 [起, 止) 毫秒区间；无 end 的定时日程视为一个瞬间。 */
  span(ev: { start: string; end?: string; all_day: boolean }): [number, number] | null {
    if (ev.all_day) {
      const sd = this.parse(ev.start);
      if (!sd) return null;
      const s = this.midnight(sd.kind === "date" ? sd.ymd : this.ymd(sd.ms));
      const ed = ev.end ? this.parse(ev.end) : null;
      const e = ed ? this.midnight(ed.kind === "date" ? ed.ymd : this.ymd(ed.ms)) : s + DAY_MS;
      return [s, Math.max(e, s + DAY_MS)];
    }
    const s = this.parse(ev.start);
    if (!s || s.kind !== "datetime") return null;
    const e = ev.end ? this.parse(ev.end) : null;
    const ems = e && e.kind === "datetime" ? e.ms : s.ms;
    return [s.ms, Math.max(ems, s.ms + 1)];
  }
}

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
  }

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    const method = request.method;
    if (path === "/mcp") {
      if (method === "POST") return this.handleMcp(request);
      return new Response(null, { status: 405, headers: { Allow: "POST, OPTIONS" } });
    }
    if (path === "/sync/agent-events") {
      if (method !== "GET") return new Response(null, { status: 405, headers: { Allow: "GET" } });
      const agent = await this.loadAgent();
      return json({ events: Object.values(agent), now: this.clock.format(Date.now()) });
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
    // 写入时顺便清理超过 30 天的墓碑
    const cutoff = Date.now() - TOMBSTONE_MS;
    for (const [id, ev] of Object.entries(agent)) {
      if (ev.deleted && Date.parse(ev.updated_at) < cutoff) delete agent[id];
    }
    await this.state.storage.put("agent", agent);
  }
  private async loadSnapshot(): Promise<Snapshot> {
    return (await this.state.storage.get<Snapshot>("snapshot")) ?? { events: [], generated_at: null };
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

  private async handleMcp(request: Request): Promise<Response> {
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
        const r = await this.handleRpc(item);
        if (r) out.push(r);
      }
      return out.length ? json(out) : new Response(null, { status: 202 });
    }
    const r = await this.handleRpc(body);
    return r ? json(r) : new Response(null, { status: 202 });
  }

  /** 处理单个 JSON-RPC 消息；通知 / 客户端响应返回 null。 */
  private async handleRpc(msg: unknown): Promise<Json | null> {
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
          instructions: INSTRUCTIONS,
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
          const result = await this.callTool(name, args);
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

  private async callTool(name: string, args: Args): Promise<unknown> {
    switch (name) {
      case "list_events":
        return this.listEvents(args);
      case "add_event":
        return this.addEvent(args);
      case "update_event":
        return this.updateEvent(args);
      default:
        return this.deleteEvent(args);
    }
  }

  private publicAgent(ev: AgentEvent, withStamps = false) {
    const out: Record<string, unknown> = { id: ev.id, title: ev.title, start: ev.start };
    if (ev.end) out.end = ev.end;
    out.all_day = ev.all_day;
    if (ev.location) out.location = ev.location;
    if (ev.notes) out.notes = ev.notes;
    out.source = "Grok";
    out.editable = true;
    if (withStamps) {
      out.created_at = ev.created_at;
      out.updated_at = ev.updated_at;
    }
    return out;
  }

  private async listEvents(args: Args) {
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
      if (!e.deleted) push(e, this.publicAgent(e));
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

  private async addEvent(args: Args) {
    const title = str(args, "title", { required: true, max: 200 })!;
    const startIn = str(args, "start", { required: true, max: 40 })!;
    const endIn = str(args, "end", { max: 40 });
    const allDay = bool(args, "all_day");
    const location = str(args, "location", { max: 200 });
    const notes = str(args, "notes", { max: 2000 });
    const t = this.clock.normalize(startIn, endIn, allDay);

    const agent = await this.loadAgent();
    const now = utcStamp();
    // 同标题 + 同开始时间的未删除条目 → 更新
    const dup = Object.values(agent).find((e) => !e.deleted && e.title === title && e.start === t.start);
    if (dup) {
      dup.all_day = t.all_day;
      if (endIn !== undefined && endIn !== "") dup.end = t.end;
      if (location) dup.location = location;
      if (notes) dup.notes = notes;
      dup.updated_at = now;
      await this.saveAgent(agent);
      return this.publicAgent(dup, true);
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
    };
    agent[ev.id] = ev;
    await this.saveAgent(agent);
    return this.publicAgent(ev, true);
  }

  /** 取出可编辑的条目，否则抛出中文错误。 */
  private findEditable(agent: Record<string, AgentEvent>, id: string): AgentEvent {
    if (id.startsWith("daily:")) throw new UserError("这条日程来自用户的 Daily（课程/系统日历），只读，不能修改或删除。");
    const ev = agent[id];
    if (!ev || ev.deleted) {
      throw new UserError(`找不到 id 为「${id}」的日程。只能修改/删除你自己创建的日程（editable=true），请先用 list_events 确认 id。`);
    }
    return ev;
  }

  private async updateEvent(args: Args) {
    const c = this.clock;
    const id = str(args, "id", { required: true, max: 100 })!;
    const agent = await this.loadAgent();
    const ev = this.findEditable(agent, id);

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
    return this.publicAgent(ev, true);
  }

  private async deleteEvent(args: Args) {
    const id = str(args, "id", { required: true, max: 100 })!;
    const agent = await this.loadAgent();
    const ev = this.findEditable(agent, id);
    ev.deleted = true;
    ev.updated_at = utcStamp();
    await this.saveAgent(agent);
    return { ok: true, id, deleted: true, title: ev.title };
  }
}
