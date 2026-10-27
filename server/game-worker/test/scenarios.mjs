// End-to-end checks of the v1 protocol. Run against `wrangler dev` (default) or a deployment:
//   node test/scenarios.mjs                       # http://localhost:8787
//   BASE=https://cruiselan-games.<you>.workers.dev node test/scenarios.mjs
//   node test/scenarios.mjs restart1 | restart2   # before / after killing the server
import WebSocket from "ws";
import fs from "node:fs";

const BASE = process.env.BASE ?? "http://localhost:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
const SAVE = "/tmp/cruiselan-games-restart.json";
const results = [];
const check = (name, pass, detail = "") => {
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name}${detail ? "  — " + detail : ""}`);
};
const api = async (path, body) => {
  const response = await fetch(BASE + path, body === undefined ? {} : { method: "POST", body: JSON.stringify(body) });
  return { status: response.status, ...(await response.json()) };
};
const sleep = (ms) => new Promise((s) => setTimeout(s, ms));

class Player {
  constructor(seatInfo, name) { Object.assign(this, seatInfo, { name, inbox: [], waiters: [], raw: [], revision: -1 }); }
  async connect() {
    this.ws = new WebSocket(`${WS_BASE}/v1/rooms/${this.code}/socket`, { headers: { Authorization: `Bearer ${this.token}` } });
    this.ws.on("message", (data) => {
      const text = data.toString();
      if (text === "pong") return;
      this.raw.push(text);
      const msg = JSON.parse(text);
      if (msg.type === "snapshot" && msg.revision >= this.revision) { this.revision = msg.revision; this.view = msg.view; }
      if (msg.type === "roster") this.roster = msg;
      this.inbox.push(msg);
      this.waiters = this.waiters.filter((w) => !w(msg));
    });
    this.closed = null;
    this.ws.on("close", (code) => (this.closed = code));
    await new Promise((resolve, reject) => {
      this.ws.once("open", resolve);
      this.ws.once("unexpected-response", (_, res) => reject(new Error(`HTTP ${res.statusCode}`)));
      this.ws.once("error", reject);
    });
    return this;
  }
  waitFor(predicate, ms = 8000) {
    const hit = this.inbox.find(predicate);
    if (hit) { this.inbox.splice(this.inbox.indexOf(hit), 1); return Promise.resolve(hit); }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${this.name}: timed out waiting`)), ms);
      this.waiters.push((m) => { if (!predicate(m)) return false; clearTimeout(timer); this.inbox.splice(this.inbox.indexOf(m), 1); resolve(m); return true; });
    });
  }
  send(message) { this.ws.send(JSON.stringify(message)); }
  async resume() { this.send({ type: "resume" }); return this.waitFor((m) => m.type === "roster"); }
  async seen(revision) { if (this.revision < revision) await this.waitFor((m) => m.type === "snapshot" && m.revision >= revision); }
  async move(move, { moveId = crypto.randomUUID(), baseRevision = this.revision } = {}) {
    this.send({ type: "move", moveId, baseRevision, move });
    return this.waitFor((m) => m.type === "result" && m.moveId === moveId);
  }
  close() { this.ws.close(); }
}

async function room(game, count, names = ["Ann", "Bob", "Cat", "Dan"]) {
  const created = await api("/v1/rooms", { game, nickname: names[0] });
  const seats = [created];
  for (let i = 1; i < count; i++) seats.push(await api(`/v1/rooms/${created.code}/join`, { nickname: names[i] }));
  const players = await Promise.all(seats.map((s, i) => new Player(s, names[i]).connect()));
  await Promise.all(players.map((p) => p.resume()));
  return players;
}
const startAll = async (players) => {
  players[0].send({ type: "start" });
  await Promise.all(players.map((p) => p.seen(0)));
};
const ttt = (p) => p.view.ticTacToe._0;
const mover = (players) => players.find((p) => GAMES_TURN(p));
const GAMES_TURN = (p) => {
  const s = p.view.ticTacToe?._0 ?? p.view.connectFour?._0;
  return s.players[s.turn === "x" || s.turn === "red" ? 0 : 1] === p.seat;
};

