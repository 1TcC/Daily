// 短信解析：纯函数，不依赖 Worker 运行时，Node 可直接导入做单元测试。
// 只产出结构化结果，不保留短信原文。

import type { Clock } from "./clock.ts";
import { DAY_MS, pad } from "./clock.ts";

export interface SmsEvent {
  id: string;
  title: string;
  start: string;
  end?: string;
  all_day: boolean;
  location?: string;
  notes?: string;
  kind: "parcel" | "travel";
  meta: Record<string, string>;
}

export type SmsResult =
  | { type: "pickup"; event: SmsEvent }
  | { type: "picked_up"; code?: string; station?: string }
  | { type: "train"; event: SmsEvent; order?: string; rebook: boolean }
  | { type: "train_cancel"; order?: string; train: string; date: string }
  | { type: "flight"; event: SmsEvent }
  | null;

/** 包裹条目从收到当天起保留的天数（end 不含）。 */

/** 同步的稳定短哈希（cyrb53 双种子，96 位），只用于生成确定性 id，非密码学用途。 */
export function shortHash(s: string): string {
  const one = (seed: number) => {
    let h1 = 0xdeadbeef ^ seed;
    let h2 = 0x41c6ce57 ^ seed;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      h1 = Math.imul(h1 ^ c, 2654435761);
      h2 = Math.imul(h2 ^ c, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16).padStart(14, "0").slice(2);
  };
  return one(0) + one(1);
}

export const smsId = (...parts: string[]) => "sms-" + shortHash(parts.join("|"));

/** 全角转半角、统一连字符与空白，方便后面用一套正则。 */
export function normalizeText(raw: string): string {
  return raw
    .replace(/[！-～]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/[　 ]/g, " ")
    .replace(/[‐-―−]/g, "-")
    .replace(/\s+/g, " ")
    .replace(/(\d) ?- ?(?=\d)/g, "$1-") // "6 - 2 - 1043" → "6-2-1043"
    .trim();
}

/**
 * 只有「月日」时推断年份：在去年/今年/明年里，取不早于 30 天前、且离现在最近的那天。
 * 返回 YYYY-MM-DD；日期不存在返回 null。
 */
export function inferDate(month: number, day: number, nowMs: number, clock: Clock): string | null {
  const nowYear = Number(clock.ymd(nowMs).slice(0, 4));
  let best: { ymd: string; dist: number } | null = null;
  for (const y of [nowYear - 1, nowYear, nowYear + 1]) {
    const t = new Date(Date.UTC(y, month - 1, day));
    if (t.getUTCFullYear() !== y || t.getUTCMonth() !== month - 1 || t.getUTCDate() !== day) continue;
    const ymd = `${y}-${pad(month)}-${pad(day)}`;
    const ms = clock.midnight(ymd);
    if (ms < nowMs - 30 * DAY_MS) continue;
    const dist = Math.abs(ms - nowMs);
    if (!best || dist < best.dist) best = { ymd, dist };
  }
  return best?.ymd ?? null;
}

// ---------- 入口 ----------

/**
 * 解析一条短信。nowMs 是收到短信的时间（用于推断年份、包裹收到日）。
 * 无法识别（验证码、广告、银行等）返回 null。
 */
export function parseSms(text: string, nowMs: number, clock: Clock): SmsResult {
  const t = normalizeText(text).slice(0, 2000);
  if (!t) return null;
  const sender = t.match(/【([^】]{1,20})】/)?.[1] ?? "";
  return parseTrain(t, nowMs, clock) ?? parseFlight(t, nowMs, clock) ?? parsePickedUp(t) ?? parsePickup(t, sender, nowMs, clock);
}

// ---------- 快递 ----------

const CARRIERS = ["中通", "圆通", "申通", "韵达", "顺丰", "极兔", "邮政", "EMS", "百世", "德邦", "天天", "丹鸟", "京东", "菜鸟", "兔喜", "安能", "跨越"];
const PARCEL_CONTEXT = /取件|取货|提货|自提|驿站|快递|包裹|丰巢|快递柜|取出|订单/;

const CODE_LABEL = /(?:取件码|取货码|提货码|提取码|取件号|取货号|取件密码|取货密码)\s*[::为是]?\s*([A-Za-z0-9]+(?:-[A-Za-z0-9]+){0,3})/;
const CODE_PING = /凭\s*([A-Za-z0-9]+(?:-[A-Za-z0-9]+){0,3})\s*(?:及时|前往|到|来|取|领)/;
const CODE_DASH = /(?<![\d-])(\d{1,3}-\d{1,3}-\d{2,6})(?![\d-])/;

