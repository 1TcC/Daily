#!/usr/bin/env bash
# 冒烟测试：bash test/smoke.sh [BASE_URL]，默认 http://localhost:8787/testsecret
# 需要先启动：npx wrangler dev --port 8787 --var RELAY_SECRET:testsecret
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

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" = "0" ]