async function basics() {
  const health = await api("/v1/health");
  check("Health check answers with the protocol version", health.ok === true && health.protocol === 1);
  const bad = await api("/v1/rooms", { game: "poker", nickname: "X" });
  check("Unknown game is refused", bad.status === 400);

  const created = await api("/v1/rooms", { game: "ticTacToe", nickname: "Ann\n\u0007" });
  check("Create returns an 8-character code and a seat token", /^[0-9A-Z]{8}$/.test(created.code) && created.token.length === 64 && created.seat === "seat0");
  const ann = await new Player(created, "Ann").connect();
  let roster = await ann.resume();
  check("Lobby roster: organizer, one connected player, cleaned nickname", roster.phase === "lobby" && roster.organizer === "seat0" && roster.players.length === 1 && roster.players[0].connected && roster.players[0].nickname === "Ann");
  ann.send({ type: "start" });
  const early = await ann.waitFor((m) => m.type === "error");
  check("Starting with too few players is refused", early.error === "notEnoughPlayers");

  const typed = created.code.toLowerCase().slice(0, 4) + "-" + created.code.toLowerCase().slice(4);
  const joined = await api(`/v1/rooms/${typed}/join`, { nickname: "Bob" });
  check("Joining accepts a lowercase code with a dash", joined.status === 200 && joined.seat === "seat1");
  roster = await ann.waitFor((m) => m.type === "roster" && m.players.length === 2);
  check("The organizer sees the new player arrive (not yet connected)", roster.players[1].nickname === "Bob" && !roster.players[1].connected);
  const bob = await new Player(joined, "Bob").connect();
  await bob.resume();
  roster = await ann.waitFor((m) => m.type === "roster" && m.players.every((p) => p.connected));
  check("…and then sees them connect", true);
  bob.send({ type: "start" });
  const notOrganizer = await bob.waitFor((m) => m.type === "error");
  check("Only the organizer can start", notOrganizer.error === "notAllowed");
  const full = await api(`/v1/rooms/${created.code}/join`, { nickname: "Cat" });
  check("A full lobby refuses another join", full.status === 409 && full.error === "full");

  await startAll([ann, bob]);
  check("Starting sends both players revision 0", ann.revision === 0 && bob.revision === 0);
  const late = await api(`/v1/rooms/${created.code}/join`, { nickname: "Cat" });
  check("A started game refuses joins", late.status === 409 && late.error === "alreadyStarted");
  const unknown = await api("/v1/rooms/ZZZZZZZZ/join", { nickname: "Cat" });
  check("An unknown code is not found", unknown.status === 404);
  const wrongToken = await new Player({ ...created, token: "0".repeat(64) }, "Eve").connect().then(() => "connected", (e) => e.message);
  check("A wrong seat token can't open the room", wrongToken === "HTTP 401", wrongToken);

  const [x, o] = ttt(ann).players[0] === "seat0" ? [ann, bob] : [bob, ann];
  let r = await o.move({ ticTacToe: { cell: 4 } });
  check("Out-of-turn move refused with the rules' message", !r.ok && r.error === "notYourTurn" && r.message === "It's not your turn.");
  r = await x.move({ ticTacToe: { cell: 42 } });
  check("Out-of-range move refused", !r.ok && r.error === "outOfBounds");
  r = await x.move({ connectFour: { column: 1 } });
  check("A move for the wrong game is refused", !r.ok && r.error === "wrongGame");
  const id = crypto.randomUUID();
  r = await x.move({ ticTacToe: { cell: 4 } }, { moveId: id });
  check("A valid move commits as revision 1", r.ok && r.revision === 1);
  await o.seen(1);
  const dupes = await Promise.all(Array.from({ length: 5 }, () => x.move({ ticTacToe: { cell: 0 } }, { moveId: id, baseRevision: 0 })));
  check("Resending the same move id changes nothing and repeats the answer", dupes.every((d) => d.duplicate && d.ok && d.revision === 1));
  r = await o.move({ ticTacToe: { cell: 0 } }, { baseRevision: 0 });
  check("A move based on an old turn is refused as stale", !r.ok && r.error === "staleBoard");
  r = await o.move({ ticTacToe: { cell: 4 } });
  check("An occupied square is refused", !r.ok && r.error === "occupied");

  // Play to a win: X takes 4, 0? Build a quick line X: 4, 1, 7 ; O: 0, 2.
  for (const [p, cell] of [[o, 0], [x, 1], [o, 2], [x, 7]]) {
    r = await p.move({ ticTacToe: { cell } });
    if (!r.ok) throw new Error(`move ${cell}: ${r.error}`);
    await Promise.all([ann, bob].map((q) => q.seen(r.revision)));
  }
  check("Plays to a win that both players see", JSON.stringify(ttt(ann)) === JSON.stringify(ttt(bob)) && ttt(ann).outcome?.win?._0 === "x");

  // Rematch: both must vote.
  x.send({ type: "rematch" });
  roster = await o.waitFor((m) => m.type === "roster" && m.rematchVotes.length === 1);
  check("A rematch vote is shared with the other player", roster.rematchVotes[0] === x.seat);
  o.send({ type: "rematch" });
  await Promise.all([ann, bob].map((q) => q.seen(6)));
  check("When everyone votes, a new round starts (revision 6, empty board)", ttt(ann).board.every((c) => c === null) && ann.revision === 6);

  // Organizer disconnects mid-game: the game goes on and they come back to the current state.
  const [annX, other] = [ann, bob];
  annX.close();
  roster = await other.waitFor((m) => m.type === "roster" && m.players.some((p) => !p.connected));
  check("When the organizer drops, the other player sees them as away", roster.players.find((p) => p.seat === annX.seat).connected === false);
  const nextMover = [ann, bob].find((p) => GAMES_TURN(p));
  if (nextMover === bob) { r = await bob.move({ ticTacToe: { cell: 4 } }); check("The other player can still move while the organizer is away", r.ok, `revision ${r.revision}`); }
  else check("The other player can still move while the organizer is away", true, "(organizer's turn; nothing to play)");
  const annBack = await new Player(created, "Ann").connect();
  await annBack.resume();
  await annBack.seen(bob.revision);
  check("The organizer comes back to exactly the current state", annBack.revision === bob.revision && JSON.stringify(ttt(annBack)) === JSON.stringify(ttt(bob)));

  // Leaving mid-game ends it for everyone, with a reason.
  bob.send({ type: "leave" });
  roster = await annBack.waitFor((m) => m.type === "roster" && m.phase === "ended");
  check("A player leaving mid-game ends the match for everyone", roster.endedMessage === "Bob left the game. The match has ended.");
  await sleep(300);
  check("The leaver's socket is closed", bob.closed !== null);
  const rejoin = await new Player(joined, "Bob").connect().then(() => "connected", (e) => e.message);
  check("A seat that left can't reconnect", rejoin === "HTTP 410", rejoin);
  annBack.close();
}

