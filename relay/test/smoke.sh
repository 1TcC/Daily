#!/usr/bin/env bash
# 冒烟测试：bash test/smoke.sh [BASE_URL]，默认 http://localhost:8787/testsecret
# 需要先启动：npx wrangler dev --port 8787（RELAY_SECRET 取自 .dev.vars，值为 testsecret）
BASE="${1:-http://localhost:8787/testsecret}"
BASE="${BASE%/}"
ORIGIN="$(echo "$BASE" | sed -E 's#^(https?://[^/]+)/.*#\1#')"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1  -> $2"; }

# rpc <json>：POST 到 /mcp，输出响应体
rpc() { curl -sS -X POST "$BASE/mcp" -H 'Content-Type: application/json' -d "$1"; }
# tool <name> <args-json>：输出整个 JSON-RPC 响应
tool() { rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }
# py <python-expr 使用 d 表示解析后的 JSON>：stdin 为 JSON，打印表达式结果
py() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
# inner：取出 tools/call 结果的 text 并解析为 JSON 打印
inner() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["result"]["content"][0]["text"])'; }
# check <名称> <JSON> <表达式> ：表达式为 True 则通过
check() {
  local out; out="$(printf '%s' "$2" | py "$3" 2>&1)"
  if [ "$out" = "True" ]; then ok "$1"; else bad "$1" "$out | $2"; fi
}

TITLE="冒烟测试-$$"

# 1. initialize
R="$(rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}')"
check "initialize 回显协议版本并带 serverInfo" "$R" 'd["result"]["protocolVersion"]=="2025-03-26" and d["result"]["serverInfo"]["name"]=="daily" and "instructions" in d["result"]'

# 2. tools/list
R="$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
check "tools/list 返回 4 个工具" "$R" 'sorted(t["name"] for t in d["result"]["tools"])==["add_event","delete_event","list_events","update_event"]'

# 通知 → 202
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/mcp" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"notifications/initialized"}')"
[ "$CODE" = "202" ] && ok "notification 返回 202" || bad "notification 返回 202" "$CODE"

# 3. add_event（不带时区）
R="$(tool add_event "{\"title\":\"$TITLE\",\"start\":\"2031-11-03 19:35\",\"end\":\"2031-11-03T21:00\",\"location\":\"线上\"}")"
check "add_event 成功且按 +08:00 输出" "$R" 'json.loads(d["result"]["content"][0]["text"])["start"]=="2031-11-03T19:35:00+08:00" and "isError" not in d["result"]'
ID="$(printf '%s' "$R" | inner | py 'd["id"]')"

# 4. list_events 可见且 editable
R="$(tool list_events '{"start_date":"2031-11-03","end_date":"2031-11-03"}')"
check "list_events 包含该日程且 editable=true" "$R" "any(e['title']=='$TITLE' and e['editable'] is True and e['source']=='Grok' and e['id']=='$ID' for e in json.loads(d['result']['content'][0]['text'])['events'])"
check "list_events 带 now 和 snapshot_updated_at" "$R" "(lambda x: 'now' in x and 'snapshot_updated_at' in x and x['now'].endswith('+08:00'))(json.loads(d['result']['content'][0]['text']))"

# 5. 同标题同开始 → 同 id
R="$(tool add_event "{\"title\":\"$TITLE\",\"start\":\"2031-11-03T19:35:00+08:00\",\"notes\":\"去重\"}")"
check "重复 add_event 复用同一 id 并更新" "$R" "(lambda x: x['id']=='$ID' and x['notes']=='去重')(json.loads(d['result']['content'][0]['text']))"

# 6. update_event
R="$(tool update_event "{\"id\":\"$ID\",\"title\":\"$TITLE-改\",\"location\":\"\"}")"
check "update_event 修改标题并清除地点" "$R" "(lambda x: x['title']=='$TITLE-改' and 'location' not in x and x['start']=='2031-11-03T19:35:00+08:00')(json.loads(d['result']['content'][0]['text']))"

# 全天日程
R="$(tool add_event "{\"title\":\"$TITLE-全天\",\"start\":\"2031-11-05\"}")"
check "全天日程 end 默认次日" "$R" "(lambda x: x['all_day'] is True and x['start']=='2031-11-05' and x['end']=='2031-11-06')(json.loads(d['result']['content'][0]['text']))"
R="$(tool list_events '{"start_date":"2031-11-06","end_date":"2031-11-06"}')"
check "全天日程 end 不含（次日查不到）" "$R" "not any(e['title']=='$TITLE-全天' for e in json.loads(d['result']['content'][0]['text'])['events'])"
ID2="$(tool list_events '{"start_date":"2031-11-05"}' | inner | py "[e['id'] for e in d['events'] if e['title']=='$TITLE-全天'][0]")"

