// CruiseLAN online games: one Durable Object per room. The game rules are the app's own Swift
// rules compiled to WebAssembly (see build-rules.sh), so online and offline games behave the same.
//
// HTTP
//   GET  /v1/health                      → { ok, protocol }
//   POST /v1/rooms        { game, nickname, open? }  → { code, seat, token, game, maxSeats }
//        open: true lists the game for everyone (default false, private: code only)
//   POST /v1/rooms/:code/join { nickname }    → same
//   GET  /v1/lobbies[?game=]              → { lobbies: [{ code, game, host, seats, maxSeats }] } (open games)
//   POST /v1/quickplay    { game, nickname, avoid? } → seat in the longest-waiting open game, or a new one
//   GET  /v1/rooms/:code/socket  (Authorization: Bearer <token>, WebSocket upgrade)
//
// WebSocket, client → server
//   { type: "resume" }                      roster + current snapshot
//   { type: "start" }                       organizer starts the game
//   { type: "move", moveId, baseRevision, move }
//   { type: "rematch" } | { type: "leave" } | { type: "ping", t }
//   { type: "kick", seat }                  organizer removes a player before the game starts
//   "ping" (plain text, every 25 s): answered "pong" by Cloudflare without waking the room; it keeps
//   the seat marked as connected
// server → client
//   { type: "roster", ... } | { type: "snapshot", revision, view } |
//   { type: "result", moveId, ok, revision, error?, message?, duplicate? } |
//   { type: "pong", t } | { type: "error", error }
import { DurableObject } from "cloudflare:workers";
import rulesModule from "./rules.wasm";
import { createRules } from "./rules.js";

const PROTOCOL = 1;

const GAMES = {
  ticTacToe: { min: 2, max: 2 }, connectFour: { min: 2, max: 2 }, checkers: { min: 2, max: 2 }, chess: { min: 2, max: 2 },
  colorMatch: { min: 2, max: 4 }, tonk: { min: 2, max: 4 }, spades: { min: 4, max: 4 },
};
const HOUR = 3600 * 1000, DAY = 24 * HOUR;
// Retention, matching the privacy policy: unused lobbies 24 h, games 7 days after the last
// move, ended games 30 days.
const TTL = { lobby: DAY, playing: 7 * DAY, ended: 30 * DAY };
const MAX_MESSAGE_BYTES = 16 * 1024;
// A socket counts as connected only if it said something recently. Clients send "ping" every
// 25 s; Cloudflare answers "pong" itself without waking the room. A phone that vanished without
// closing (dead battery, lost signal) shows as away after this long.
const PRESENCE_TIMEOUT = 75 * 1000;
const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford base32, no I L O U