function extractCode(t: string): string | undefined {
  return (t.match(CODE_LABEL) ?? t.match(CODE_PING) ?? t.match(CODE_DASH))?.[1];
}

const STATION_ARRIVE = /已(?:经)?(?:到达|送达|到|入库|存放在|存放至|存入|放入|投递至|投递到)\s*([^,。;!?:]{2,40}?)\s*(?=[,。;]|请|凭|取件码|取货码|提货码|提取码|取件号|$)/;
const noTags = (t: string) => t.replace(/【[^】]*】/g, " ");
const STATION_NAME = /([^,。;\s【】]{2,30}?(?:驿站|丰巢柜|快递柜|自提点|自提柜|取件点|超市|快递站|服务站))/;

function cleanStation(s: string): string {
  return s.replace(/[【】\[\]]/g, "").replace(/^(?:您的|你的|的)/, "").trim().slice(0, 40);
}

function parsePickedUp(t: string): SmsResult {
  const done = /已(?:被|由)?(?:取出|取走|取件|签收|提取|领取|取货|提货)|取件成功|已于[^,。]{0,20}?(?:取出|取走|取件|签收)|已出库/;
  if (!done.test(t) || !PARCEL_CONTEXT.test(t)) return null;
  const code = extractCode(t);
  const st = noTags(t).match(STATION_NAME)?.[1];
  const station = st ? cleanStation(st) : undefined;
  return { type: "picked_up", ...(code ? { code } : {}), ...(station ? { station } : {}) };
}

function parsePickup(t: string, sender: string, nowMs: number, clock: Clock): SmsResult {
  const code = extractCode(t);
  if (!code || !PARCEL_CONTEXT.test(t)) return null;
  const arrive = t.match(STATION_ARRIVE)?.[1];
  let station = arrive ? cleanStation(arrive) : "";
  if (!station) station = cleanStation(noTags(t).match(STATION_NAME)?.[1] ?? "");
  if (!station) station = sender || "快递";

  const c = t.match(/您的\s*([一-龥A-Za-z]{1,4}?)(?:快递|包裹|物流)/)?.[1];
  const carrier = CARRIERS.find((x) => x === c) ?? CARRIERS.find((x) => x === sender);

  const day = clock.ymd(nowMs);
  const meta: Record<string, string> = { pickup_code: code, station };
  if (carrier) meta.carrier = carrier;
  return {
    type: "pickup",
    event: {
      // 带上收到日期：取件码可能被复用，隔天的同码快递是新包裹
      id: smsId("parcel", code, station, day),
      title: `取件 ${code} · ${station}`,
      // 只在收到短信的时刻出现一次；没取的件由 Daily「待取件」列表持续提醒
      start: clock.format(nowMs),
      all_day: false,
      location: station,
      notes: `取件码 ${code}`,
      kind: "parcel",
      meta,
    },
  };
}

// ---------- 火车（12306） ----------

const MD = /(\d{1,2})月(\d{1,2})日/;
const TRAIN_NO = /(?<![A-Za-z0-9])([A-Z]{0,2}\d{1,4})次/;
const STATION_TIME = /([一-龥]{2,14})站\s*(\d{1,2}):(\d{2})\s*(?:开|发车)/;

const hm = (h: string, m: string): number | null => (Number(h) <= 23 && Number(m) <= 59 ? Number(h) * 60 + Number(m) : null);
const noZeros = (s: string) => s.replace(/^0+(?=\d)/, "");