# end <= start → 错误
R="$(tool add_event "{\"title\":\"x\",\"start\":\"2031-11-03 10:00\",\"end\":\"2031-11-03 09:00\"}")"
check "end 早于 start → isError" "$R" 'd["result"]["isError"] is True'

# 7. PUT snapshot
CODE="$(curl -sS -o /tmp/smoke_put.$$ -w '%{http_code}' -X PUT "$BASE/sync/snapshot" -H 'Content-Type: application/json' \
  -d '{"events":[{"title":"数据结构","start":"2031-11-03T08:00:00+08:00","end":"2031-11-03T09:40:00+08:00","all_day":false,"location":"45楼B302","notes":"李四","source":"教务课程"}],"generated_at":"2031-11-01T00:00:00Z"}')"
BODY="$(cat /tmp/smoke_put.$$)"; rm -f /tmp/smoke_put.$$
[ "$CODE" = "200" ] && check "PUT snapshot → ok,count=1" "$BODY" 'd["ok"] is True and d["count"]==1' || bad "PUT snapshot" "$CODE $BODY"
R="$(tool list_events '{"start_date":"2031-11-03","end_date":"2031-11-03"}')"
check "list_events 含快照条目 editable=false 且按开始时间排序" "$R" "(lambda x: [e['title'] for e in x['events']][0]=='数据结构' and x['events'][0]['editable'] is False and x['events'][0]['source']=='教务课程' and x['snapshot_updated_at']=='2031-11-01T00:00:00Z')(json.loads(d['result']['content'][0]['text']))"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$BASE/sync/snapshot" -H 'Content-Type: application/json' -d '{"events":"nope"}')"
[ "$CODE" = "400" ] && ok "PUT snapshot 非法 body → 400" || bad "PUT snapshot 非法 body → 400" "$CODE"

# 8. 更新 / 删除 快照条目或未知 id → isError
R="$(tool update_event '{"id":"daily:0","title":"x"}')"
check "update 快照 id → isError" "$R" 'd["result"]["isError"] is True'
R="$(tool update_event '{"id":"00000000-0000-0000-0000-000000000000","title":"x"}')"
check "update 未知 id → isError" "$R" 'd["result"]["isError"] is True'
R="$(tool delete_event '{"id":"00000000-0000-0000-0000-000000000000"}')"
check "delete 未知 id → isError" "$R" 'd["result"]["isError"] is True'

# 9. delete_event
R="$(tool delete_event "{\"id\":\"$ID\"}")"
check "delete_event 成功" "$R" '"isError" not in d["result"]'
tool delete_event "{\"id\":\"$ID2\"}" >/dev/null
R="$(tool list_events '{"start_date":"2031-11-03","end_date":"2031-11-03"}')"
check "删除后 list_events 不再包含" "$R" "not any(e['title'].startswith('$TITLE') for e in json.loads(d['result']['content'][0]['text'])['events'])"

# 10. GET sync/agent-events 含 deleted:true
R="$(curl -sS "$BASE/sync/agent-events")"
check "sync/agent-events 含 deleted:true 的墓碑" "$R" "any(e['id']=='$ID' and e['deleted'] is True for e in d['events']) and 'now' in d"

# 其它 JSON-RPC 行为
R="$(rpc '{"jsonrpc":"2.0","id":9,"method":"nope"}')"
check "未知方法 → -32601" "$R" 'd["error"]["code"]==-32601'
R="$(rpc '{bad json')"
check "坏 JSON → -32700" "$R" 'd["error"]["code"]==-32700'
R="$(rpc '[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]')"
check "批量请求" "$R" 'len(d)==2 and d[0]["result"]=={}'
R="$(tool list_events '{"start_date":"2031-01-01","end_date":"2032-01-01"}')"
check "范围超过 120 天 → isError" "$R" 'd["result"]["isError"] is True'

