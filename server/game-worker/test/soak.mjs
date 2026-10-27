// Soak test: scripted players play every game to the end, concurrently, while their
// connections drop at random. Checks consistency, ordering and hidden information throughout.
//   BASE=https://cruiselan-games.<you>.workers.dev node test/soak.mjs [roomsPerGame] [dropChance]
import WebSocket from "ws";
import fs from "node:fs";
import { createRules } from "../src/rules.js";

const BASE = process.env.BASE ?? "http://localhost:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
const ROOMS_PER_GAME = Number(process.argv[2] ?? 2);
const DROP = Number(process.argv[3] ?? 0.04);
const MAX_MOVES = 600;
const rules = createRules(new WebAssembly.Module(fs.readFileSync(new URL("../src/rules.wasm", import.meta.url))));
const PLAYERS = { ticTacToe: 2, connectFour: 2, checkers: 2, chess: 2, colorMatch: 4, tonk: 3, spades: 4 };
const FIRST = { ticTacToe: "x", connectFour: "red", checkers: "black", chess: "white" };
const sleep = (ms) => new Promise((s) => setTimeout(s, ms));
const api = async (path, body) => (await fetch(BASE + path, { method: "POST", body: JSON.stringify(body) })).json();
const problems = [];
const problem = (room, text) => { problems.push(`${room}: ${text}`); };

export function inner(view) { return Object.values(view)[0]._0; }
export function awaiting(game, view) {
  const s = inner(view);
  if (FIRST[game]) return s.outcome ? null : s.players[s.turn === FIRST[game] ? 0 : 1];
  if (game === "colorMatch") return s.roundResult ? null : (s.drawFourTarget ?? s.currentPlayer);
  if (game === "spades") return s.phase === "handOver" ? null : s.currentPlayer;
  if (game === "tonk") return s.phase === "roundOver" ? null : s.currentPlayer;
}
const finished = (game, view) => awaiting(game, view) === null;

/** Candidate moves for the player who's up, best first. Board games ask the real rules. */
export function candidates(game, view) {
  const s = inner(view);
  const shuffle = (a) => a.map((x) => [Math.random(), x]).sort((p, q) => p[0] - q[0]).map((p) => p[1]);
  if (FIRST[game]) return shuffle(rules.call({ op: "legalMoves", state: view }).moves);
  if (game === "spades") return s.phase === "bidding" ? [{ spades: { _0: { bid: { tricks: 1 + Math.floor(Math.random() * 4) } } } }]
    : shuffle(s.legalPlays).map((id) => ({ spades: { _0: { play: { cardId: id } } } }));
  if (game === "tonk") return s.phase === "mustDraw" ? [{ tonk: { _0: { drawFromStock: {} } } }, { tonk: { _0: { takeDiscard: {} } } }]
    : shuffle(s.hand.filter((c) => c.id !== s.tookDiscardId)).map((c) => ({ tonk: { _0: { discard: { cardId: c.id } } } }));
  if (game === "colorMatch") {
    if (s.drawFourTarget === s.viewer) return [{ colorMatch: { _0: { respondToDrawFour: { challenge: Math.random() < 0.3 } } } }];
    const colors = ["red", "yellow", "green", "blue"];
    const play = (c) => ({ colorMatch: { _0: { play: { cardId: c.id, chosenColor: colors[Math.floor(Math.random() * 4)], callOne: true } } } });
    if (s.drawnCardId != null) return [play({ id: s.drawnCardId }), { colorMatch: { _0: { pass: {} } } }];
    return [...shuffle(s.hand).map(play), { colorMatch: { _0: { draw: {} } } }];
  }
}

class Bot {
  constructor(room, seatInfo) { Object.assign(this, { room, seatInfo, seat: seatInfo.seat, revision: -1, view: null, pending: null, tried: new Set(), drops: 0, refusals: 0, moves: 0, hands: new Map(), done: false }); }
  connect() {
    if (this.done) return;
    this.ws = new WebSocket(`${WS_BASE}/v1/rooms/${this.seatInfo.code}/socket`, { headers: { Authorization: `Bearer ${this.seatInfo.token}` } });
    this.ws.on("open", () => {
      this.ws.send(JSON.stringify({ type: "resume" }));
      // A move whose answer was lost with the old socket: same id, so it can't apply twice.
      if (this.pending) this.ws.send(JSON.stringify({ type: "move", ...this.pending }));
    });
    this.ws.on("message", (d) => this.onMessage(JSON.parse(d)));
    this.ws.on("close", () => { if (!this.done) setTimeout(() => this.connect(), 200 + Math.random() * 1500); });
    this.ws.on("error", () => {});
  }
  chaos() { if (!this.done && Math.random() < DROP && this.ws?.readyState === 1) { this.drops++; this.ws.terminate(); } }
  onMessage(m) {
    if (m.type === "roster") this.room.onRoster(this, m);
    if (m.type === "snapshot") {
      if (m.revision < this.revision) problem(this.room.name, `${this.seat} went back from revision ${this.revision} to ${m.revision}`);
      if (m.revision <= this.revision) return;
      this.revision = m.revision;
      this.view = m.view;
      const s = inner(m.view);
      if (s.viewer !== undefined && s.viewer !== this.seat) problem(this.room.name, `${this.seat} got ${s.viewer}'s view`);
      if (s.hand) this.hands.set(m.revision, s.hand.map((c) => c.id));
      this.room.onSnapshot(this, m.revision, m.view);
      this.tried = new Set();
      this.act();
    }
    if (m.type === "result" && this.pending?.moveId === m.moveId) {
      this.pending = null;
      if (m.ok) { this.moves++; this.room.totalMoves++; }
      else { this.refusals++; if (m.error !== "staleBoard") this.act(); }
    }
  }
  act() {
    if (this.pending || !this.view || this.done) return;
    if (awaiting(this.room.game, this.view) !== this.seat) return;
    if (this.room.totalMoves >= MAX_MOVES) return this.room.finish("move cap");
    const next = candidates(this.room.game, this.view).find((c) => !this.tried.has(JSON.stringify(c)));
    if (!next) return problem(this.room.name, `${this.seat} has no move left to try at revision ${this.revision}`);
    this.tried.add(JSON.stringify(next));
    this.pending = { moveId: crypto.randomUUID(), baseRevision: this.revision, move: next };
    if (this.ws?.readyState === 1) this.ws.send(JSON.stringify({ type: "move", ...this.pending }));
    this.chaos();
  }
}

