// A scripted partner for testing the app by hand or in the simulator. Plays any game.
//   node test/partner.mjs --host GAME [--private] [--bots N] [--kick-after S]
//   node test/partner.mjs --join CODE [--leave-after-moves N]
// --bots N: N more scripted players join too (for 3-4 player games).
// --kick-after S: as host, remove the first non-scripted player S seconds after they join.
import WebSocket from "ws";
import { awaiting, candidates } from "./soak.mjs";

const BASE = process.env.BASE ?? "https://cruiselan-games.dguilloryjr.workers.dev";
const arg = (name, fallback) => (process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : fallback);
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const api = async (path, body) => (await fetch(BASE + path, { method: "POST", body: JSON.stringify(body) })).json();
const names = ["RoboBob", "RoboCat", "RoboDan"];
const botSeats = new Set();

function play(seatInfo, name, { isHost, expected }) {
  let revision = -1, view = null, pending = null, tried = new Set(), roster = null, moves = 0, kicked = false;
  const game = seatInfo.game;
  const leaveAfter = Number(arg("--leave-after-moves", -1));
  const kickAfter = Number(arg("--kick-after", -1));
  const connect = () => {
    const ws = new WebSocket(`${BASE.replace(/^http/, "ws")}/v1/rooms/${seatInfo.code}/socket`, { headers: { Authorization: `Bearer ${seatInfo.token}` } });
    ws.on("open", () => { ws.send(JSON.stringify({ type: "resume" })); setInterval(() => ws.readyState === 1 && ws.send("ping"), 25000); });
    ws.on("close", (c) => { log(name, "closed", c); if (c !== 4000 && c !== 4001) setTimeout(connect, 1000); });
    ws.on("error", () => {});
    ws.on("unexpected-response", (_, r) => { log(name, "refused", r.statusCode); process.exit(0); });
    ws.on("message", (d) => {
      if (d.toString() === "pong") return;
      const m = JSON.parse(d);
      if (m.type === "roster") {
        roster = m;
        log(name, "roster", m.phase, m.players.map((p) => p.nickname + (p.connected ? "" : "(away)")).join(", "), m.endedMessage ?? "");
        const humans = m.players.filter((p) => !botSeats.has(p.seat));
        if (isHost && m.phase === "lobby" && kickAfter >= 0 && humans.length && !kicked) {
          kicked = true;
          setTimeout(() => { log(name, "removing", humans[0].nickname); ws.send(JSON.stringify({ type: "kick", seat: humans[0].seat })); }, kickAfter * 1000);
        } else if (isHost && kickAfter < 0 && m.phase === "lobby" && m.players.length >= expected && m.players.every((p) => p.connected)) {
          setTimeout(() => ws.send(JSON.stringify({ type: "start" })), 1500);
        }
        if (m.phase === "ended") log(name, "game over:", m.endedMessage);
      }
      if (m.type === "result" && pending?.moveId === m.moveId) {
        pending = null;
        if (m.ok) moves++; else if (m.error !== "staleBoard") setTimeout(act, 300);
      }
      if (m.type === "snapshot" && m.revision > revision) {
        revision = m.revision; view = m.view; tried = new Set();
        if (awaiting(game, view) === null) {
          log(name, "round over at revision", revision);
          setTimeout(() => ws.send(JSON.stringify({ type: "rematch" })), 1500);
        }
        setTimeout(act, 1200);
      }
    });
    const act = () => {
      if (pending || !view || awaiting(game, view) !== seatInfo.seat) return;
      if (leaveAfter >= 0 && moves >= leaveAfter) { log(name, "leaving"); ws.send(JSON.stringify({ type: "leave" })); return; }
      const next = candidates(game, view).find((c) => !tried.has(JSON.stringify(c)));
      if (!next) return;
      tried.add(JSON.stringify(next));
      pending = { moveId: crypto.randomUUID(), baseRevision: revision, move: next };
      ws.send(JSON.stringify({ type: "move", ...pending }));
    };
  };
  connect();
}

const mode = process.argv[2];
if (mode === "--host") {
  const game = process.argv[3];
  const host = await api("/v1/rooms", { game, nickname: names[0], open: !process.argv.includes("--private") });
  botSeats.add(host.seat);
  const extra = Number(arg("--bots", 0));
  const helpers = [];
  for (let i = 0; i < extra; i++) { const s = await api(`/v1/rooms/${host.code}/join`, { nickname: names[i + 1] }); botSeats.add(s.seat); helpers.push(s); }
  const expected = Number(arg("--players", extra + 2));
  log("hosting", game, "code", host.code, `(${process.argv.includes("--private") ? "private" : "open"}), starts at ${expected} players`);
  play(host, names[0], { isHost: true, expected });
  helpers.forEach((s, i) => play(s, names[i + 1], { isHost: false }));
} else if (mode === "--join") {
  const seat = await api(`/v1/rooms/${process.argv[3]}/join`, { nickname: names[0] });
  log("joined", JSON.stringify({ seat: seat.seat, game: seat.game, error: seat.error }));
  if (seat.token) play(seat, names[0], { isHost: false });
}
setTimeout(() => process.exit(0), 20 * 60 * 1000);
