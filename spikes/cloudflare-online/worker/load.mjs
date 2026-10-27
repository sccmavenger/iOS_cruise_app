// N concurrent Connect Four rooms, two WebSocket players each, playing until someone wins.
import WebSocket from "ws";
const BASE = "http://localhost:8787", WS = "ws://localhost:8787", ROOMS = Number(process.argv[2] ?? 100);
const post = async (path, body) => (await fetch(BASE + path, { method: "POST", body: JSON.stringify(body) })).json();
function player(code, token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS}/rooms/${code}/socket`, { headers: { Authorization: `Bearer ${token}` } });
    const p = { ws, revision: -1, pending: new Map(), view: null };
    ws.on("message", (d) => { const m = JSON.parse(d); if (m.type === "snapshot") { if (m.revision >= p.revision) { p.revision = m.revision; p.view = m.view; } } if (m.type === "result") p.pending.get(m.moveId)?.(m); });
    ws.on("open", () => resolve(p)); ws.on("error", reject);
  });
}
const send = (p, move) => new Promise((resolve) => { const id = Math.random().toString(36).slice(2); const t = performance.now(); p.pending.set(id, (m) => resolve({ ...m, ms: performance.now() - t })); p.ws.send(JSON.stringify({ type: "move", moveId: id, baseRevision: p.revision, move })); });
async function playRoom(i) {
  const a = await post("/rooms", { game: "connectFour", nickname: "A" }), b = await post(`/rooms/${a.code}/join`, { nickname: "B" });
  const [pa, pb] = await Promise.all([player(a.code, a.token), player(a.code, b.token)]);
  for (const p of [pa, pb]) { p.ws.send(JSON.stringify({ type: "resume" })); }
  await new Promise((s) => setTimeout(s, 200));
  const times = []; let moves = 0, col = i % 7;
  while (moves < 42) {
    const state = pa.view?.connectFour?._0; if (!state || state.outcome) break;
    const mover = state.players[state.turn === "red" ? 0 : 1] === "seat0" ? pa : pb;
    const r = await send(mover, { connectFour: { column: col } });
    times.push(r.ms); col = (col + 3) % 7;
    if (r.ok) { moves++; while (pa.revision < r.revision || pb.revision < r.revision) await new Promise((s) => setTimeout(s, 1)); }
  }
  pa.ws.close(); pb.ws.close();
  return { times, moves };
}
const t0 = performance.now();
const all = await Promise.all(Array.from({ length: ROOMS }, (_, i) => playRoom(i)));
const seconds = (performance.now() - t0) / 1000;
const times = all.flatMap((r) => r.times).sort((x, y) => x - y), moves = all.reduce((n, r) => n + r.moves, 0);
const q = (p) => times[Math.min(times.length - 1, Math.floor(times.length * p))].toFixed(1);
console.log(`${ROOMS} rooms (${ROOMS * 2} sockets): ${moves} committed moves, ${times.length} requests in ${seconds.toFixed(1)} s → ${(times.length / seconds).toFixed(0)} req/s; round trip p50 ${q(.5)} ms, p95 ${q(.95)} ms, p99 ${q(.99)} ms, max ${times.at(-1).toFixed(1)} ms`);
