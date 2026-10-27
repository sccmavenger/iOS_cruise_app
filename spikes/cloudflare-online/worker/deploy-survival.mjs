// Do sockets opened before a deploy keep working after it, and which code version serves them?
import WebSocket from "ws";
import { spawnSync } from "node:child_process";
const BASE = process.env.BASE, WS = BASE.replace(/^http/, "ws");
const post = async (path, body) => (await fetch(BASE + path, { method: "POST", body: JSON.stringify(body) })).json();
const sleep = (ms) => new Promise((s) => setTimeout(s, ms));
function open(code, token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS}/rooms/${code}/socket`, { headers: { Authorization: `Bearer ${token}` } });
    const p = { ws, revision: -1, view: null, waiters: [], closed: null };
    ws.on("message", (d) => { const m = JSON.parse(d); if (m.type === "snapshot" && m.revision >= p.revision) { p.revision = m.revision; p.view = m.view; } p.waiters = p.waiters.filter((w) => !w(m)); });
    ws.on("close", (code) => (p.closed = { code, at: Date.now() }));
    ws.on("open", () => resolve(p)); ws.on("error", reject);
  });
}
const ask = (p, msg, type, ms = 8000) => new Promise((resolve) => { const t = setTimeout(() => resolve(null), ms); p.waiters.push((m) => m.type === type && (clearTimeout(t), resolve(m), true)); try { p.ws.send(JSON.stringify(msg)); } catch { resolve(null); } });
const mode = process.argv[2]; // "hibernated" (idle 15 s before deploy) or "active" (deploy right after a move)
const a = await post("/rooms", { game: "connectFour", nickname: "A" }), b = await post(`/rooms/${a.code}/join`, { nickname: "B" });
const [pa, pb] = await Promise.all([open(a.code, a.token), open(a.code, b.token)]);
await ask(pa, { type: "resume" }, "snapshot"); await ask(pb, { type: "resume" }, "snapshot");
const before = await ask(pa, { type: "stats" }, "stats");
console.log(`[${mode}] before deploy: served by version ${before.version}`);
if (mode === "hibernated") await sleep(15000);
const t0 = Date.now();
const d = spawnSync("node", ["node_modules/wrangler/bin/wrangler.js", "deploy"], { env: { ...process.env, WRANGLER_SEND_METRICS: "false" }, encoding: "utf8" });
const newVersion = (d.stdout.match(/Current Version ID: (\S+)/) ?? [])[1];
console.log(`[${mode}] deploy exit ${d.status} in ${((Date.now() - t0) / 1000).toFixed(1)} s; new version ${newVersion}`);
for (let i = 0; i < 6; i++) {
  await sleep(5000);
  const s = await ask(pa, { type: "stats" }, "stats", 4000);
  console.log(`  +${((Date.now() - t0) / 1000).toFixed(0)} s: old socket ${pa.closed ? "CLOSED code " + pa.closed.code : "open"}; stats ${s ? "served by " + (s.version === newVersion ? "NEW version" : s.version === before.version ? "OLD version" : "version " + s.version) : "no answer"}`);
  if (pa.closed) break;
}
const first = pa.view.connectFour._0.players[0] === "seat0" ? pa : pb;
const r = pa.closed ? null : await ask(first, { type: "move", moveId: crypto.randomUUID(), baseRevision: first.revision, move: { connectFour: { column: 3 } } }, "result");
console.log(`  move on a pre-deploy socket: ${r ? (r.ok ? "committed, revision " + r.revision : "refused " + r.error) : "not possible (socket closed)"}`);
pa.ws.close(); pb.ws.close(); process.exit(0);