let rules = null;
const getRules = () => (rules ??= createRules(rulesModule));

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
const randomHex = (bytes) => [...crypto.getRandomValues(new Uint8Array(bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");
async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
/** Accepts "abcd-efgh", "ABCDEFGH", and the usual Crockford look-alikes (O→0, I/L→1). */
function normalizeCode(raw) {
  const code = String(raw ?? "").toUpperCase().replace(/[\s-]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  return /^[0-9A-HJKMNP-TV-Z]{8}$/.test(code) ? code : null;
}
/** The app filters nicknames too; the server only keeps them short and printable. */
function cleanNickname(raw) {
  const name = String(raw ?? "").replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, "").trim().slice(0, 20);
  return name || "Player";
}
async function readJSON(request) {
  const text = await request.text();
  if (text.length > 2048) return null;
  try { return JSON.parse(text); } catch { return null; }
}
async function limited(limiter, key) {
  if (!limiter) return false; // binding absent (older wrangler dev): no limit
  const { success } = await limiter.limit({ key });
  return !success;
}

const directory = (env) => env.DIRECTORY.get(env.DIRECTORY.idFromName("global"));

async function createRoom(env, game, nickname, open) {
  for (let attempt = 0; attempt < 3; attempt++) {
    const code = [...crypto.getRandomValues(new Uint8Array(8))].map((b) => CODE_ALPHABET[b & 31]).join("");
    const response = await env.ROOMS.get(env.ROOMS.idFromName(code)).fetch("https://room/create", {
      method: "POST", body: JSON.stringify({ code, game, nickname, open }),
    });
    if (response.status !== 409) return response;
  }
  return json({ error: "tryAgain" }, 503);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    const ip = request.headers.get("cf-connecting-ip") ?? "local";
    if (parts[0] !== "v1") return json({ error: "notFound" }, 404);

    if (request.method === "GET" && parts[1] === "health" && parts.length === 2) return json({ ok: true, protocol: PROTOCOL });

    if (request.method === "POST" && parts[1] === "rooms" && parts.length === 2) {
      if (await limited(env.CREATE_LIMITER, ip)) return json({ error: "rateLimited" }, 429);
      const body = await readJSON(request);
      if (!body || !GAMES[body.game]) return json({ error: "badRequest" }, 400);
      return createRoom(env, body.game, body.nickname, body.open === true);
    }

    if (request.method === "GET" && parts[1] === "lobbies" && parts.length === 2) {
      const game = url.searchParams.get("game");
      const list = await directory(env).fetch(`https://dir/list${game && GAMES[game] ? `?game=${game}` : ""}`);
      return json(await list.json());
    }

    if (request.method === "POST" && parts[1] === "quickplay" && parts.length === 2) {
      if (await limited(env.JOIN_LIMITER, ip)) return json({ error: "rateLimited" }, 429);
      const body = await readJSON(request);
      if (!body || !GAMES[body.game]) return json({ error: "badRequest" }, 400);
      const avoid = new Set(Array.isArray(body.avoid) ? body.avoid.slice(0, 20).map(String) : []);
      const { lobbies } = await (await directory(env).fetch(`https://dir/list?game=${body.game}&oldestFirst=1`)).json();
      // Seat the player in the game that's been waiting longest; another player may take the
      // last seat first, so try the next one.
      for (const lobby of lobbies.filter((l) => !avoid.has(l.code)).slice(0, 5)) {
        const joined = await env.ROOMS.get(env.ROOMS.idFromName(lobby.code)).fetch("https://room/join", {
          method: "POST", body: JSON.stringify({ nickname: body.nickname }),
        });
        if (joined.status === 200) return joined;
      }
      return createRoom(env, body.game, body.nickname, true);
    }

    if (parts[1] === "rooms" && parts.length === 4) {
      const code = normalizeCode(parts[2]);
      if (!code) return json({ error: "notFound" }, 404);
      const room = env.ROOMS.get(env.ROOMS.idFromName(code));
      if (request.method === "POST" && parts[3] === "join") {
        // Codes are short, so guessing is throttled per address.
        if (await limited(env.JOIN_LIMITER, ip)) return json({ error: "rateLimited" }, 429);
        const body = await readJSON(request);
        return room.fetch("https://room/join", { method: "POST", body: JSON.stringify({ nickname: body?.nickname }) });
      }
      if (request.method === "GET" && parts[3] === "socket") return room.fetch(new Request("https://room/socket", request));
    }
    return json({ error: "notFound" }, 404);
  },
};

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS room (
        id INTEGER PRIMARY KEY CHECK (id = 1), code TEXT NOT NULL, game TEXT NOT NULL, phase TEXT NOT NULL,
        min_seats INTEGER NOT NULL, max_seats INTEGER NOT NULL, organizer TEXT NOT NULL, ended_message TEXT,
        turn_revision INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS seats (
        seat TEXT PRIMARY KEY, idx INTEGER NOT NULL, nickname TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
        active INTEGER NOT NULL DEFAULT 1, rematch INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL, revision INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS moves (move_id TEXT PRIMARY KEY, seat TEXT NOT NULL, revision INTEGER NOT NULL, outcome TEXT NOT NULL, at INTEGER NOT NULL);
    `);
    // Added after launch: rooms from before it are private.
    try { this.sql.exec("ALTER TABLE room ADD COLUMN open INTEGER NOT NULL DEFAULT 0"); } catch {}
  }

  // MARK: storage helpers

  room() { return this.sql.exec("SELECT * FROM room WHERE id = 1").toArray()[0]; }
  activeSeats() { return this.sql.exec("SELECT seat, idx, nickname, rematch FROM seats WHERE active = 1 ORDER BY idx").toArray(); }
  current() { return this.sql.exec("SELECT json, revision FROM state WHERE id = 1").toArray()[0]; }
  nickname(seat) { return this.sql.exec("SELECT nickname FROM seats WHERE seat = ?", seat).toArray()[0]?.nickname ?? "A player"; }

  async addSeat(nickname) {
    const next = this.sql.exec("SELECT COALESCE(MAX(idx) + 1, 0) AS n FROM seats").one().n;
    const seat = `seat${next}`, token = randomHex(32);
    this.sql.exec("INSERT INTO seats (seat, idx, nickname, token_hash) VALUES (?, ?, ?, ?)", seat, next, cleanNickname(nickname), await sha256(token));
    return { seat, token };
  }

  /** Records activity and moves the expiry alarm to match the room's phase. */
  async touch() {
    const now = Date.now();
    this.sql.exec("UPDATE room SET updated_at = ? WHERE id = 1", now);
    const room = this.room();
    await this.ctx.storage.setAlarm((room.phase === "lobby" ? room.created_at : now) + TTL[room.phase]);
  }

  // MARK: HTTP from the Worker

  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === "/create") {
      if (this.room()) return json({ error: "codeTaken" }, 409);
      const { code, game, nickname, open } = await request.json();
      const now = Date.now();
      this.sql.exec("INSERT INTO room (id, code, game, phase, min_seats, max_seats, organizer, created_at, updated_at, open) VALUES (1, ?, ?, 'lobby', ?, ?, 'seat0', ?, ?, ?)",
        code, game, GAMES[game].min, GAMES[game].max, now, now, open ? 1 : 0);
      const { seat, token } = await this.addSeat(nickname);
      await this.touch();
      await this.syncDirectory();
      return json({ code, seat, token, game, maxSeats: GAMES[game].max });
    }
    if (path === "/join") {
      const room = this.room();
      if (!room) return json({ error: "notFound" }, 404);
      if (room.phase !== "lobby") return json({ error: "alreadyStarted" }, 409);
      if (this.activeSeats().length >= room.max_seats) return json({ error: "full" }, 409);
      const { nickname } = await request.json();
      const { seat, token } = await this.addSeat(nickname);
      this.broadcastRoster();
      await this.syncDirectory();
      return json({ code: room.code, seat, token, game: room.game, maxSeats: room.max_seats });
    }
    if (path === "/socket") {
      if (request.headers.get("Upgrade") !== "websocket") return json({ error: "expectedWebSocket" }, 426);
      const room = this.room();
      if (!room) return json({ error: "notFound" }, 404);
      const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer /, "");
      const row = this.sql.exec("SELECT seat, active FROM seats WHERE token_hash = ?", await sha256(token)).toArray()[0];
      if (!row) return json({ error: "badToken" }, 401);
      if (!row.active) return json({ error: "left" }, 410);
      const pair = new WebSocketPair();
      // Hibernation API: the room sleeps between moves and keeps the sockets; the tag is the seat.
      this.ctx.acceptWebSocket(pair[1], [row.seat]);
      pair[1].serializeAttachment({ lastSeen: Date.now() });
      this.broadcastRoster();
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    return json({ error: "notFound" }, 404);
  }

  // MARK: WebSocket

  async webSocketMessage(ws, message) {
    if (typeof message !== "string" || message.length > MAX_MESSAGE_BYTES) return this.send(ws, { type: "error", error: "tooLarge" });
    const [seat] = this.ctx.getTags(ws);
    ws.serializeAttachment({ lastSeen: Date.now() });
    let msg;
    try { msg = JSON.parse(message); } catch { return this.send(ws, { type: "error", error: "badJSON" }); }
    const room = this.room();
    if (!room) return ws.close(4404, "room expired");
    switch (msg.type) {
      case "ping": return this.send(ws, { type: "pong", t: msg.t });
      case "resume": return this.resume(ws, seat);
      case "start": return this.start(ws, seat);
      case "move": return this.move(ws, seat, msg);
      case "rematch": return this.rematch(seat);
      case "leave": return this.leave(seat);
      case "kick": return this.kick(ws, seat, msg.seat);
      default: return this.send(ws, { type: "error", error: "unknownType" });
    }
  }

  async webSocketClose(ws, code) {
    try { ws.close(code === 1005 ? 1000 : code, "closing"); } catch {}
    this.broadcastRoster(ws);
  }

  async webSocketError(ws) { this.broadcastRoster(ws); }

  send(ws, message) { try { ws.send(JSON.stringify(message)); } catch {} }

  /** Everyone's view of the table: who's seated, who's connected, the phase, rematch votes. */
  rosterFor(seat, closing) {
    const room = this.room();
    const connected = new Set(this.ctx.getWebSockets().filter((s) => s !== closing && this.isLive(s)).flatMap((s) => this.ctx.getTags(s)));
    const seats = this.activeSeats();
    return {
      type: "roster", protocol: PROTOCOL, code: room.code, game: room.game, phase: room.phase,
      minSeats: room.min_seats, maxSeats: room.max_seats, organizer: room.organizer, endedMessage: room.ended_message,
      you: seat, open: room.open === 1, players: seats.map((s) => ({ seat: s.seat, nickname: s.nickname, connected: connected.has(s.seat) })),
      rematchVotes: seats.filter((s) => s.rematch).map((s) => s.seat),
    };
  }

  isLive(ws) {
    const pinged = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
    const spoke = ws.deserializeAttachment()?.lastSeen ?? 0;
    return Date.now() - Math.max(pinged, spoke) < PRESENCE_TIMEOUT;
  }

  broadcastRoster(closing) {
    if (!this.room()) return;
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === closing) continue;
      const [seat] = this.ctx.getTags(ws);
      this.send(ws, this.rosterFor(seat, closing));
    }
  }

  /** Sends each socket only its own seat's projection. */
  broadcastViews(views, revision) {
    for (const ws of this.ctx.getWebSockets()) {
      const [seat] = this.ctx.getTags(ws);
      if (views[seat]) this.send(ws, { type: "snapshot", revision, view: views[seat] });
    }
  }

  resume(ws, seat) {
    this.send(ws, this.rosterFor(seat));
    const current = this.current();
    if (!current) return;
    const out = getRules().call({ op: "views", state: JSON.parse(current.json) });
    if (out.ok && out.views[seat]) this.send(ws, { type: "snapshot", revision: current.revision, view: out.views[seat] });
  }

  async start(ws, seat) {
    const room = this.room(), seats = this.activeSeats();
    if (room.phase !== "lobby" || seat !== room.organizer) return this.send(ws, { type: "error", error: "notAllowed" });
    if (seats.length < room.min_seats) return this.send(ws, { type: "error", error: "notEnoughPlayers" });
    const result = getRules().call({ op: "new", game: room.game, seats: seats.map((s) => s.seat) });
    if (!result.ok) return this.send(ws, { type: "error", error: result.error });
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("INSERT OR REPLACE INTO state (id, json, revision) VALUES (1, ?, 0)", JSON.stringify(result.state));
      this.sql.exec("UPDATE room SET phase = 'playing', turn_revision = 0 WHERE id = 1");
    });
    await this.touch();
    await this.syncDirectory();
    this.broadcastRoster();
    this.broadcastViews(result.views, 0);
  }

  async move(ws, seat, { moveId, baseRevision, move }) {
    if (typeof moveId !== "string" || moveId.length === 0 || moveId.length > 64 || !Number.isInteger(baseRevision) || typeof move !== "object" || move === null) {
      return this.send(ws, { type: "error", error: "badMove" });
    }
    // Exactly-once: a retried move id gets its original answer and changes nothing.
    const seen = this.sql.exec("SELECT outcome FROM moves WHERE move_id = ?", moveId).toArray()[0];
    if (seen) return this.send(ws, { type: "result", moveId, duplicate: true, ...JSON.parse(seen.outcome) });

    const room = this.room(), current = this.current();
    const record = (outcome, revision) =>
      this.sql.exec("INSERT INTO moves (move_id, seat, revision, outcome, at) VALUES (?, ?, ?, ?, ?)", moveId, seat, revision, JSON.stringify(outcome), Date.now());
    const refuse = (error, message) => {
      const outcome = { ok: false, error, message, revision: current?.revision ?? -1 };
      record(outcome, outcome.revision);
      this.send(ws, { type: "result", moveId, ...outcome });
    };
    if (room.phase !== "playing" || !current) return refuse("notPlaying", "This game isn't in progress.");

    const result = getRules().call({ op: "apply", state: JSON.parse(current.json), seat, move });
    // Same rule as a phone host: a move must be based on the latest turn. Call One!, Catch! and
    // resign race against turns by design, so they're exempt.
    if (baseRevision !== current.revision && baseRevision < room.turn_revision && !result.turnIndependent) {
      return refuse("staleBoard", "The board changed before your move arrived. Try again.");
    }
    if (!result.ok) return refuse(result.error, result.message);

    const next = current.revision + 1;
    // Commit before telling anyone. The revision check means a lost race can't go unnoticed.
    this.ctx.storage.transactionSync(() => {
      const written = this.sql.exec("UPDATE state SET json = ?, revision = ? WHERE id = 1 AND revision = ?", JSON.stringify(result.state), next, current.revision).rowsWritten;
      if (written !== 1) throw new Error("revision race");
      record({ ok: true, revision: next }, next);
      if (!result.turnIndependent) this.sql.exec("UPDATE room SET turn_revision = ? WHERE id = 1", next);
      if (!result.finished) this.sql.exec("UPDATE seats SET rematch = 0");
    });
    await this.touch();
    this.send(ws, { type: "result", moveId, ok: true, revision: next });
    this.broadcastViews(result.views, next);
  }

  async rematch(seat) {
    const room = this.room(), current = this.current();
    if (room.phase !== "playing" || !current) return;
    const state = JSON.parse(current.json);
    const finished = getRules().call({ op: "views", state }).finished;
    if (!finished) return;
    this.sql.exec("UPDATE seats SET rematch = 1 WHERE seat = ? AND active = 1", seat);
    const seats = this.activeSeats();
    if (seats.every((s) => s.rematch)) {
      const result = getRules().call({ op: "rematch", state });
      const next = current.revision + 1;
      this.ctx.storage.transactionSync(() => {
        this.sql.exec("UPDATE state SET json = ?, revision = ? WHERE id = 1", JSON.stringify(result.state), next);
        this.sql.exec("UPDATE room SET turn_revision = ? WHERE id = 1", next);
        this.sql.exec("UPDATE seats SET rematch = 0");
      });
      await this.touch();
      this.broadcastRoster();
      this.broadcastViews(result.views, next);
    } else {
      this.broadcastRoster();
    }
  }

  async leave(seat) {
    const room = this.room();
    const name = this.nickname(seat);
    this.sql.exec("UPDATE seats SET active = 0, rematch = 0 WHERE seat = ?", seat);
    if (room.phase === "lobby") {
      const remaining = this.activeSeats();
      if (remaining.length === 0) {
        this.sql.exec("UPDATE room SET phase = 'ended', ended_message = ? WHERE id = 1", "Everyone left the game.");
      } else if (seat === room.organizer) {
        // The earliest remaining player becomes the host.
        this.sql.exec("UPDATE room SET organizer = ? WHERE id = 1", remaining[0].seat);
      }
    } else if (room.phase === "playing") {
      this.sql.exec("UPDATE room SET phase = 'ended', ended_message = ? WHERE id = 1", `${name} left the game. The match has ended.`);
    }
    await this.touch();
    await this.syncDirectory();
    for (const ws of this.ctx.getWebSockets(seat)) { try { ws.close(4000, "left"); } catch {} }
    this.broadcastRoster();
  }

  /** The organizer removes someone before the game starts. Their seat is gone for good. */
  async kick(ws, seat, target) {
    const room = this.room();
    if (room.phase !== "lobby" || seat !== room.organizer || target === seat || typeof target !== "string") {
      return this.send(ws, { type: "error", error: "notAllowed" });
    }
    const written = this.sql.exec("UPDATE seats SET active = 0 WHERE seat = ? AND active = 1", target).rowsWritten;
    if (written !== 1) return;
    await this.touch();
    await this.syncDirectory();
    for (const s of this.ctx.getWebSockets(target)) { try { s.close(4001, "removed"); } catch {} }
    this.broadcastRoster();
  }

  /** Lists an open lobby with a free seat in the directory, and takes it off otherwise. */
  async syncDirectory() {
    const room = this.room();
    if (!room || !this.env.DIRECTORY) return;
    const seats = this.activeSeats();
    const listed = room.open === 1 && room.phase === "lobby" && seats.length > 0 && seats.length < room.max_seats;
    const host = seats.find((s) => s.seat === room.organizer)?.nickname ?? "Player";
    await directory(this.env).fetch(listed ? "https://dir/upsert" : "https://dir/remove", {
      method: "POST",
      body: JSON.stringify({ code: room.code, game: room.game, host, seats: seats.length, maxSeats: room.max_seats, createdAt: room.created_at }),
    });
  }

  async alarm() {
    const room = this.room();
    if (!room) return;
    const expires = (room.phase === "lobby" ? room.created_at : room.updated_at) + TTL[room.phase];
    if (Date.now() < expires) return this.ctx.storage.setAlarm(expires);
    if (room.open === 1 && this.env.DIRECTORY) {
      await directory(this.env).fetch("https://dir/remove", { method: "POST", body: JSON.stringify({ code: room.code }) });
    }
    for (const ws of this.ctx.getWebSockets()) { try { ws.close(4404, "room expired"); } catch {} }
    await this.ctx.storage.deleteAll();
  }
}

/**
 * The list of open lobbies with a free seat, so anyone can find a game without a code.
 * One instance ("global"). Rooms keep it current: they add themselves while open and waiting,
 * and remove themselves when full, started, ended or expired. Entries older than a lobby can
 * live (24 h) are dropped regardless.
 */
export class LobbyDirectory extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS lobbies (
      code TEXT PRIMARY KEY, game TEXT NOT NULL, host TEXT NOT NULL, seats INTEGER NOT NULL,
      max_seats INTEGER NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)`);
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/upsert") {
      const l = await request.json();
      this.sql.exec(`INSERT INTO lobbies (code, game, host, seats, max_seats, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(code) DO UPDATE SET host = excluded.host, seats = excluded.seats, updated_at = excluded.updated_at`,
        l.code, l.game, l.host, l.seats, l.maxSeats, l.createdAt, Date.now());
      return json({ ok: true });
    }
    if (url.pathname === "/remove") {
      const { code } = await request.json();
      this.sql.exec("DELETE FROM lobbies WHERE code = ?", code);
      return json({ ok: true });
    }
    if (url.pathname === "/list") {
      this.sql.exec("DELETE FROM lobbies WHERE created_at < ?", Date.now() - TTL.lobby);
      const game = url.searchParams.get("game");
      const order = url.searchParams.get("oldestFirst") ? "created_at ASC" : "created_at DESC";
      const rows = game
        ? this.sql.exec(`SELECT * FROM lobbies WHERE game = ? AND seats < max_seats ORDER BY ${order} LIMIT 50`, game).toArray()
        : this.sql.exec(`SELECT * FROM lobbies WHERE seats < max_seats ORDER BY ${order} LIMIT 50`).toArray();
      return json({ lobbies: rows.map((r) => ({ code: r.code, game: r.game, host: r.host, seats: r.seats, maxSeats: r.max_seats })) });
    }
    return json({ error: "notFound" }, 404);
  }
}
