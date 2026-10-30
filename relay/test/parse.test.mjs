// 短信解析单元测试：node --experimental-strip-types --test test/parse.test.mjs（Node 22.6+，Node 24+ 可省略 flag）
import test from "node:test";
import assert from "node:assert/strict";
import { Clock } from "../src/clock.ts";
import { parseSms, inferDate, normalizeText } from "../src/sms.ts";

const clock = new Clock("+08:00");
const NOW = Date.parse("2026-10-30T08:00:00Z"); // 北京 16:00
const parse = (s, now = NOW) => parseSms(s, now, clock);

test("菜鸟驿站到件", () => {
  const r = parse("【菜鸟驿站】您的中通包裹已到天津大学北洋园校区菜鸟驿站，请凭6-2-1043及时取件，有疑问联系18800000000");
  assert.equal(r.type, "pickup");
  const e = r.event;
  assert.equal(e.title, "取件 6-2-1043 · 天津大学北洋园校区菜鸟驿站");
  assert.equal(e.all_day, false);
  assert.equal(e.start, "2026-10-30T16:00:00+08:00");
  assert.equal(e.end, undefined);
  assert.equal(e.kind, "parcel");
  assert.deepEqual(e.meta, { pickup_code: "6-2-1043", station: "天津大学北洋园校区菜鸟驿站", carrier: "中通" });
  assert.equal(e.location, "天津大学北洋园校区菜鸟驿站");
});

test("兔喜生活（通用）", () => {
  const r = parse("【兔喜生活】快递已到XX小区兔喜超市，取件码3-5-2201，营业时间8:00-21:00");
  assert.equal(r.type, "pickup");
  assert.equal(r.event.meta.pickup_code, "3-5-2201");
  assert.equal(r.event.meta.station, "XX小区兔喜超市");
});

test("丰巢", () => {
  const r = parse("【丰巢】您的顺丰包裹已到达天大北洋园45斋丰巢柜，取件码81234567，请于24小时内取件");
  assert.equal(r.type, "pickup");
  assert.equal(r.event.meta.pickup_code, "81234567");
  assert.equal(r.event.meta.station, "天大北洋园45斋丰巢柜");
  assert.equal(r.event.meta.carrier, "顺丰");
});

test("京东自提", () => {
  const r = parse("【京东】您的订单已送达北洋园京东自提点，提货码 6635，请及时提取");
  assert.equal(r.type, "pickup");
  assert.equal(r.event.meta.pickup_code, "6635");
  assert.equal(r.event.meta.station, "北洋园京东自提点");
  assert.equal(r.event.meta.carrier, "京东");
});

test("全角标点 / 空格变体", () => {
  const r = parse("【菜鸟驿站】您的包裹已到　XX驿站，请凭 6 - 2 - 1043 及时取件，");
  assert.equal(r.type, "pickup");
  assert.equal(r.event.meta.pickup_code, "6-2-1043");
  const r2 = parse("【兔喜生活】快递已到XX小区兔喜超市，取件码：３－５－２２０１，");
  assert.equal(r2.event.meta.pickup_code, "3-5-2201");
});

test("已取件", () => {
  let r = parse("【菜鸟驿站】您的包裹6-2-1043已于10-30 18:20取出，如非本人操作请联系18800000000");
  assert.deepEqual(r, { type: "picked_up", code: "6-2-1043" });
  r = parse("【丰巢】您的包裹已被取出，取件码81234567");
  assert.deepEqual(r, { type: "picked_up", code: "81234567" });
});

test("到件不会被识别为已取件", () => {
  assert.equal(parse("【丰巢】您的包裹已到达XX丰巢柜，取件码123456，请及时取件").type, "pickup");
});

test("12306 购票", () => {
  const r = parse("【铁路客服】订单EH12345678,张三您已购11月7日G2564次5车12F号天津南站08:15开，检票口B12，请携带有效身份证件。");
  assert.equal(r.type, "train");
  assert.equal(r.rebook, false);
  assert.equal(r.order, "EH12345678");
  const e = r.event;
  assert.equal(e.title, "G2564 天津南");
  assert.equal(e.location, "天津南站");
  assert.equal(e.start, "2026-11-07T08:15:00+08:00");
  assert.equal(e.end, undefined);
  assert.equal(e.all_day, false);
  assert.equal(e.kind, "travel");
  assert.equal(e.meta.train, "G2564");
  assert.equal(e.meta.seat, "5车12F号");
  assert.equal(e.meta.gate, "B12");
  assert.equal(e.meta.order, "EH12345678");
});

test("12306 变体：您已购票 / 座位 05车012F号 / 无检票口", () => {
  const r = parse("【铁路客服】订单EH12345678,张三您已购票11月7日G2564次座位05车012F号天津南站08:15开，请携带有效身份证件。");
  assert.equal(r.type, "train");
  assert.equal(r.event.title, "G2564 天津南");
  assert.equal(r.event.meta.seat, "5车12F号");
  assert.equal(r.event.meta.gate, undefined);
  const r2 = parse("【铁路客服】订单EH12345678,张三您已购11月7日G2564次天津南站08:15开");
  assert.equal(r2.type, "train");
  assert.equal(r2.event.title, "G2564 天津南");
  assert.equal(r2.event.meta.seat, undefined);
  // 全角标点
  const r3 = parse("【铁路客服】订单EH12345678，张三您已购11月7日G2564次5车12F号天津南站08：15开，检票口Ｂ12。");
  assert.equal(r3.event.start, "2026-11-07T08:15:00+08:00");
  assert.equal(r3.event.meta.gate, "B12");
});

