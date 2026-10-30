// 时间处理（固定偏移，无夏令时）。独立成文件，便于 Node 直接导入做单元测试。

/** 面向调用方的输入错误（中文说明），在 tools/call 里转成 isError。 */
export class UserError extends Error {}

export const DAY_MS = 24 * 3600 * 1000;

function parseOffsetMinutes(s: string | undefined): number {
  const m = (s ?? "+08:00").match(/^([+-])(\d{2}):?(\d{2})$/);
  if (!m) return 480;
  return (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3]));
}

export const pad = (n: number, w = 2) => String(n).padStart(w, "0");

export type Parsed = { kind: "date"; ymd: string } | { kind: "datetime"; ms: number };

export class Clock {
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