# 11. 错误密钥 → 404；GET /mcp → 405
CODE="$(curl -sS -o /tmp/smoke_404.$$ -w '%{http_code}' -X POST "$ORIGIN/wrongsecret/mcp" -H 'Content-Type: application/json' -d '{}')"
SZ="$(wc -c < /tmp/smoke_404.$$ | tr -d ' ')"; rm -f /tmp/smoke_404.$$
[ "$CODE" = "404" ] && [ "$SZ" = "0" ] && ok "错误密钥 → 404 空响应" || bad "错误密钥 → 404 空响应" "$CODE size=$SZ"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' "$ORIGIN/")"
[ "$CODE" = "404" ] && ok "根路径 → 404" || bad "根路径 → 404" "$CODE"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/mcp")"
[ "$CODE" = "405" ] && ok "GET /mcp → 405" || bad "GET /mcp → 405" "$CODE"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE/mcp")"
[ "$CODE" = "405" ] && ok "DELETE /mcp → 405" || bad "DELETE /mcp → 405" "$CODE"

# ---- 多个 AI 区分来源（追加检查） ----
muse() { curl -s -X POST "$BASE/mcp/muse" -H 'Content-Type: application/json' -d "$1"; }
grok() { curl -s -X POST "$BASE/mcp" -H 'Content-Type: application/json' -d "$1"; }
r=$(muse '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_event","arguments":{"title":"Muse 测试","start":"2026-12-02 09:00"}}}')
mid=$(printf '%s' "$r" | python3 -c 'import sys,json; print(json.loads(json.load(sys.stdin)["result"]["content"][0]["text"])["id"])')
printf '%s' "$r" | grep -q '\\"source\\":\\"Muse\\"' && echo "PASS  Muse 创建的日程来源为 Muse" || { echo "FAIL  Muse 来源"; exit 1; }
r=$(grok "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"update_event\",\"arguments\":{\"id\":\"$mid\",\"title\":\"x\"}}}")
printf '%s' "$r" | grep -q '"isError":true' && echo "PASS  Grok 不能修改 Muse 的日程" || { echo "FAIL  越权修改"; exit 1; }
r=$(grok '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_events","arguments":{"start_date":"2026-12-02"}}}')
printf '%s' "$r" | grep -q 'Muse 测试' && printf '%s' "$r" | grep -q '\\"editable\\":false' && echo "PASS  Grok 能看到 Muse 的日程（只读）" || { echo "FAIL  可见性"; exit 1; }
r=$(muse "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_event\",\"arguments\":{\"id\":\"$mid\"}}}")
printf '%s' "$r" | grep -q '\\"deleted\\":true' && echo "PASS  Muse 能删除自己的日程" || { echo "FAIL  Muse 删除"; exit 1; }
curl -s "$BASE/sync/agent-events" | grep -q '"client":"muse"' && echo "PASS  同步接口带 client 字段" || { echo "FAIL  client 字段"; exit 1; }

# ---- 短信接收与日历订阅 ----
SECRET="${BASE##*/}"
INGEST="$(printf '%s' "$SECRET:ingest" | shasum -a 256 | cut -c1-32)"
FEED="$(printf '%s' "$SECRET:feed" | shasum -a 256 | cut -c1-32)"
ING="$ORIGIN/ingest/$INGEST/sms"
FEEDURL="$ORIGIN/feed/$FEED/daily.ics"