class Room {
  constructor(game, index) { Object.assign(this, { game, name: `${game}#${index}`, totalMoves: 0, byRevision: new Map(), started: Date.now() }); }
  async run() {
    const count = PLAYERS[this.game];
    const first = await api("/v1/rooms", { game: this.game, nickname: "Soak0" });
    if (!first.code) throw new Error(`${this.name}: create failed ${JSON.stringify(first)}`);
    const seats = [first];
    for (let i = 1; i < count; i++) seats.push(await api(`/v1/rooms/${first.code}/join`, { nickname: `Soak${i}` }));
    this.code = first.code;
    this.bots = seats.map((s) => new Bot(this, s));
    this.bots.forEach((b) => b.connect());
    await new Promise((resolve) => (this.resolve = resolve));
    return this.report();
  }
  onRoster(bot, roster) {
    if (roster.phase === "lobby" && bot.seat === roster.organizer && !this.startSent && roster.players.length === PLAYERS[this.game] && roster.players.every((p) => p.connected)) {
      this.startSent = true;
      bot.ws.send(JSON.stringify({ type: "start" }));
    }
    if (roster.phase === "ended") this.finish(`ended: ${roster.endedMessage}`);
  }
  onSnapshot(bot, revision, view) {
    // Everyone must see the same public game at the same revision.
    const s = inner(view);
    const publicPart = FIRST[this.game] ? JSON.stringify(s)
      : JSON.stringify({ currentPlayer: s.currentPlayer, scores: s.scores, round: s.round, cardCounts: s.cardCounts, phase: s.phase, lastEvent: s.lastEvent });
    const seen = this.byRevision.get(revision);
    if (seen && seen !== publicPart) problem(this.name, `players disagree at revision ${revision}`);
    this.byRevision.set(revision, publicPart);
    if (finished(this.game, view)) this.finish("finished");
  }
  finish(why) {
    if (this.why) return;
    this.why = why;
    setTimeout(() => {
      // Hidden cards: at every revision, no two players held the same card.
      for (const [revision] of this.byRevision) {
        const seen = new Map();
        for (const bot of this.bots) for (const id of bot.hands.get(revision) ?? []) {
          if (seen.has(id)) problem(this.name, `card ${id} in two hands at revision ${revision}`);
          seen.set(id, bot.seat);
        }
      }
      for (const bot of this.bots) { bot.done = true; try { bot.ws.close(); } catch {} }
      this.resolve();
    }, 800);
  }
  report() {
    const drops = this.bots.reduce((n, b) => n + b.drops, 0), refusals = this.bots.reduce((n, b) => n + b.refusals, 0);
    return { name: this.name, why: this.why, moves: this.totalMoves, revisions: this.byRevision.size, drops, refusals, seconds: ((Date.now() - this.started) / 1000).toFixed(1) };
  }
}

if (import.meta.url !== `file://${process.argv[1]}`) { /* imported for its move logic */ } else {
const rooms = Object.keys(PLAYERS).flatMap((game) => Array.from({ length: ROOMS_PER_GAME }, (_, i) => new Room(game, i)));
const t0 = Date.now();
const reports = await Promise.all(rooms.map((r) => r.run().catch((e) => ({ name: r.name, why: `crashed: ${e.message}` }))));
for (const r of reports) console.log(`${r.name.padEnd(14)} ${String(r.why).padEnd(20)} moves ${String(r.moves).padStart(4)}  drops ${String(r.drops).padStart(3)}  refusals ${String(r.refusals).padStart(4)}  ${r.seconds}s`);
const bad = reports.filter((r) => !/^finished|^move cap/.test(r.why));
console.log(`\n${rooms.length} rooms in ${((Date.now() - t0) / 1000).toFixed(0)} s; ${reports.reduce((n, r) => n + (r.moves ?? 0), 0)} moves; ${reports.reduce((n, r) => n + (r.drops ?? 0), 0)} dropped connections`);
console.log(problems.length ? `PROBLEMS (${problems.length}):\n` + problems.slice(0, 20).join("\n") : "No problems: consistent views, ordered revisions, no shared cards.");
process.exit(problems.length || bad.length ? 1 : 0);
}