async function lobbyHandover() {
  const players = await room("colorMatch", 3);
  const [ann, bob, cat] = players;
  ann.send({ type: "leave" });
  const roster = await bob.waitFor((m) => m.type === "roster" && m.organizer !== "seat0");
  check("If the organizer leaves the lobby, the next player becomes host", roster.organizer === bob.seat && roster.players.length === 2);
  bob.send({ type: "start" });
  await Promise.all([bob, cat].map((p) => p.seen(0)));
  check("…and can start the game", bob.view.colorMatch._0.players.length === 2);
  players.forEach((p) => p.close());
}

async function turnIndependent() {
  const players = await room("chess", 2);
  await startAll(players);
  const white = players.find((p) => p.view.chess._0.players[0] === p.seat), black = players.find((p) => p !== white);
  let r = await white.move({ chess: { _0: { move: { from: 12, to: 28 } } } });
  await black.seen(r.revision);
  r = await black.move({ chess: { _0: { move: { from: 52, to: 36 } } } });
  await white.seen(r.revision);
  r = await white.move({ chess: { _0: { resign: {} } } }, { baseRevision: 0 });
  check("Resigning is accepted even from an old view (turn-independent)", r.ok, r.error ?? "");
  players.forEach((p) => p.close());
}

async function hiddenCards() {
  const players = await room("spades", 4);
  await startAll(players);
  for (let step = 0; step < 24; step++) {
    const actor = players.find((p) => p.view.spades._0.currentPlayer === p.seat);
    const v = actor.view.spades._0;
    const r = await actor.move(v.phase === "bidding" ? { spades: { _0: { bid: { tricks: 3 } } } } : { spades: { _0: { play: { cardId: v.legalPlays[0] } } } });
    if (!r.ok) throw new Error("spades " + r.error);
    await Promise.all(players.map((p) => p.seen(r.revision)));
  }
  let leaked = 0, keys = 0;
  for (const p of players) {
    const others = new Set(players.filter((q) => q !== p).flatMap((q) => q.view.spades._0.hand.map((c) => c.id)));
    for (const text of p.raw) {
      const msg = JSON.parse(text);
      leaked += (msg.view?.spades?._0?.hand ?? []).filter((c) => others.has(c.id)).length;
      if (/"hands"|"stock"|"drawPile"/.test(text)) keys++;
    }
  }
  check("Spades: nobody ever receives another player's cards or the deck", leaked === 0 && keys === 0, `${players.reduce((n, p) => n + p.raw.length, 0)} messages checked`);
  players.forEach((p) => p.close());
}

