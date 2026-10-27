// Pilot scenarios against the local Cloudflare runtime. Usage: node scenarios.mjs <phase>
import WebSocket from "ws";
import fs from "node:fs";
const BASE = process.env.BASE ?? "http://localhost:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
const SAVE = "/tmp/cf-spike/restart-room.json";
const results = [];
const check = (name, pass, detail = "") => { results.push({ name, pass }); console.log(`${pass ? "PASS" : "FAIL"}  ${name}${detail ? "  — " + detail : ""}`); };
const post = async (path, body) => (await fetch(BASE + path, { method: "POST", body: JSON.stringify(body) })).json();
let moveCounter = 0;
const newMoveId = () => `m-${Date.now()}-${moveCounter++}-${Math.random().toString(16).slice(2)}`;

class Player {
  constructor(name, code, token) { Object.assign(this, { name, code, token, inbox: [], waiters: [], raw: [] }); }
  async connect() {
    this.ws = new WebSocket(`${WS_BASE}/rooms/${this.code}/socket`, { headers: { Authorization: `Bearer ${this.token}` } });
    this.ws.on("message", (data) => {
      const text = data.toString(); this.raw.push(text);
      const msg = JSON.parse(text);
      if (msg.type === "snapshot") { this.view = msg.view; this.revision = msg.revision; }
      this.inbox.push(msg); this.waiters = this.waiters.filter((w) => !w(msg));
    });
    await new Promise((resolve, reject) => { this.ws.once("open", resolve); this.ws.once("error", reject); this.ws.once("unexpected-response", (_, res) => reject(new Error("HTTP " + res.statusCode))); });
    return this;
  }
  waitFor(predicate, ms = 5000) {
    const hit = this.inbox.find(predicate);
    if (hit) { this.inbox.splice(this.inbox.indexOf(hit), 1); return Promise.resolve(hit); }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${this.name}: timed out`)), ms);
      this.waiters.push((msg) => { if (!predicate(msg)) return false; clearTimeout(timer); this.inbox.splice(this.inbox.indexOf(msg), 1); resolve(msg); return true; });
    });
  }
  async move(move, { moveId = newMoveId(), baseRevision = this.revision } = {}) {
    const sent = performance.now();
    this.ws.send(JSON.stringify({ type: "move", moveId, baseRevision, move }));
    const result = await this.waitFor((m) => m.type === "result" && m.moveId === moveId);
    result.roundTripMs = performance.now() - sent;
    return result;
  }
  /** Resolves once this player has seen at least `revision` (from a broadcast or a resume). */
  async waitRevision(revision) {
    if (this.revision >= revision) return;
    await this.waitFor((m) => m.type === "snapshot" && m.revision >= revision);
  }
  async resume() { this.ws.send(JSON.stringify({ type: "resume" })); return this.waitFor((m) => m.type === "snapshot" || m.type === "lobby"); }
  close() { this.ws.close(); }
}

async function makeRoom(game, players) {
  const created = await post("/rooms", { game, nickname: "P0" });
  const tokens = [created];
  for (let i = 1; i < players; i++) tokens.push(await post(`/rooms/${created.code}/join`, { nickname: `P${i}` }));
  return { code: created.code, tokens };
}
const board = (p) => p.view?.ticTacToe?._0?.board;

async function ticTacToeScenarios() {
  // Players connect first, then the second join starts the game.
  const created = await post("/rooms", { game: "ticTacToe", nickname: "Ann" });
  check("Create room returns an 8-character invite code and a seat token", /^[0-9A-Z]{8}$/.test(created.code) && created.token?.length === 64, created.code);
  const ann = await new Player("Ann", created.code, created.token).connect();
  const lobby = await ann.resume();
  check("Before the game starts the room reports lobby", lobby.type === "lobby" && lobby.seats === 1);
  const joined = await post(`/rooms/${created.code}/join`, { nickname: "Bob" });
  const bob = await new Player("Bob", created.code, joined.token).connect();
  await ann.waitFor((m) => m.type === "snapshot");
  await bob.resume();
  check("Both players get revision 0 when the room fills", ann.revision === 0 && bob.revision === 0);
  const third = await post(`/rooms/${created.code}/join`, { nickname: "Cat" });
  check("A full, started room refuses more joins", third.error === "alreadyStarted");

  const bad = await new Player("Mallory", created.code, "nope").connect().then(() => "connected", (e) => e.message);
  check("A wrong seat token is refused", bad === "HTTP 401", bad);
  const other = await post("/rooms", { game: "ticTacToe", nickname: "Eve" });
  const cross = await new Player("Eve", created.code, other.token).connect().then(() => "connected", (e) => e.message);
  check("A seat token from room Y can't open room X", cross !== "connected", cross);

  const [x, o] = ann.view.ticTacToe._0.players[0] === "seat0" ? [ann, bob] : [bob, ann];
  let r = await o.move({ ticTacToe: { cell: 4 } });
  check("Moving out of turn is refused", !r.ok && r.error === "notYourTurn", r.error);
  r = await x.move({ ticTacToe: { cell: 9 } });
  check("An out-of-range cell is refused", !r.ok && r.error === "outOfBounds", r.error);
  const firstId = newMoveId();
  r = await x.move({ ticTacToe: { cell: 4 } }, { moveId: firstId });
  check("A valid move commits as revision 1", r.ok && r.revision === 1, `rules ${r.rulesMs?.toFixed(2)} ms, round trip ${r.roundTripMs.toFixed(1)} ms`);
  await o.waitFor((m) => m.type === "snapshot" && m.revision === 1);
  const dupes = await Promise.all(Array.from({ length: 10 }, () => x.move({ ticTacToe: { cell: 4 } }, { moveId: firstId, baseRevision: 0 })));
  check("The same move id sent 10 more times changes nothing and gets the same answer", dupes.every((d) => d.duplicate && d.ok && d.revision === 1));
  await o.resume();
  check("…and the board still has exactly one move", board(o).filter(Boolean).length === 1 && o.revision === 1);
  r = await o.move({ ticTacToe: { cell: 0 } }, { baseRevision: 0 });
  check("A move based on an old revision is refused as stale", !r.ok && r.error === "staleBoard");
  r = await o.move({ ticTacToe: { cell: 4 } });
  check("Playing an occupied cell is refused", !r.ok && r.error === "occupied");

  // Room creator disconnects while it's the other player's turn; the other player moves while
  // the creator is gone; the creator comes back to the current state.
  r = await o.move({ ticTacToe: { cell: 0 } });            // revision 2, X to move
  await x.waitRevision(2);
  if (x === ann) { r = await x.move({ ticTacToe: { cell: 8 } }); await o.waitFor((m) => m.type === "snapshot" && m.revision === 3); } // now O (Bob) to move
  const before = r.revision;
  ann.close();
  await new Promise((s) => setTimeout(s, 300));
  await bob.resume();
  r = await bob.move({ ticTacToe: { cell: x === ann ? 1 : 2 } });
  check("While the room creator is disconnected, the other player's move still commits", r.ok && r.revision === before + 1, r.error ?? `revision ${r.revision}`);
  const annBack = await new Player("Ann", created.code, created.token).connect();
  await annBack.resume();
  check("The room creator returns and gets the current state, including the move made while away", annBack.revision === before + 1 && JSON.stringify(board(annBack)) === JSON.stringify(board(bob)), `revision ${annBack.revision}`);
  const players = { [ann === x ? "x" : "o"]: annBack, [ann === x ? "o" : "x"]: bob };
  // Finish: X takes 4, 1?, 7 column; just play the remaining moves in a fixed order until finished.
  const order = [1, 7, 2, 3, 5, 6, 8];
  let finished = false;
  for (const cell of order) {
    if (finished) break;
    for (const p of [players.x, players.o]) {
      await p.resume();
      const awaiting = p.view.ticTacToe._0;
      if (awaiting.outcome) { finished = true; break; }
      const myTurn = awaiting.players[awaiting.turn === "x" ? 0 : 1] === (p === players.x ? "seat0" : "seat1") || null;
      const res = await p.move({ ticTacToe: { cell } });
      if (res.ok) { const snap = await players.x.waitFor((m) => m.type === "snapshot" && m.revision === res.revision).catch(() => null); finished = !!snap?.finished; break; }
    }
  }
  await players.x.resume(); await players.o.resume();
  check("The game plays to a finish and both players see the same final board", JSON.stringify(board(players.x)) === JSON.stringify(board(players.o)) && !!players.x.view.ticTacToe._0.outcome, JSON.stringify(players.x.view.ticTacToe._0.outcome));
  annBack.close(); bob.close();
}

async function spadesLeakScenario() {
  const { code, tokens } = await makeRoom("spades", 4);
  const players = await Promise.all(tokens.map((t, i) => new Player(`S${i}`, code, t.token).connect()));
  await Promise.all(players.map((p) => p.resume()));
  // Play bids and a few tricks, collecting every message each seat receives.
  for (let step = 0; step < 24; step++) {
    const views = players.map((p) => p.view.spades._0);
    const actor = players.find((p) => p.view.spades._0.currentPlayer === p.view.spades._0.viewer);
    const v = actor.view.spades._0;
    const move = v.phase === "bidding" ? { spades: { _0: { bid: { tricks: 3 } } } } : { spades: { _0: { play: { cardId: v.legalPlays[0] } } } };
    const res = await actor.move(move);
    if (!res.ok) throw new Error("spades move refused: " + res.error);
    await Promise.all(players.map((p) => p.waitFor((m) => m.type === "snapshot" && m.revision === res.revision)));
  }
  let leaks = 0, keysLeaked = 0;
  for (const p of players) {
    const own = new Set(p.view.spades._0.hand.map((c) => c.id));
    for (const q of players) {
      if (q === p) continue;
      const theirs = q.view.spades._0.hand.map((c) => c.id);
      for (const text of p.raw) {
        const msg = JSON.parse(text);
        const handIds = new Set((msg.view?.spades?._0?.hand ?? []).map((c) => c.id));
        leaks += theirs.filter((id) => handIds.has(id) && !own.has(id)).length;
      }
    }
    keysLeaked += p.raw.filter((t) => /"hands"|"deck"|"stock"|"drawPile"/.test(t)).length;
  }
  check("Spades: no seat ever receives another seat's current cards or the full hands", leaks === 0 && keysLeaked === 0, `${players.reduce((n, p) => n + p.raw.length, 0)} messages checked`);
  players.forEach((p) => p.close());
}

async function restartPhase1() {
  const { code, tokens } = await makeRoom("connectFour", 2);
  const [a, b] = await Promise.all(tokens.map((t, i) => new Player(`C${i}`, code, t.token).connect()));
  await a.resume(); await b.resume();
  const first = a.view.connectFour._0.players[0] === "seat0" ? a : b, second = first === a ? b : a;
  for (const [p, col] of [[first, 3], [second, 3], [first, 4], [second, 2]]) {
    const r = await p.move({ connectFour: { column: col } });
    if (!r.ok) throw new Error(r.error);
    await Promise.all([a, b].map((q) => q.waitRevision(r.revision)));
  }
  await a.resume();
  fs.writeFileSync(SAVE, JSON.stringify({ code, tokens, revision: a.revision, view: a.view }));
  console.log(`saved room ${code} at revision ${a.revision}`);
  a.close(); b.close();
}

async function restartPhase2() {
  const saved = JSON.parse(fs.readFileSync(SAVE, "utf8"));
  const a = await new Player("C0", saved.code, saved.tokens[0].token).connect();
  await a.resume();
  check("After the server restarts, committed moves are all still there", a.revision === saved.revision && JSON.stringify(a.view) === JSON.stringify(saved.view), `revision ${a.revision}`);
  const b = await new Player("C1", saved.code, saved.tokens[1].token).connect(); await b.resume();
  let r = await a.move({ connectFour: { column: 0 } });
  if (!r.ok && r.error === "notYourTurn") r = await b.move({ connectFour: { column: 0 } });
  check("…and the game continues from there", r.ok && r.revision === saved.revision + 1, r.error ?? `revision ${r.revision}`);
  a.close(); b.close();
}

async function timing() {
  // Fresh isolate measurement is done by restarting wrangler; here, per-move cost under a warm isolate.
  const { code, tokens } = await makeRoom("chess", 2);
  const [a, b] = await Promise.all(tokens.map((t, i) => new Player(`T${i}`, code, t.token).connect()));
  await a.resume(); await b.resume();
  a.ws.send(JSON.stringify({ type: "stats" }));
  const stats = await a.waitFor((m) => m.type === "stats");
  const white = a.view.chess._0.players[0] === "seat0" ? a : b, black = white === a ? b : a;
  const line = [[12, 28], [52, 36], [6, 21], [57, 42], [5, 26], [62, 45]];
  const trips = [], rules = [];
  for (let i = 0; i < line.length; i++) {
    const p = i % 2 === 0 ? white : black;
    const r = await p.move({ chess: { _0: { move: { from: line[i][0], to: line[i][1] } } } });
    if (!r.ok) throw new Error("chess " + r.error);
    await Promise.all([white, black].map((q) => q.waitRevision(r.revision)));
    trips.push(r.roundTripMs); rules.push(r.rulesMs);
  }
  const avg = (xs) => (xs.reduce((s, x) => s + x, 0) / xs.length).toFixed(2);
  console.log(`TIMING  Swift rules init in this isolate: ${stats.rulesInitMs?.toFixed(1)} ms; chess move: rules ${avg(rules)} ms avg, round trip (commit + broadcast, localhost) ${avg(trips)} ms avg`);
  a.close(); b.close();
}

const phase = process.argv[2] ?? "all";
try {
  if (phase === "all") { await ticTacToeScenarios(); await spadesLeakScenario(); await timing(); }
  if (phase === "restart1") await restartPhase1();
  if (phase === "restart2") await restartPhase2();
} catch (e) { check(`scenario crashed: ${e.message}`, false); }
const failed = results.filter((r) => !r.pass).length;
console.log(`\n${results.length - failed}/${results.length} checks passed`);
process.exit(failed ? 1 : 0);