function parseTrain(t: string, nowMs: number, clock: Clock): SmsResult {
  const md = t.match(MD);
  const train = t.match(TRAIN_NO)?.[1];
  if (!md || !train) return null;
  const ymd = inferDate(Number(md[1]), Number(md[2]), nowMs, clock);
  if (!ymd) return null;
  const order = t.match(/订单\s*号?\s*[::]?\s*([A-Za-z0-9]{5,12})/)?.[1];

  const st = t.match(STATION_TIME);
  if (!st) {
    return /退票/.test(t) ? { type: "train_cancel", ...(order ? { order } : {}), train, date: ymd } : null;
  }
  // 站名前面可能粘着「号/次/座/票/购/车」等汉字（座位、车次后面没有标点时）
  const from = st[1].replace(/^.*[号次座票购车签]/, "");
  const min = hm(st[2], st[3]);
  if (from.length < 2 || min === null) return null;
  const startMs = clock.midnight(ymd) + min * 60000;

  const sm = t.match(/(\d{1,2})车\s*(\d{1,3}[A-Za-z]?)号/);
  const seat = sm ? `${noZeros(sm[1])}车${noZeros(sm[2])}号` : /无座/.test(t) ? "无座" : "";
  const gate = t.match(/检票口\s*[::]?\s*([A-Za-z0-9]+(?:[-、/][A-Za-z0-9]+)?)/)?.[1] ?? "";

  const meta: Record<string, string> = { train };
  if (seat) meta.seat = seat;
  if (gate) meta.gate = gate;
  if (order) meta.order = order;
  meta.station = `${from}站`;
  const notes = [seat, gate && `检票口${gate}`, order && `订单${order}`].filter(Boolean).join(" · ");
  return {
    type: "train",
    order,
    rebook: /改签/.test(t),
    event: {
      id: order ? smsId("train", order, train, ymd) : smsId("train", train, ymd, from),
      title: `${train} ${from}`,
      start: clock.format(startMs),
      all_day: false,
      location: `${from}站`,
      ...(notes ? { notes } : {}),
      kind: "travel",
      meta,
    },
  };
}

// ---------- 航班（尽力而为） ----------

const FLIGHT_NO = /(?<![A-Za-z0-9])((?:[A-Z][A-Z0-9]|[0-9][A-Z])\d{3,4})(?![0-9A-Za-z])/;
const NOISE_WORDS = /预计|计划|预定|预订|将于|准时|按时|最新|更新为|调整为|变更为|航班|起飞/g;

function parseFlight(t: string, nowMs: number, clock: Clock): SmsResult {
  if (!/航班|起飞|值机|登机/.test(t)) return null;
  const md = t.match(MD);
  const no = t.match(FLIGHT_NO)?.[1];
  const dep = t.match(/(\d{1,2}):(\d{2})\s*起飞/) ?? t.match(/起飞时间\s*[::]?\s*(\d{1,2}):(\d{2})/);
  if (!md || !no || !dep) return null;
  const ymd = inferDate(Number(md[1]), Number(md[2]), nowMs, clock);
  const depMin = hm(dep[1], dep[2]);
  if (!ymd || depMin === null) return null;
  const startMs = clock.midnight(ymd) + depMin * 60000;

  // 出发 / 到达机场（可带航站楼）：「北京首都T2 08:00起飞」「10:15到达上海虹桥T2」
  const depPlace = t.match(/([一-龥]{2,10})\s*(T\d)?\s*\d{1,2}:\d{2}\s*起飞/);
  const depName = depPlace?.[1].replace(/^.*班/, "").replace(NOISE_WORDS, "");
  const depTerm = depPlace?.[2] ?? "";
  const arr = t.match(/(\d{1,2}):(\d{2})\s*(?:到达|抵达|落地)\s*([一-龥]{2,10})?\s*(T\d)?/);
  const arrMin = arr ? hm(arr[1], arr[2]) : null;
  const arrName = arr?.[3];
  const arrTerm = arr?.[4] ?? "";
  const cities = t.match(/\(([一-龥]{2,6})\s*(?:-|至|到|→)\s*([一-龥]{2,6})\)/);

  let route = "";
  if (depName && depName.length >= 2 && arrName) route = `${depName}→${arrName}`;
  else if (cities) route = `${cities[1]}→${cities[2]}`;
  else if (depName && depName.length >= 2) route = depName;

  let endMs: number | undefined;
  if (arrMin !== null) {
    endMs = clock.midnight(ymd) + arrMin * 60000;
    if (endMs <= startMs) endMs += DAY_MS; // 跨天到达
  }
  const meta: Record<string, string> = { flight: no };
  if (depName && depName.length >= 2) meta.from = depName + depTerm;
  if (arrName) meta.to = arrName + arrTerm;
  const notes = [depTerm && `出发${depTerm}`, arrTerm && `到达${arrTerm}`].filter(Boolean).join(" · ");
  return {
    type: "flight",
    event: {
      id: smsId("flight", no, ymd),
      title: route ? `${no} ${route}` : no,
      start: clock.format(startMs),
      ...(endMs !== undefined ? { end: clock.format(endMs) } : {}),
      all_day: false,
      ...(depName && depName.length >= 2 ? { location: depName + depTerm } : {}),
      ...(notes ? { notes } : {}),
      kind: "travel",
      meta,
    },
  };
}
