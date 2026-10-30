// iCalendar 订阅源生成（纯函数）。

import type { Clock } from "./clock.ts";
import { DAY_MS } from "./clock.ts";
import { shortHash } from "./sms.ts";

export interface IcsEvent {
  title: string;
  start: string;
  end?: string;
  all_day: boolean;
  location?: string;
  notes?: string;
  meta?: Record<string, string>;
}
export interface IcsAgentEvent extends IcsEvent {
  id: string;
  updated_at: string;
  deleted: boolean;
}
export interface IcsSnapshotEvent extends IcsEvent {
  source?: string;
}

const PAST_DAYS = 7;
const FUTURE_DAYS = 60;

/** TEXT 值转义：反斜杠、分号、逗号、换行。 */
export function escapeText(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r\n|\r|\n/g, "\\n");
}

/** 按 UTF-8 字节在 75 octets 处折行（续行以一个空格开头，也计入 75），不拆开多字节字符。 */
export function foldLine(line: string): string {
  const enc = new TextEncoder();
  if (enc.encode(line).length <= 75) return line;
  const out: string[] = [];
  let cur = "";
  let bytes = 0;
  let limit = 75;
  for (const ch of line) {
    const n = enc.encode(ch).length;
    if (bytes + n > limit) {
      out.push(cur);
      cur = "";
      bytes = 0;
      limit = 74; // 续行开头的空格占 1 字节
    }
    cur += ch;
    bytes += n;
  }
  out.push(cur);
  return out.join("\r\n ");
}

const stamp = (ms: number) => new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
const dateOnly = (ymd: string) => ymd.replace(/-/g, "");

/**
 * 生成订阅内容：快照里非「系统日历」的条目 + 所有未删除的 agent event，范围为过去 7 天到未来 60 天。
 * 系统日历本来就在手机上，不重复放。
 */
export function buildIcs(
  snapshot: { events: IcsSnapshotEvent[]; generated_at: string | null },
  agent: IcsAgentEvent[],
  nowMs: number,
  clock: Clock,
): string {
  const rs = nowMs - PAST_DAYS * DAY_MS;
  const re = nowMs + FUTURE_DAYS * DAY_MS;
  const snapStamp = snapshot.generated_at && !Number.isNaN(Date.parse(snapshot.generated_at)) ? Date.parse(snapshot.generated_at) : nowMs;

  const items: { uid: string; ev: IcsEvent; stampMs: number; startMs: number }[] = [];
  const seen = new Set<string>();
  const add = (uid: string, ev: IcsEvent, stampMs: number) => {
    const sp = clock.span(ev);
    if (!sp || sp[0] >= re || sp[1] <= rs || seen.has(uid)) return;
    seen.add(uid);
    items.push({ uid, ev, stampMs, startMs: sp[0] });
  };
  for (const e of snapshot.events) {
    if (e.source?.startsWith("系统日历")) continue;
    add(`snap-${shortHash(e.title + "|" + e.start)}@daily`, e, snapStamp);
  }
  for (const e of agent) {
    if (!e.deleted) add(`${e.id}@daily`, e, Date.parse(e.updated_at) || nowMs);
  }
  items.sort((a, b) => a.startMs - b.startMs || a.uid.localeCompare(b.uid));

  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Daily//Relay//ZH",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "X-WR-CALNAME:Daily",
    "REFRESH-INTERVAL;VALUE=DURATION:PT15M",
    "X-PUBLISHED-TTL:PT15M",
  ];
  for (const { uid, ev, stampMs } of items) {
    lines.push("BEGIN:VEVENT", `UID:${uid}`, `DTSTAMP:${stamp(stampMs)}`);
    const sp = clock.span(ev)!;
    if (ev.all_day) {
      lines.push(`DTSTART;VALUE=DATE:${dateOnly(clock.ymd(sp[0]))}`, `DTEND;VALUE=DATE:${dateOnly(clock.ymd(sp[1]))}`);
    } else {
      lines.push(`DTSTART:${stamp(sp[0])}`);
      if (ev.end) lines.push(`DTEND:${stamp(sp[1])}`);
    }
    lines.push(`SUMMARY:${escapeText(ev.title)}`);
    if (ev.location) lines.push(`LOCATION:${escapeText(ev.location)}`);
    // 描述：备注；没有备注时用 meta（如取件码）
    const desc = ev.notes || (ev.meta ? Object.entries(ev.meta).map(([k, v]) => `${k}: ${v}`).join("\n") : "");
    if (desc) lines.push(`DESCRIPTION:${escapeText(desc)}`);
    lines.push("END:VEVENT");
  }
  lines.push("END:VCALENDAR");
  return lines.map(foldLine).join("\r\n") + "\r\n";
}
