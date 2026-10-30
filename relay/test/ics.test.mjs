// ICS 生成单元测试：node --test test/ics.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { Clock } from "../src/clock.ts";
import { buildIcs, escapeText, foldLine } from "../src/ics.ts";

const clock = new Clock("+08:00");
const NOW = Date.parse("2026-10-30T08:00:00Z");
const ag = (o) => ({ id: "a1", title: "t", start: "2026-11-02T10:00:00+08:00", all_day: false, updated_at: "2026-10-30T00:00:00Z", deleted: false, ...o });

test("转义与折行", () => {
  assert.equal(escapeText("a,b;c\\d\ne"), "a\\,b\\;c\\\\d\\ne");
  const long = "SUMMARY:" + "天津".repeat(40);
  const folded = foldLine(long);
  for (const l of folded.split("\r\n")) assert.ok(new TextEncoder().encode(l).length <= 75);
  assert.equal(folded.split("\r\n").map((l, i) => (i ? l.slice(1) : l)).join(""), long);
});

test("范围、过滤、UID、格式", () => {
  const snap = {
    generated_at: null,
    events: [
      { title: "系统", start: "2026-11-02T10:00:00+08:00", all_day: false, source: "系统日历 · 个人" },
      { title: "课程", start: "2026-11-02T08:00:00+08:00", end: "2026-11-02T09:40:00+08:00", all_day: false, source: "教务课程" },
      { title: "太远", start: "2027-03-02T08:00:00+08:00", all_day: false },
    ],
  };
  const ics = buildIcs(snap, [
    ag({ id: "x1", title: "G2564 天津南", location: "天津南站", notes: "5车12F号, B12" }),
    ag({ id: "x2", title: "已删", deleted: true }),
    ag({ id: "x3", title: "全天", start: "2026-11-03", end: "2026-11-06", all_day: true }),
    ag({ id: "x4", title: "太旧", start: "2026-10-01T10:00:00+08:00" }),
  ], NOW, clock);
  assert.ok(ics.startsWith("BEGIN:VCALENDAR\r\n") && ics.endsWith("END:VCALENDAR\r\n"));
  assert.ok(!ics.includes("系统") && !ics.includes("太远") && !ics.includes("已删") && !ics.includes("太旧"));
  assert.ok(ics.includes("SUMMARY:课程") && ics.includes("UID:x1@daily"));
  assert.ok(ics.includes("DTSTART:20261102T020000Z") && ics.includes("DESCRIPTION:5车12F号\\, B12"));
  assert.ok(ics.includes("DTSTART;VALUE=DATE:20261103\r\nDTEND;VALUE=DATE:20261106"));
  assert.match(ics, /UID:snap-[0-9a-f]{24}@daily/);
  assert.equal(ics, buildIcs(snap, [], NOW, clock).length ? ics : "");
});
