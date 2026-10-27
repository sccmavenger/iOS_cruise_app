// CruiseLAN online-games spike: one Durable Object per room, Swift rules compiled to WebAssembly.
import { DurableObject } from "cloudflare:workers";
import rulesModule from "./rules.wasm";
import { createRules } from "./rules.js";

// One rules instance per isolate, created on first use, so cold-start cost is measurable.
let rules = null, rulesInitMs = null;
function getRules() {
  if (!rules) { const t = performance.now(); rules = createRules(rulesModule); rulesInitMs = performance.now() - t; }
  return rules;
}

const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford base32
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const randomHex = (n) => [...crypto.getRandomValues(new Uint8Array(n))].map((b) => b.toString(16).padStart(2, "0")).join("");
async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
const MAX_SEATS = { ticTacToe: 2, connectFour: 2, checkers: 2, chess: 2, colorMatch: 4, tonk: 4, spades: 4 };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean); // rooms/:code/(join|socket)
    if (request.method === "POST" && url.pathname === "/rooms") {
      const { game, nickname, seats } = await request.json();
      if (!MAX_SEATS[game]) return json({ error: "unknownGame" }, 400);
      const code = [...crypto.getRandomValues(new Uint8Array(8))].map((b) => CODE_ALPHABET[b & 31]).join("");
      const stub = env.ROOMS.get(env.ROOMS.idFromName(code));
      return stub.fetch("https://room/create", { method: "POST", body: JSON.stringify({ code, game, nickname, seats: seats ?? MAX_SEATS[game] }) });
    }
    if (parts[0] === "rooms" && parts[1] && /^[0-9A-Z]{8}$/.test(parts[1])) {
      const stub = env.ROOMS.get(env.ROOMS.idFromName(parts[1]));
      if (parts[2] === "join" && request.method === "POST") return stub.fetch("https://room/join", { method: "POST", body: await request.text() });
      if (parts[2] === "socket") return stub.fetch(new Request("https://room/socket", request));
    }
    return json({ error: "notFound" }, 404);
  },
};

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS room (id INTEGER PRIMARY KEY CHECK (id = 1), code TEXT, game TEXT, phase TEXT, max_seats INTEGER, created_at INTEGER, updated_at INTEGER);
      CREATE TABLE IF NOT EXISTS seats (seat TEXT PRIMARY KEY, idx INTEGER, nickname TEXT, token_hash TEXT UNIQUE);
      CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT, revision INTEGER);
      CREATE TABLE IF NOT EXISTS moves (move_id TEXT PRIMARY KEY, seat TEXT, revision INTEGER, move TEXT, outcome TEXT, at INTEGER);
    `);
  }

  room() { return this.sql.exec("SELECT * FROM room WHERE id = 1").toArray()[0]; }
  seats() { return this.sql.exec("SELECT seat, idx, nickname FROM seats ORDER BY idx").toArray(); }
  current() { return this.sql.exec("SELECT json, revision FROM state WHERE id = 1").toArray()[0]; }

  async addSeat(nickname) {
    const seats = this.seats(), seat = `seat${seats.length}`, token = randomHex(32);
    this.sql.exec("INSERT INTO seats (seat, idx, nickname, token_hash) VALUES (?, ?, ?, ?)", seat, seats.length, String(nickname ?? "Player").slice(0, 20), await sha256(token));
    return { seat, token };
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/create") {
      if (this.room()) return json({ error: "codeCollision" }, 409);
      const { code, game, nickname, seats } = await request.json();
      const now = Date.now();
      this.sql.exec("INSERT INTO room VALUES (1, ?, ?, 'lobby', ?, ?, ?)", code, game, seats, now, now);
      const { seat, token } = await this.addSeat(nickname);
      await this.ctx.storage.setAlarm(now + 24 * 3600 * 1000); // lobby expiry
      return json({ code, seat, token });
    }
    if (url.pathname === "/join") {
      const room = this.room();
      if (!room) return json({ error: "notFound" }, 404);
      if (room.phase !== "lobby") return json({ error: "alreadyStarted" }, 409);
      const { nickname } = await request.json();
      const { seat, token } = await this.addSeat(nickname);
      if (this.seats().length === room.max_seats) this.start();
      return json({ code: room.code, seat, token });
    }
    if (url.pathname === "/socket") {
      if (request.headers.get("Upgrade") !== "websocket") return json({ error: "expectedWebSocket" }, 426);
      const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer /, "");
      const row = this.sql.exec("SELECT seat FROM seats WHERE token_hash = ?", await sha256(token)).toArray()[0];
      if (!row) return json({ error: "badToken" }, 401);
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1], [row.seat]); // hibernation API; the tag is the seat
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    return json({ error: "notFound" }, 404);
  }

  start() {
    const room = this.room(), seats = this.seats().map((s) => s.seat);
    const t = performance.now();
    const result = getRules().call({ op: "new", game: room.game, seats });
    const ms = performance.now() - t;
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("INSERT INTO state VALUES (1, ?, 0)", JSON.stringify(result.state));
      this.sql.exec("UPDATE room SET phase = 'playing', updated_at = ? WHERE id = 1", Date.now());
    });
    this.broadcast(result.views, 0, { rulesMs: ms });
  }

  broadcast(views, revision, extra = {}) {
    for (const ws of this.ctx.getWebSockets()) {
      const [seat] = this.ctx.getTags(ws);
      // Each socket gets only its own seat's projection.
      ws.send(JSON.stringify({ type: "snapshot", revision, view: views[seat], ...extra }));
    }
  }

  async webSocketMessage(ws, message) {
    const [seat] = this.ctx.getTags(ws);
    let msg;
    try { msg = JSON.parse(message); } catch { return ws.send(JSON.stringify({ type: "error", error: "badJSON" })); }
    if (msg.type === "resume") return this.sendCurrent(ws, seat);
    if (msg.type === "stats") return ws.send(JSON.stringify({ type: "stats", rulesInitMs, isolateHasRules: rules !== null }));
    if (msg.type === "move") return this.handleMove(ws, seat, msg);
    ws.send(JSON.stringify({ type: "error", error: "unknownType" }));
  }

  sendCurrent(ws, seat) {
    const room = this.room(), current = this.current();
    if (!current) return ws.send(JSON.stringify({ type: "lobby", phase: room?.phase, seats: this.seats().length, of: room?.max_seats }));
    ws.send(JSON.stringify({ type: "snapshot", revision: current.revision, view: this.projectionFor(current.json, seat), finished: room.phase === "finished" }));
  }

  projectionFor(stateJson, seat) {
    const out = getRules().call({ op: "views", state: JSON.parse(stateJson) });
    return out.views?.[seat];
  }

  handleMove(ws, seat, { moveId, baseRevision, move }) {
    if (typeof moveId !== "string" || moveId.length > 64) return ws.send(JSON.stringify({ type: "error", error: "badMoveId" }));
    // Exactly-once: a retried move id gets its original answer and changes nothing.
    const seen = this.sql.exec("SELECT outcome, revision FROM moves WHERE move_id = ?", moveId).toArray()[0];
    if (seen) return ws.send(JSON.stringify({ type: "result", moveId, duplicate: true, ...JSON.parse(seen.outcome) }));
    const current = this.current();
    if (!current) return ws.send(JSON.stringify({ type: "result", moveId, ok: false, error: "notStarted" }));
    const record = (outcome, revision) => this.sql.exec("INSERT INTO moves VALUES (?, ?, ?, ?, ?, ?)", moveId, seat, revision, JSON.stringify(move), JSON.stringify(outcome), Date.now());
    if (baseRevision !== current.revision) {
      const outcome = { ok: false, error: "staleBoard", revision: current.revision };
      record(outcome, current.revision);
      return ws.send(JSON.stringify({ type: "result", moveId, ...outcome }));
    }
    const t = performance.now();
    const result = getRules().call({ op: "apply", state: JSON.parse(current.json), seat, move });
    const rulesMs = performance.now() - t;
    if (!result.ok) {
      const outcome = { ok: false, error: result.error, message: result.message, revision: current.revision };
      record(outcome, current.revision);
      return ws.send(JSON.stringify({ type: "result", moveId, rulesMs, ...outcome }));
    }
    const next = current.revision + 1;
    // Commit before telling anyone. The revision check makes a lost race impossible to miss.
    this.ctx.storage.transactionSync(() => {
      const updated = this.sql.exec("UPDATE state SET json = ?, revision = ? WHERE id = 1 AND revision = ?", JSON.stringify(result.state), next, current.revision).rowsWritten;
      if (updated !== 1) throw new Error("revision race");
      record({ ok: true, revision: next }, next);
      this.sql.exec("UPDATE room SET updated_at = ?, phase = ? WHERE id = 1", Date.now(), result.finished ? "finished" : "playing");
    });
    ws.send(JSON.stringify({ type: "result", moveId, ok: true, revision: next, rulesMs }));
    this.broadcast(result.views, next, { finished: result.finished });
  }

  async alarm() {
    const room = this.room();
    if (room && Date.now() - room.updated_at > 24 * 3600 * 1000) await this.ctx.storage.deleteAll();
  }
}
