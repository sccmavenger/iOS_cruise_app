// A scripted second player for end-to-end tests with the app:
//   node test/bot.mjs <CODE> [--leave-after N]
//   node test/bot.mjs --host [game] [--private]  host a game and start it when someone joins
//   node test/bot.mjs --quickplay [game]   use Quick Play
// Joins the room, then plays Tic-Tac-Toe or Connect Four whenever it's its turn (first free cell),
// and votes for rematches. Reconnects like the app does, and keeps its seat in /tmp so a restarted
// bot rejoins the same seat. Logs every message to stdout.
import WebSocket from "ws";
import fs from "node:fs";
const BASE = process.env.BASE ?? "https://cruiselan-games.dguilloryjr.workers.dev";
const mode = process.argv[2]?.startsWith("--") ? process.argv[2] : "--join";
const code = mode === "--join" ? process.argv[2] : null;
const gameArg = mode === "--join" ? null : process.argv[3] ?? "ticTacToe";
const leaveAfter = process.argv.includes("--leave-after") ? Number(process.argv[process.argv.indexOf("--leave-after") + 1]) : -1;
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const saved = code ? `/tmp/cruiselan-bot-${code}.json` : null;
let seat = saved && fs.existsSync(saved) ? JSON.parse(fs.readFileSync(saved, "utf8")) : null;
if (!seat) {
  const post = (path, body) => fetch(`${BASE}${path}`, { method: "POST", body: JSON.stringify(body) }).then((r) => r.json());
  seat = mode === "--host" ? await post("/v1/rooms", { game: gameArg, nickname: "RoboBob", open: !process.argv.includes("--private") })
    : mode === "--quickplay" ? await post("/v1/quickplay", { game: gameArg, nickname: "RoboBob" })
    : await post(`/v1/rooms/${code}/join`, { nickname: "RoboBob" });
  if (seat.token) fs.writeFileSync(`/tmp/cruiselan-bot-${seat.code}.json`, JSON.stringify(seat));
}
log("seat", JSON.stringify({ seat: seat.seat, game: seat.game, error: seat.error }));
if (!seat.token) process.exit(1);
let revision = -1, moves = 0, waiting = null, ws, leaving = false;
function connect() {
  ws = new WebSocket(`${BASE.replace(/^http/, "ws")}/v1/rooms/${seat.code}/socket`, { headers: { Authorization: `Bearer ${seat.token}` } });
  ws.on("open", () => { log("connected"); ws.send(JSON.stringify({ type: "resume" })); });
  const keepAlive = setInterval(() => ws.readyState === 1 && ws.send("ping"), 25000);
  ws.on("close", () => clearInterval(keepAlive));
  ws.on("unexpected-response", (_, res) => { log("refused", res.statusCode); process.exit(0); });
  ws.on("error", () => {});
  ws.on("close", (c) => {
    log("closed", c);
    if (leaving || c === 4000 || c === 4404) process.exit(0);
    setTimeout(connect, 1000);
  });
  ws.on("message", onMessage);
}
connect();
function onMessage(data) {
  if (data.toString() === "pong") return;
  const m = JSON.parse(data);
  // Hosting: start as soon as someone has joined and connected.
  if (m.type === "roster" && m.phase === "lobby" && m.organizer === seat.seat && m.players.length >= 2 && m.players.every((p) => p.connected)) {
    setTimeout(() => ws.send(JSON.stringify({ type: "start" })), 1500);
  }
  if (m.type === "roster") log("roster", m.phase, m.players.map((p) => `${p.nickname}${p.connected ? "" : "(away)"}`).join(", "), m.endedMessage ?? "", m.rematchVotes.length ? `votes ${m.rematchVotes}` : "");
  if (m.type === "result") log("result", m.ok ? `ok rev ${m.revision}` : m.error);
  if (m.type !== "snapshot" || m.revision <= revision) return;
  revision = m.revision;
  const s = m.view.ticTacToe?._0 ?? m.view.connectFour?._0;
  log("snapshot", revision, m.view.ticTacToe ? s.board.map((c) => c ?? ".").join("") : "", s.outcome ? `outcome ${JSON.stringify(s.outcome)}` : "");
  if (s.outcome) { setTimeout(() => ws.send(JSON.stringify({ type: "rematch" })), 1000); return; }
  const myTurn = s.players[s.turn === "x" || s.turn === "red" ? 0 : 1] === seat.seat;
  if (!myTurn) return;
  if (leaveAfter >= 0 && moves >= leaveAfter) { log("leaving"); leaving = true; ws.send(JSON.stringify({ type: "leave" })); return; }
  clearTimeout(waiting);
  waiting = setTimeout(() => {
    const move = m.view.ticTacToe ? { ticTacToe: { cell: [4, 0, 2, 6, 8, 1, 3, 5, 7].find((c) => s.board[c] === null) } } : { connectFour: { column: 3 } };
    moves++;
    ws.send(JSON.stringify({ type: "move", moveId: crypto.randomUUID(), baseRevision: revision, move }));
  }, 1500);
}
setTimeout(() => { log("time limit"); process.exit(0); }, 15 * 60 * 1000);
