// 本地测试实时推送：连上 /sync/live，再调用 add_event，期待收到 agent-changed 通知。
const base = process.argv[2] ?? "http://localhost:8787/testsecret";
const ws = new WebSocket(base.replace(/^http/, "ws") + "/sync/live");
const timer = setTimeout(() => { console.log("FAIL: 5 秒内没收到推送"); process.exit(1); }, 5000);
ws.onmessage = (e) => {
  if (e.data === "pong") { console.log("PASS: 心跳 ping → pong"); return; }
  const msg = JSON.parse(e.data);
  if (msg.type === "agent-changed") {
    console.log("PASS: 收到推送", msg.type);
    clearTimeout(timer); ws.close(); process.exit(0);
  }
};
ws.onopen = async () => {
  ws.send("ping");
  await new Promise((r) => setTimeout(r, 300));
  const body = { jsonrpc: "2.0", id: 1, method: "tools/call",
    params: { name: "add_event", arguments: { title: "推送测试", start: "2026-12-01 10:00" } } };
  const resp = await fetch(base + "/mcp", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  console.log("add_event HTTP", resp.status);
};
ws.onerror = (e) => { console.log("FAIL: 连接出错", e.message ?? e); process.exit(1); };