# ing <text> [received_at]：POST JSON，输出响应体
ing() { python3 -c 'import json,sys; d={"text":sys.argv[1]}; 
if len(sys.argv)>2: d["received_at"]=sys.argv[2]
print(json.dumps(d))' "$@" | curl -sS -X POST "$ING" -H 'Content-Type: application/json' --data-binary @-; }
# evs <起> <止>：Grok 视角 list_events，输出 events 数组 JSON
evs() { tool list_events "{\"start_date\":\"$1\",\"end_date\":\"$2\"}" | inner | py 'json.dumps(d["events"], ensure_ascii=False)'; }
bj() { python3 -c 'import datetime as d,sys; t=d.datetime.now(d.timezone(d.timedelta(hours=8))).date()+d.timedelta(int(sys.argv[1])); print(t.isoformat(), f"{t.month}月{t.day}日")' "$1"; }

read TODAY _ <<<"$(bj 0)"
read D5 D5CN <<<"$(bj 5)"
read D6 D6CN <<<"$(bj 6)"
read D8 D8CN <<<"$(bj 8)"
FROM="$(bj -1 | cut -d' ' -f1)"; TO="$(bj 30 | cut -d' ' -f1)"
CODE="6-2-$((1000 + $$ % 9000))"
ORDER="EH$((10000000 + $$))"

R="$(ing "【菜鸟驿站】您的中通包裹已到天津大学北洋园校区菜鸟驿站，请凭$CODE及时取件，有疑问联系18800000000")"
check "ingest 取件短信 → parsed=pickup" "$R" 'd=={"ok":True,"parsed":"pickup"}'
E="$(evs $FROM $TO)"
check "list_events 含取件条目：来源短信、不可编辑、meta.pickup_code" "$E" "any(e['source']=='短信' and e['editable'] is False and e['kind']=='parcel' and e['meta']['pickup_code']=='$CODE' and e['title'].startswith('取件 $CODE') and not e['all_day'] for e in d)"
ing "【菜鸟驿站】您的中通包裹已到天津大学北洋园校区菜鸟驿站，请凭$CODE及时取件，有疑问联系18800000000" >/dev/null
E="$(evs $FROM $TO)"
check "同一短信投递两次 → 只有一条" "$E" "sum(1 for e in d if e.get('meta',{}).get('pickup_code')=='$CODE')==1"
R="$(ing "【丰巢】您的顺丰包裹已到达天大北洋园45斋丰巢柜，取件码81234567，请于24小时内取件")"
check "丰巢取件短信 → pickup" "$R" 'd["parsed"]=="pickup"'

# Grok 不能改短信条目
SID="$(printf '%s' "$E" | py "[e['id'] for e in d if e.get('meta',{}).get('pickup_code')=='$CODE'][0]")"
R="$(tool update_event "{\"id\":\"$SID\",\"title\":\"x\"}")"
check "Grok 修改短信条目 → isError" "$R" 'd["result"]["isError"] is True and "短信" in d["result"]["content"][0]["text"]'
R="$(curl -sS "$BASE/sync/agent-events")"
check "sync/agent-events 带 client=sms、kind、meta" "$R" "any(e['client']=='sms' and e['kind']=='parcel' and e['meta']['pickup_code']=='$CODE' for e in d['events'])"
R="$(tool delete_event "{\"id\":\"$SID\"}")"
check "AI 可以把取件条目标记为已取（删除）" "$R" '"isError" not in d["result"]'
R="$(curl -sS -X POST "$BASE/mcp/sms" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' -o /dev/null -w '%{http_code}')"
[ "$R" = "404" ] && ok "/mcp/sms 不可作为 AI 身份" || bad "/mcp/sms 不可作为 AI 身份" "$R"

# 已取件 → 条目消失
R="$(ing "【菜鸟驿站】您的包裹$CODE已于10-30 18:20取出，如非本人操作请联系18800000000")"
check "已取出短信 → parsed=picked_up" "$R" 'd["parsed"]=="picked_up"'
E="$(evs $FROM $TO)"
check "取走的包裹条目消失，另一个仍在" "$E" "not any(e.get('meta',{}).get('pickup_code')=='$CODE' for e in d) and any(e.get('meta',{}).get('pickup_code')=='81234567' for e in d)"
ing "【丰巢】您的包裹已被取出，取件码81234567" >/dev/null
ing "【菜鸟驿站】您的中通包裹已到天津大学北洋园校区菜鸟驿站，请凭$CODE及时取件" >/dev/null
E="$(evs $FROM $TO)"
check "无码/有码取出均生效；重复投递到件短信不复活已取走的包裹" "$E" "not any(e.get('kind')=='parcel' for e in d)"

# 火车：购票 → 改签 → 退票
R="$(ing "【铁路客服】订单$ORDER,张三您已购$D5CN""G2564次5车12F号天津南站08:15开，检票口B12，请携带有效身份证件。")"
check "购票短信 → parsed=train" "$R" 'd["parsed"]=="train"'
E="$(evs $FROM $TO)"
check "车票出现：标题/时间/地点/meta" "$E" "any(e['title']=='G2564 天津南' and e['start']=='${D5}T08:15:00+08:00' and e['location']=='天津南站' and e['kind']=='travel' and e['meta']['seat']=='5车12F号' and e['meta']['gate']=='B12' and e['meta']['order']=='$ORDER' and e['source']=='短信' and e['editable'] is False for e in d)"
ing "【铁路客服】订单$ORDER,张三您已购$D5CN""G2564次5车12F号天津南站08:15开，检票口B12，请携带有效身份证件。" >/dev/null
E="$(evs $FROM $TO)"
check "购票短信重复投递 → 一条" "$E" "sum(1 for e in d if e['title']=='G2564 天津南')==1"
R="$(ing "【铁路客服】订单$ORDER,张三您已改签$D6CN""G2566次3车8A号天津南站09:20开，检票口A3。")"
E="$(evs $FROM $TO)"
check "改签：旧车次消失，新车次出现" "$E" "not any(e['title']=='G2564 天津南' for e in d) and any(e['title']=='G2566 天津南' and e['start']=='${D6}T09:20:00+08:00' and e['meta']['seat']=='3车8A号' for e in d)"
R="$(ing "【铁路客服】订单$ORDER,张三您已办理$D6CN""G2566次车票退票，退款50.00元将在1-15日内退回。")"
check "退票短信 → parsed=train_cancel" "$R" 'd["parsed"]=="train_cancel"'
E="$(evs $FROM $TO)"
check "退票后车次消失" "$E" "not any(e.get('kind')=='travel' for e in d)"

# 航班
R="$(ing "【航旅纵横】您预订的$D8CN""MU5101航班，北京首都T2 08:00起飞，预计10:15到达上海虹桥T2，请提前办理值机。")"
check "航班短信 → flight 且标题/起止时间正确" "$R" 'd["parsed"]=="flight"'
E="$(evs $FROM $TO)"
check "航班条目" "$E" "any(e['title']=='MU5101 北京首都→上海虹桥' and e['start']=='${D8}T08:00:00+08:00' and e['end']=='${D8}T10:15:00+08:00' and e['meta']['flight']=='MU5101' for e in d)"

# 无法识别 / 空文本 / text/plain / 非法 body
R="$(ing "【某银行】您的验证码是123456，5分钟内有效")"
check "验证码短信 → parsed=null" "$R" 'd=={"ok":True,"parsed":None}'
R="$(ing "")"
check "空文本 → parsed=null" "$R" 'd=={"ok":True,"parsed":None}'
R="$(curl -sS -X POST "$ING" -H 'Content-Type: text/plain; charset=utf-8' --data-binary "【兔喜生活】快递已到XX小区兔喜超市，取件码3-5-2201，营业时间8:00-21:00")"
check "text/plain body 也能解析" "$R" 'd["parsed"]=="pickup"'
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$ING" -H 'Content-Type: application/json' -d 'not json')"
[ "$CODE" = "400" ] && ok "ingest 非法 JSON → 400" || bad "ingest 非法 JSON → 400" "$CODE"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' "$ING")"
[ "$CODE" = "405" ] && ok "ingest GET → 405" || bad "ingest GET → 405" "$CODE"

# 过期：20 天前的车票，写入时即被标记删除
OLD="$(python3 -c 'import datetime as d; t=d.datetime.now(d.timezone(d.timedelta(hours=8))).date()-d.timedelta(20); print(f"{t.month}月{t.day}日")')"
ing "【铁路客服】订单EH00000001,李四您已购$OLD""D123次1车1A号北京南站07:00开" >/dev/null
R="$(curl -sS "$BASE/sync/agent-events")"
check "过期（结束超过 7 天）的短信条目被标记 deleted" "$R" "any(e.get('meta',{}).get('order')=='EH00000001' and e['deleted'] is True for e in d['events'])"

# 令牌隔离
CODE="$(curl -sS -o /tmp/smoke_ing.$$ -w '%{http_code}' -X POST "$ORIGIN/ingest/0000000000000000000000000000000/sms" -H 'Content-Type: application/json' -d '{"text":"x"}')"
SZ="$(wc -c < /tmp/smoke_ing.$$ | tr -d ' ')"; rm -f /tmp/smoke_ing.$$
[ "$CODE" = "404" ] && [ "$SZ" = "0" ] && ok "错误 ingest 令牌 → 404 空响应" || bad "错误 ingest 令牌 → 404 空响应" "$CODE size=$SZ"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$ORIGIN/ingest/$FEED/sms" -d 'x')"
[ "$CODE" = "404" ] && ok "feed 令牌不能用于 ingest" || bad "feed 令牌不能用于 ingest" "$CODE"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' "$ORIGIN/feed/$INGEST/daily.ics")"
[ "$CODE" = "404" ] && ok "ingest 令牌不能订阅 feed" || bad "ingest 令牌不能订阅 feed" "$CODE"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' "$ORIGIN/ingest/$INGEST/mcp")"
[ "$CODE" = "404" ] && ok "ingest 令牌访问不了其它路径" || bad "ingest 令牌访问不了其它路径" "$CODE"

# 订阅源：先放一个系统日历条目和一个课程条目
curl -sS -X PUT "$BASE/sync/snapshot" -H 'Content-Type: application/json' \
  -d "{\"events\":[{\"title\":\"系统日历牙医\",\"start\":\"${D5}T10:00:00+08:00\",\"all_day\":false,\"source\":\"系统日历 · 个人\"},{\"title\":\"数据结构课\",\"start\":\"${D5}T14:00:00+08:00\",\"end\":\"${D5}T15:40:00+08:00\",\"all_day\":false,\"source\":\"教务课程\"}],\"generated_at\":\"${TODAY}T00:00:00Z\"}" >/dev/null
ing "【铁路客服】订单$ORDER,张三您已购$D5CN""G1234次5车12F号天津南站08:15开，检票口B12，请携带有效身份证件。" >/dev/null
curl -sS -D /tmp/smoke_feed_h.$$ -o /tmp/smoke_feed.$$ "$FEEDURL"
HDR="$(cat /tmp/smoke_feed_h.$$)"; ICS="$(cat /tmp/smoke_feed.$$)"
printf '%s' "$HDR" | grep -qi 'content-type: text/calendar; charset=utf-8' && ok "feed Content-Type" || bad "feed Content-Type" "$HDR"
printf '%s' "$ICS" | head -1 | grep -q 'BEGIN:VCALENDAR' && ok "feed 以 BEGIN:VCALENDAR 开头" || bad "feed 以 BEGIN:VCALENDAR 开头" "$(head -c 200 /tmp/smoke_feed.$$)"
printf '%s' "$ICS" | grep -q 'SUMMARY:G1234 天津南' && ok "feed 含车票" || bad "feed 含车票" "no train"
printf '%s' "$ICS" | grep -q 'SUMMARY:数据结构课' && ok "feed 含非系统日历快照条目（课程）" || bad "feed 含课程" "no course"
printf '%s' "$ICS" | grep -q '系统日历牙医' && bad "feed 不含系统日历条目" "found" || ok "feed 不含系统日历条目"
printf '%s' "$ICS" | grep -q 'DESCRIPTION:5车12F号 · 检票口B12 · 订单' && ok "feed 描述含座位/检票口/订单" || bad "feed DESCRIPTION" "$(grep DESCRIPTION /tmp/smoke_feed.$$)"
python3 - /tmp/smoke_feed.$$ <<'PY' && ok "feed CRLF 行尾、75 字节折行、DTSTART UTC" || bad "feed 格式" "见上"
import sys,re
raw=open(sys.argv[1],'rb').read()
assert raw.endswith(b"\r\n") and b"\n" not in raw.replace(b"\r\n",b""), "CRLF"
for l in raw.split(b"\r\n")[:-1]: assert len(l)<=75, l
assert re.search(rb"DTSTART:\d{8}T\d{6}Z", raw)
assert re.search(rb"UID:[0-9a-f-]+@daily", raw) or b"@daily" in raw
PY
rm -f /tmp/smoke_feed_h.$$ /tmp/smoke_feed.$$
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -I "$FEEDURL")"
[ "$CODE" = "200" ] && ok "feed HEAD → 200" || bad "feed HEAD → 200" "$CODE"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$FEEDURL" -d x)"
[ "$CODE" = "405" ] && ok "feed POST → 405" || bad "feed POST → 405" "$CODE"
CODE="$(curl -sS -o /tmp/smoke_f404.$$ -w '%{http_code}' "$ORIGIN/feed/ffffffffffffffffffffffffffffffff/daily.ics")"
SZ="$(wc -c < /tmp/smoke_f404.$$ | tr -d ' ')"; rm -f /tmp/smoke_f404.$$
[ "$CODE" = "404" ] && [ "$SZ" = "0" ] && ok "错误 feed 令牌 → 404 空响应" || bad "错误 feed 令牌 → 404 空响应" "$CODE size=$SZ"

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" = "0" ]

# ---- Daily 标记已完成（DELETE /sync/agent-events/<id>） ----
R="$(ing '【测试】您的包裹已到删除测试驿站，请凭4-4-4444取件。')"
DID="$(curl -sS "$BASE/sync/agent-events" | py "[e['id'] for e in d['events'] if (e.get('meta') or {}).get('pickup_code')=='4-4-4444' and not e['deleted']][0]")"
R="$(curl -sS -X DELETE "$BASE/sync/agent-events/$DID")"
check "Daily 标记已取件" "$R" 'd["ok"] is True'
R="$(curl -sS -X DELETE "$BASE/sync/agent-events/$DID" -o /dev/null -w '%{http_code}')"
[ "$R" = "404" ] && ok "重复标记返回 404" || bad "重复标记返回 404" "$R"
echo "通过 $PASS，失败 $FAIL"
