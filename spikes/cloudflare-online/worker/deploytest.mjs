// Real-Cloudflare tests: hibernation with open sockets, a deploy mid-game, and cold vs warm timing.
import WebSocket from "ws";
import { spawn } from "node:child_process";
const BASE = process.env.BASE, WS = BASE.replace(/^http/, "ws");
const post = async (path, body) => (await fetch(BASE + path, { method: "POST", body: JSON.stringify(body) })).json();
const sleep = (ms) => new Promise((s) => setTimeout(s, ms));
const results = []; const check = (n, p, d = "") => { results.push(p); console.log(`${p ? "PASS" : "FAIL"}  ${n}${d ? "  — " + d : ""}`); };

function open(code, token, name) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS}/rooms/${code}/socket`, { headers: { Authorization: `Bearer ${token}` } });
    const p = { name, ws, revision: -1, view: null, waiters: [], closes: [] };
    ws.on("message", (d) => { const m = JSON.parse(d); if (m.type === "snapshot" && m.revision >= p.revision) { p.revision = m.revision; p.view = m.view; } p.waiters = p.waiters.filter((w) => !w(m)); });
    ws.on("close", (code, reason) => p.closes.push({ code, at: Date.now(), reason: reason.toString() }));
    ws.on("open", () => resolve(p)); ws.on("error", reject);
  });
}
const ask = (p, msg, type) => new Promise((resolve) => { p.waiters.push((m) => m.type === type && (resolve(m), true)); p.ws.send(JSON.stringify(msg)); });
async function move(p, column) {
  const id = crypto.randomUUID(), t = performance.now();
  const r = await ask(p, { type: "move", moveId: id, baseRevision: p.revision, move: { connectFour: { column } } }, "result");
  return { ...r, ms: performance.now() - t };
}
const syncTo = async (ps, rev) => { while (ps.some((p) => p.revision < rev)) await sleep(5); };

const a = await post("/rooms", { game: "connectFour", nickname: "A" }), b = await post(`/rooms/${a.code}/join`, { nickname: "B" });
let [pa, pb] = await Promise.all([open(a.code, a.token, "A"), open(a.code, b.token, "B")]);
await Promise.all([ask(pa, { type: "resume" }, "snapshot"), ask(pb, { type: "resume" }, "snapshot")]);
const first = pa.view.connectFour._0.players[0] === "seat0" ? pa : pb, second = first === pa ? pb : pa;
const warm = [];
for (const [p, c] of [[first, 3], [second, 3], [first, 4]]) { const r = await move(p, c); warm.push(r.ms); await syncTo([pa, pb], r.revision); }
console.log(`warm move round trips: ${warm.map((x) => x.toFixed(0)).join(", ")} ms`);
const before = await ask(pa, { type: "stats" }, "stats");

// 1. Hibernation: leave both sockets idle (no pings), then see if the object was rebuilt.
console.log("idle for 20 s with both sockets open…");
await sleep(20000);
const after = await ask(pa, { type: "stats" }, "stats");
check("Sockets stay open through 20 s of idle", pa.closes.length === 0 && pb.closes.length === 0);
check("The room hibernated while idle (object rebuilt, sockets kept)", after.instanceId !== before.instanceId && after.sockets === 2,
  after.instanceId !== before.instanceId ? "instance changed, so no duration billed while asleep" : "same instance; it stayed in memory");
const r1 = await move(second, 2);
check("After waking, the next move commits normally", r1.ok && r1.revision === 4, `round trip ${r1.ms.toFixed(0)} ms`);
await syncTo([pa, pb], 4);
const savedView = JSON.stringify(pa.view);

// 2. Deploy mid-game.
console.log("deploying a new version while the game is open…");
const t0 = Date.now();
const deploy = spawn("node", ["node_modules/wrangler/bin/wrangler.js", "deploy"], { env: { ...process.env, WRANGLER_SEND_METRICS: "false" }, stdio: ["ignore", "pipe", "pipe"] });
let out = ""; deploy.stdout.on("data", (d) => (out += d)); deploy.stderr.on("data", (d) => (out += d));
const deployed = await new Promise((s) => deploy.on("close", s));
const deployMs = Date.now() - t0;
for (let i = 0; i < 60 && (pa.closes.length === 0 || pb.closes.length === 0); i++) await sleep(500);
check("The deploy finished", deployed === 0, `${(deployMs / 1000).toFixed(1)} s`);
check("The deploy disconnected the open sockets (documented behavior)", pa.closes.length > 0 && pb.closes.length > 0,
  pa.closes.length ? `close code ${pa.closes[0].code}, ${((pa.closes[0].at - t0) / 1000).toFixed(1)} s after the deploy started` : "no close seen");

// 3. Reconnect and resume: cold start of the new version.
const tReconnect = performance.now();
[pa, pb] = await Promise.all([open(a.code, a.token, "A"), open(a.code, b.token, "B")]);
await Promise.all([ask(pa, { type: "resume" }, "snapshot"), ask(pb, { type: "resume" }, "snapshot")]);
const reconnectMs = performance.now() - tReconnect;
check("After the deploy, both players resume to the same committed state", pa.revision === 4 && JSON.stringify(pa.view) === savedView, `reconnect + resume ${reconnectMs.toFixed(0)} ms`);
const next = pa.view.connectFour._0, mover = next.players[next.turn === "red" ? 0 : 1] === "seat0" ? pa : pb;
const cold = await move(mover, 0);
const statsNew = await ask(pa, { type: "stats" }, "stats");
check("The first move on the new version commits", cold.ok && cold.revision === 5, `round trip ${cold.ms.toFixed(0)} ms (rules loaded fresh in this isolate: ${statsNew.isolateId !== before.isolateId})`);
pa.ws.close(); pb.ws.close();
console.log(`\n${results.filter(Boolean).length}/${results.length} checks passed`);
if (!/Deployed|Current Version ID/.test(out)) console.log("deploy output:\n" + out.slice(-800));
process.exit(0);