async function restart1() {
  const players = await room("connectFour", 2);
  await startAll(players);
  for (const column of [3, 3, 4, 2]) {
    const p = mover(players);
    const r = await p.move({ connectFour: { column } });
    if (!r.ok) throw new Error(r.error);
    await Promise.all(players.map((q) => q.seen(r.revision)));
  }
  fs.writeFileSync(SAVE, JSON.stringify({ seats: players.map((p) => ({ code: p.code, seat: p.seat, token: p.token })), revision: players[0].revision, view: players[0].view }));
  console.log(`saved room ${players[0].code} at revision ${players[0].revision}`);
  players.forEach((p) => p.close());
}

async function restart2() {
  const saved = JSON.parse(fs.readFileSync(SAVE, "utf8"));
  const players = await Promise.all(saved.seats.map((s, i) => new Player(s, `P${i}`).connect()));
  await Promise.all(players.map((p) => p.resume()));
  await players[0].seen(saved.revision);
  check("After a restart, every committed move is still there", players[0].revision === saved.revision && JSON.stringify(players[0].view) === JSON.stringify(saved.view));
  const r = await mover(players).move({ connectFour: { column: 0 } });
  check("…and the game continues", r.ok && r.revision === saved.revision + 1);
  players.forEach((p) => p.close());
}

/** Slow (80 s): a phone that goes silent without closing shows as away; one that pings doesn't. */
async function presence() {
  const [silent, pinger] = await room("ticTacToe", 2);
  const keepAlive = setInterval(() => pinger.ws.send("ping"), 20000);
  pinger.ws.on("message", () => {}); // "pong" replies are plain text and skipped by the parser below
  await sleep(80000);
  clearInterval(keepAlive);
  pinger.inbox = []; // only the roster sent in reply to this resume counts
  const roster = await pinger.resume();
  const bySeat = Object.fromEntries(roster.players.map((p) => [p.seat, p.connected]));
  check("A seat that pings stays connected; one silent for 75 s shows as away", bySeat[pinger.seat] === true && bySeat[silent.seat] === false, JSON.stringify(roster.players));
  silent.close(); pinger.close();
}

const phase = process.argv[2] ?? "all";
try {
  if (phase === "all") { await basics(); await lobbyHandover(); await turnIndependent(); await hiddenCards(); }
  if (phase === "restart1") await restart1();
  if (phase === "restart2") await restart2();
  if (phase === "presence") await presence();
} catch (error) {
  check(`crashed: ${error.message}`, false);
}
const failed = results.filter((r) => !r).length;
console.log(`\n${results.length - failed}/${results.length} checks passed`);
process.exit(failed ? 1 : 0);