test("12306 改签 / 退票", () => {
  const buy = parse("【铁路客服】订单EH12345678,张三您已购11月7日G2564次5车12F号天津南站08:15开，检票口B12，请携带有效身份证件。");
  const re = parse("【铁路客服】订单EH12345678,张三您已改签11月8日G2566次3车8A号天津南站09:20开，检票口A3。");
  assert.equal(re.type, "train");
  assert.equal(re.rebook, true);
  assert.equal(re.order, "EH12345678");
  assert.equal(re.event.title, "G2566 天津南");
  assert.equal(re.event.start, "2026-11-08T09:20:00+08:00");
  assert.equal(re.event.meta.seat, "3车8A号");
  assert.notEqual(re.event.id, buy.event.id);
  const c = parse("【铁路客服】订单EH12345678,张三您已办理11月7日G2564次车票退票，退款50.00元将在1-15日内退回。");
  assert.deepEqual(c, { type: "train_cancel", order: "EH12345678", train: "G2564", date: "2026-11-07" });
});

test("航旅纵横航班", () => {
  const r = parse("【航旅纵横】您预订的11月9日MU5101航班，北京首都T2 08:00起飞，预计10:15到达上海虹桥T2，请提前办理值机。");
  assert.equal(r.type, "flight");
  const e = r.event;
  assert.equal(e.title, "MU5101 北京首都→上海虹桥");
  assert.equal(e.start, "2026-11-09T08:00:00+08:00");
  assert.equal(e.end, "2026-11-09T10:15:00+08:00");
  assert.equal(e.meta.flight, "MU5101");
  assert.equal(e.location, "北京首都T2");
  assert.equal(e.kind, "travel");
});

test("东航航班（只有城市）", () => {
  const r = parse("【东方航空】尊敬的旅客，您乘坐的MU5101（北京-上海）11月9日08:00起飞，请提前到达机场。");
  assert.equal(r.type, "flight");
  assert.equal(r.event.title, "MU5101 北京→上海");
  assert.equal(r.event.start, "2026-11-09T08:00:00+08:00");
  assert.equal(r.event.end, undefined);
});

test("无法识别的短信 → null", () => {
  for (const s of [
    "【某银行】您的验证码是123456，5分钟内有效，请勿泄露。",
    "【京东】验证码 6635，请勿告知他人",
    "【招商银行】您尾号1234的账户11月7日支出500.00元",
    "【某商城】双11大促，全场5折起，回复TD退订",
    "您好，明天下午三点开会",
    "",
    "   ",
    "【铁路客服】您的验证码为 123456",
  ]) {
    assert.equal(parse(s), null, s);
  }
});

test("年份推断", () => {
  const dec28 = Date.parse("2026-12-28T04:00:00Z");
  assert.equal(inferDate(1, 3, dec28, clock), "2027-01-03");
  assert.equal(inferDate(12, 30, dec28, clock), "2026-12-30");
  // 刚过去 10 天内的日期仍算今年；过去超过 30 天则推到明年
  assert.equal(inferDate(10, 20, NOW, clock), "2026-10-20");
  assert.equal(inferDate(9, 1, NOW, clock), "2027-09-01");
  // 年初收到去年底的通知
  assert.equal(inferDate(12, 30, Date.parse("2027-01-05T04:00:00Z"), clock), "2026-12-30");
  assert.equal(inferDate(2, 30, NOW, clock), null);
  const r = parseSms("【铁路客服】订单EH12345678,张三您已购1月3日G2564次5车12F号天津南站08:15开，检票口B12。", dec28, clock);
  assert.equal(r.event.start, "2027-01-03T08:15:00+08:00");
});

test("确定性 id：同一短信重复解析相同，不同关键字段不同", () => {
  const a = "【菜鸟驿站】您的中通包裹已到天津大学北洋园校区菜鸟驿站，请凭6-2-1043及时取件，有疑问联系18800000000";
  const b = "【菜鸟驿站】您的圆通包裹已到天津大学北洋园校区菜鸟驿站，请凭6-2-1043及时取件，请尽快领取";
  assert.equal(parse(a).event.id, parse(a).event.id);
  assert.equal(parse(a).event.id, parse(b).event.id); // 同码同站同日 = 同一包裹
  assert.notEqual(parse(a).event.id, parse(a.replace("1043", "1044")).event.id);
  assert.notEqual(parse(a).event.id, parse(a, NOW + 2 * 86400000).event.id); // 隔天复用取件码 = 新包裹
  const t = "【铁路客服】订单EH12345678,张三您已购11月7日G2564次5车12F号天津南站08:15开，检票口B12。";
  assert.equal(parse(t).event.id, parse(t.replace("5车12F号", "6车1A号")).event.id); // 订单+车次+日期决定 id
  assert.match(parse(t).event.id, /^sms-[0-9a-f]{24}$/);
});

test("normalizeText", () => {
  assert.equal(normalizeText("　ＡＢ１２，（ｘ）\n 6 - 2"), "AB12,(x) 6-2");
});
