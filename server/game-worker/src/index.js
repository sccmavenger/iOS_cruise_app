// CruiseLAN online games: one Durable Object per room. The game rules are the app's own Swift
// rules compiled to WebAssembly (see build-rules.sh), so online and offline games behave the same.
//
// HTTP
//   GET  /v1/health                      → { ok, protocol }
//   POST /v1/rooms        { game, nickname, open? }  → { code, seat, token, game, maxSeats }
//        open: true lists the game for everyone (default false, private: code only)
//   POST /v1/rooms/:code/join { nickname }    → same
//   POST /v1/rooms/:code/leave  (Authorization: Bearer <token>) → gives up the seat; works even
//        when the socket is down, so leaving is never lost
//   GET  /v1/lobbies[?game=]              → { lobbies: [{ code, game, host, seats, maxSeats }] } (open games)
//   POST /v1/quickplay    { game, nickname, avoid? } → seat in the longest-waiting open game, or a new one
//   GET  /v1/rooms/:code/info             → { game, host, seats, maxSeats, phase } for invite pages
//
// Invite links (one tap into a game)
//   GET  /join/:code                      → opens the app straight into the game (Universal Link);
//                                           without the app, a page with "Open" and "Get the app"
//   GET  /.well-known/apple-app-site-association  → tells iOS that /join/* links belong to the app
//   GET  /v1/rooms/:code/socket  (Authorization: Bearer <token>, WebSocket upgrade)
//
// WebSocket, client → server
//   { type: "resume" }                      roster + current snapshot
//   { type: "start" }                       organizer starts the game
//   { type: "move", moveId, baseRevision, move }
//   { type: "rematch" } | { type: "leave" } | { type: "ping", t }
//   { type: "kick", seat }                  organizer removes a player before the game starts
//   { type: "push", token, sandbox }        this seat's APNs device token ("" clears it), so the
//                                           seat gets notifications while the app isn't open
//   { type: "away" }                        the app left the screen: counts as not connected (and
//                                           gets notifications) until it says anything else
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
const MAX_BODY_BYTES = 2048;
// Abuse limits. A player sends a few messages a minute (pings don't count: Cloudflare answers
// them), so 40 in 10 s is a flood. A phone has one socket; two covers a reconnect overlap.
const MESSAGE_LIMIT = { count: 40, windowMs: 10 * 1000 };
const MAX_SOCKETS_PER_SEAT = 2;
// A lobby seat whose player never connects is freed after this long, so nobody can block an
// open game by taking its seats over HTTP and never showing up.
const GHOST_SEAT_GRACE = 90 * 1000;
// One address (a ship or hotel shares one) can list this many open games per game type, so a
// single attacker can't fill the open list.
const MAX_LISTED_PER_ADDRESS = 10;
// Push notifications (APNs), for players whose app isn't on screen. Never more than one of a
// kind per seat this often, so joining and leaving over and over can't spam anyone.
const APNS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" };
const APNS_TOPIC = "com.dannyguillory.cruiselan";
const PUSH_THROTTLE_MS = 10 * 1000;
// Moves remembered for exactly-once retries. A retry comes within minutes, not thousands of moves later.
const MOVES_KEPT = 2000;
// A socket counts as connected only if it said something recently. Clients send "ping" every
// 25 s; Cloudflare answers "pong" itself without waking the room. A phone that vanished without
// closing (dead battery, lost signal) shows as away after this long.
const PRESENCE_TIMEOUT = 75 * 1000;
const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford base32, no I L O U
const APP_ID = "CB4AAVWWUD.com.dannyguillory.cruiselan";
const GET_APP_URL = "https://testflight.apple.com/join/E7j3xJE7"; // Ring 1 public TestFlight link
const GAME_NAMES = {
  ticTacToe: "Tic-Tac-Toe", connectFour: "Connect Four", colorMatch: "Color Match", checkers: "Checkers",
  chess: "Chess", spades: "Spades", tonk: "Tonk",
};

let rules = null;
const getRules = () => (rules ??= createRules(rulesModule));

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff" } });
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
  const name = Array.from(String(raw ?? "")
    // Control, format (direction overrides, zero-width), private-use, unpaired surrogates and
    // line separators can spoof or hide names. The zero-width joiner stays, for emoji.
    .replace(/(?!\u200d)[\p{Cc}\p{Cf}\p{Co}\p{Cs}\p{Cn}\p{Zl}\p{Zp}]/gu, "")
    .replace(/\s+/g, " ").trim()).slice(0, 20).join("").trim();
  return name || "Player";
}
/** Reads a small JSON body, stopping as soon as it's too big rather than buffering it all. */
async function readJSON(request) {
  if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES || !request.body) return null;
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) { reader.cancel().catch(() => {}); return null; }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { all.set(chunk, offset); offset += chunk.byteLength; }
  try { return JSON.parse(new TextDecoder().decode(all)); } catch { return null; }
}
/**
 * A label for the caller's address, so one address can't fill the open list. Keyed with a
 * server secret (`wrangler secret put ADDRESS_KEY`): unlike a plain hash, it can't be turned
 * back into the address by trying every one.
 */
async function addressKey(env, ip) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.ADDRESS_KEY ?? "dev-only"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(ip));
  return [...new Uint8Array(mac)].slice(0, 12).map((b) => b.toString(16).padStart(2, "0")).join("");
}
async function limited(limiter, key) {
  if (!limiter) return false; // binding absent (older wrangler dev): no limit
  const { success } = await limiter.limit({ key });
  return !success;
}

const directory = (env) => env.DIRECTORY.get(env.DIRECTORY.idFromName("global"));

// The invite page runs no script and can't be framed (clickjacking) or sniffed as another type.
const PAGE_HEADERS = {
  "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "x-frame-options": "DENY", "x-content-type-options": "nosniff", "referrer-policy": "no-referrer",
};

const escapeHTML = (text) => String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

/**
 * Shown only when the app isn't installed (or the link is opened somewhere that doesn't hand
 * Universal Links to apps). "Open in CruiseLAN" uses the app's own URL scheme with the code, so
 * after installing, one more tap still lands in the game.
 */
async function invitePage(env, rawCode) {
  const code = normalizeCode(rawCode);
  let info = null;
  if (code) {
    const response = await env.ROOMS.get(env.ROOMS.idFromName(code)).fetch("https://room/info");
    if (response.status === 200) info = await response.json();
  }
  const shown = code ? `${code.slice(0, 4)}-${code.slice(4)}` : "";
  const game = info ? GAME_NAMES[info.game] ?? "a game" : "a game";
  // The host's name isn't shown: it's chosen by whoever made the game, and this page is public.
  const title = info ? `You're invited to play ${game}` : code ? "This game has ended" : "Invite link not recognized";
  const detail = !info ? "Ask for a new invite, or host your own game in CruiseLAN."
    : info.phase !== "lobby" ? "This game has already started." : `${info.seats} of ${info.maxSeats} seats taken.`;
  const open = info && info.phase === "lobby"
    ? `<a class="button" href="cruiselan://join/${code}">Open in CruiseLAN</a>` : "";
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="apple-itunes-app" content="app-id=6823032794">
<title>${title} · CruiseLAN</title>
<style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:480px;margin:48px auto;padding:0 24px;color:#0b1a3d;text-align:center}
h1{font-size:26px;color:#05456f}.code{font:700 30px ui-monospace,monospace;letter-spacing:3px;margin:16px 0}
.button{display:block;background:#05456f;color:#fff;text-decoration:none;padding:16px;border-radius:14px;font-weight:600;margin:12px 0}
.secondary{background:#e8f1f7;color:#05456f}p{color:#3c4a66}</style></head><body>
<h1>${title}</h1><p>${escapeHTML(detail)}</p>
${shown ? `<div class="code">${shown}</div>` : ""}
${open}
<a class="button secondary" href="${GET_APP_URL}">Don't have CruiseLAN? Get it free</a>
<p>After installing, come back and tap <b>Open in CruiseLAN</b>, or enter the code in Games › Join a Game with a Code.</p>
</body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", ...PAGE_HEADERS } });
}

// MARK: APNs

const b64url = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64json = (value) => b64url(new TextEncoder().encode(JSON.stringify(value)));
let apnsJWT = null; // { token, at }: Apple wants a fresh one at least hourly, and not more than every 20 min

/** The provider token APNs expects: an ES256 JWT signed with the team's push key (secret APNS_KEY). */
async function apnsAuthorization(env) {
  if (apnsJWT && Date.now() - apnsJWT.at < 40 * 60 * 1000) return apnsJWT.token;
  const der = Uint8Array.from(atob(env.APNS_KEY.replace(/-----[^-]+-----/g, "").replace(/\\n|\s/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signed = `${b64json({ alg: "ES256", kid: env.APNS_KEY_ID })}.${b64json({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) })}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signed));
  apnsJWT = { token: `${signed}.${b64url(signature)}`, at: Date.now() };
  return apnsJWT.token;
}

/**
 * Sends one alert. Returns "gone" when Apple says the token is dead (app deleted, notifications
 * reset), so the caller forgets it. The text never contains player names: names are filtered
 * by the app, and a notification is shown by iOS without the app's filter.
 */
async function sendPush(env, { token, sandbox }, { title, body, collapse, code }) {
  if (!env.APNS_KEY) return "off";
  const base = env.APNS_MOCK ?? (sandbox ? APNS.sandbox : APNS.production);
  const response = await fetch(`${base}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsAuthorization(env)}`, "apns-topic": APNS_TOPIC, "apns-push-type": "alert",
      "apns-priority": "10", "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
      // Same id as the app's own "turn" notification, so the two replace each other.
      ...(collapse ? { "apns-collapse-id": collapse } : {}),
    },
    body: JSON.stringify({ aps: { alert: { title, body }, sound: "default", "thread-id": "game" }, route: "game", code }),
  });
  if (response.ok) return "sent";
  if (response.status === 410) return "gone";
  const reason = (await response.json().catch(() => ({}))).reason ?? "";
  if (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") return "gone";
  return `failed ${response.status} ${reason}`;
}

async function createRoom(env, game, nickname, open, address) {
  for (let attempt = 0; attempt < 3; attempt++) {
    const code = [...crypto.getRandomValues(new Uint8Array(8))].map((b) => CODE_ALPHABET[b & 31]).join("");
    const response = await env.ROOMS.get(env.ROOMS.idFromName(code)).fetch("https://room/create", {
      method: "POST", body: JSON.stringify({ code, game, nickname, open, address }),
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
    if ((request.method === "GET" || request.method === "HEAD") && url.pathname === "/.well-known/apple-app-site-association") {
      return json({ applinks: { details: [{ appIDs: [APP_ID], components: [{ "/": "/join/*", comment: "Game invite links" }] }] } });
    }
    if (request.method === "GET" && parts[0] === "join" && parts.length === 2) {
      // Each page tells whether a code exists, so it's throttled like joining.
      if (await limited(env.INFO_LIMITER, ip)) return new Response("Too many requests. Wait a minute and try again.", { status: 429, headers: PAGE_HEADERS });
      return invitePage(env, parts[1]);
    }
    if (parts[0] !== "v1") return json({ error: "notFound" }, 404);

    if (request.method === "GET" && parts[1] === "health" && parts.length === 2) return json({ ok: true, protocol: PROTOCOL });

    if (request.method === "POST" && parts[1] === "rooms" && parts.length === 2) {
      if (await limited(env.CREATE_LIMITER, ip)) return json({ error: "rateLimited" }, 429);
      const body = await readJSON(request);
      if (!body || !GAMES[body.game]) return json({ error: "badRequest" }, 400);
      return createRoom(env, body.game, body.nickname, body.open === true, await addressKey(env, ip));
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
      return createRoom(env, body.game, body.nickname, true, await addressKey(env, ip));
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
      if (request.method === "GET" && parts[3] === "info") {
        if (await limited(env.INFO_LIMITER, ip)) return json({ error: "rateLimited" }, 429);
        return room.fetch("https://room/info");
      }
      if (request.method === "POST" && parts[3] === "leave") {
        return room.fetch("https://room/leave", { method: "POST", headers: { Authorization: request.headers.get("Authorization") ?? "" } });
      }
    }
    return json({ error: "notFound" }, 404);
  },
};

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    // Rooms created before a column existed get it here (fails harmlessly on a fresh object).
    try { this.sql.exec("ALTER TABLE room ADD COLUMN open INTEGER NOT NULL DEFAULT 0"); } catch {}
    try { this.sql.exec("ALTER TABLE seats ADD COLUMN removed INTEGER NOT NULL DEFAULT 0"); } catch {}
    try { this.sql.exec("ALTER TABLE room ADD COLUMN address TEXT"); } catch {}
    // Older seats count as connected, so they're never mistaken for ghosts.
    try { this.sql.exec("ALTER TABLE seats ADD COLUMN joined_at INTEGER NOT NULL DEFAULT 0"); } catch {}
    try { this.sql.exec("ALTER TABLE seats ADD COLUMN connected INTEGER NOT NULL DEFAULT 1"); } catch {}
    try { this.sql.exec("ALTER TABLE seats ADD COLUMN push_token TEXT"); } catch {}
    try { this.sql.exec("ALTER TABLE seats ADD COLUMN push_sandbox INTEGER NOT NULL DEFAULT 0"); } catch {}
    try { this.sql.exec("ALTER TABLE room ADD COLUMN awaiting TEXT"); } catch {}
    this.pushedAt = new Map(); // "seat|kind" → time; lost when the room sleeps, which is fine
  }

  /**
   * Tables are made only when a room is really created, so looking up a code that doesn't
   * exist (a typo, a guess, an expired invite) stores nothing.
   */
  createSchema() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS room (
        id INTEGER PRIMARY KEY CHECK (id = 1), code TEXT NOT NULL, game TEXT NOT NULL, phase TEXT NOT NULL,
        min_seats INTEGER NOT NULL, max_seats INTEGER NOT NULL, organizer TEXT NOT NULL, ended_message TEXT,
        turn_revision INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        open INTEGER NOT NULL DEFAULT 0, address TEXT, awaiting TEXT);
      CREATE TABLE IF NOT EXISTS seats (
        seat TEXT PRIMARY KEY, idx INTEGER NOT NULL, nickname TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
        active INTEGER NOT NULL DEFAULT 1, rematch INTEGER NOT NULL DEFAULT 0, removed INTEGER NOT NULL DEFAULT 0,
        joined_at INTEGER NOT NULL DEFAULT 0, connected INTEGER NOT NULL DEFAULT 0,
        push_token TEXT, push_sandbox INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL, revision INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS moves (move_id TEXT PRIMARY KEY, seat TEXT NOT NULL, revision INTEGER NOT NULL, outcome TEXT NOT NULL, at INTEGER NOT NULL);
    `);
  }

  // MARK: storage helpers

  room() {
    try { return this.sql.exec("SELECT * FROM room WHERE id = 1").toArray()[0]; } catch { return undefined; } // no tables: no room
  }
  activeSeats() { return this.sql.exec("SELECT seat, idx, nickname, rematch FROM seats WHERE active = 1 ORDER BY idx").toArray(); }
  current() { return this.sql.exec("SELECT json, revision FROM state WHERE id = 1").toArray()[0]; }
  nickname(seat) { return this.sql.exec("SELECT nickname FROM seats WHERE seat = ?", seat).toArray()[0]?.nickname ?? "A player"; }

  /** A new seat secret and its hash. Done first, because awaiting lets other requests in. */
  async newToken() {
    const token = randomHex(32);
    return { token, hash: await sha256(token) };
  }

  /** Synchronous, so a capacity check just before it can't be raced by another join. */
  insertSeat(nickname, hash) {
    const next = this.sql.exec("SELECT COALESCE(MAX(idx) + 1, 0) AS n FROM seats").one().n;
    const seat = `seat${next}`;
    this.sql.exec("INSERT INTO seats (seat, idx, nickname, token_hash, joined_at) VALUES (?, ?, ?, ?, ?)", seat, next, cleanNickname(nickname), hash, Date.now());
    return seat;
  }

  /** A room that was never created, or has expired. */
  notFound() {
    return json({ error: "notFound" }, 404);
  }

  async seatFor(request) {
    const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer /, "");
    return this.sql.exec("SELECT seat, active, removed FROM seats WHERE token_hash = ?", await sha256(token)).toArray()[0];
  }

  /** Records activity and moves the expiry alarm to match the room's phase. */
  async touch() {
    this.sql.exec("UPDATE room SET updated_at = ? WHERE id = 1", Date.now());
    await this.scheduleAlarm();
  }

  /** The next thing the alarm has to do: free a ghost seat, or expire the room. */
  async scheduleAlarm() {
    const room = this.room();
    const expires = (room.phase === "lobby" ? room.created_at : room.updated_at) + TTL[room.phase];
    // The same seats freeGhostSeats frees (never the host), so the alarm can't keep firing for nothing.
    const ghost = room.phase === "lobby"
      ? this.sql.exec("SELECT MIN(joined_at) AS t FROM seats WHERE active = 1 AND connected = 0 AND seat != ?", room.organizer).one().t : null;
    const at = ghost == null ? expires : Math.min(expires, ghost + GHOST_SEAT_GRACE + 1000);
    await this.ctx.storage.setAlarm(Math.max(at, Date.now() + 1000));
  }

  /** Frees lobby seats whose players never connected. Returns whether any were freed. */
  freeGhostSeats() {
    const room = this.room();
    if (room?.phase !== "lobby") return false;
    const freed = this.sql.exec("UPDATE seats SET active = 0 WHERE active = 1 AND connected = 0 AND seat != ? AND joined_at < ?",
      room.organizer, Date.now() - GHOST_SEAT_GRACE).rowsWritten;
    return freed > 0;
  }

  // MARK: HTTP from the Worker

  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === "/create") {
      if (this.room()) return json({ error: "codeTaken" }, 409);
      const { code, game, nickname, open, address } = await request.json();
      const { token, hash } = await this.newToken();
      if (this.room()) return json({ error: "codeTaken" }, 409);
      this.createSchema();
      const now = Date.now();
      this.sql.exec("INSERT INTO room (id, code, game, phase, min_seats, max_seats, organizer, created_at, updated_at, open, address) VALUES (1, ?, ?, 'lobby', ?, ?, 'seat0', ?, ?, ?, ?)",
        code, game, GAMES[game].min, GAMES[game].max, now, now, open ? 1 : 0, address ?? null);
      const seat = this.insertSeat(nickname, hash);
      await this.touch();
      await this.syncDirectory();
      return json({ code, seat, token, game, maxSeats: GAMES[game].max });
    }
    if (path === "/join") {
      const { nickname } = await request.json();
      const { token, hash } = await this.newToken();
      // From here to the insert nothing awaits, so two joins for the last seat can't both win.
      const room = this.room();
      if (!room) return this.notFound();
      if (room.phase !== "lobby") return json({ error: "alreadyStarted" }, 409);
      this.freeGhostSeats();
      if (this.activeSeats().length >= room.max_seats) return json({ error: "full" }, 409);
      const seat = this.insertSeat(nickname, hash);
      this.broadcastRoster();
      await this.scheduleAlarm();
      await this.syncDirectory();
      // The host who shared a link and put the phone away hears that someone came.
      const count = this.activeSeats().length, name = GAME_NAMES[room.game];
      this.notify(room.organizer, count >= room.max_seats
        ? { kind: "lobby", title: `Your ${name} game is full`, body: "Everyone's here. Tap to start the game." }
        : { kind: "lobby", title: `Someone joined your ${name} game`,
            body: count >= room.min_seats ? `${count} of ${room.max_seats} players. Tap to start, or wait for more.` : `${count} of ${room.max_seats} players.` });
      return json({ code: room.code, seat, token, game: room.game, maxSeats: room.max_seats });
    }
    if (path === "/info") {
      const room = this.room();
      if (!room) return this.notFound();
      // No names: anyone holding a code can ask, and a private game's players are nobody else's business.
      return json({ game: room.game, seats: this.activeSeats().length, maxSeats: room.max_seats, phase: room.phase });
    }
    if (path === "/socket") {
      if (request.headers.get("Upgrade") !== "websocket") return json({ error: "expectedWebSocket" }, 426);
      if (!this.room()) return this.notFound();
      const row = await this.seatFor(request);
      if (!row) return json({ error: "badToken" }, 401);
      // 403 rather than a WebSocket close code: iOS can't read custom close codes.
      if (row.removed) return json({ error: "removed" }, 403);
      if (!row.active) return json({ error: "left" }, 410);
      const pair = new WebSocketPair();
      // Hibernation API: the room sleeps between moves and keeps the sockets; the tag is the seat.
      this.ctx.acceptWebSocket(pair[1], [row.seat]);
      const now = Date.now();
      pair[1].serializeAttachment({ lastSeen: now, openedAt: now, windowStart: now, count: 0, away: false });
      this.sql.exec("UPDATE seats SET connected = 1 WHERE seat = ?", row.seat);
      // A seat gets a socket or two (a reconnect can overlap the old one), never a crowd: the
      // oldest extra ones are closed, so nobody can multiply what the room sends.
      const mine = this.ctx.getWebSockets(row.seat).sort((x, y) => (y.deserializeAttachment()?.openedAt ?? 0) - (x.deserializeAttachment()?.openedAt ?? 0));
      for (const old of mine.slice(MAX_SOCKETS_PER_SEAT)) { try { old.close(4002, "replaced"); } catch {} }
      this.broadcastRoster();
      await this.syncDirectory();
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    if (path === "/leave") {
      if (!this.room()) return this.notFound();
      const row = await this.seatFor(request);
      if (!row) return json({ error: "badToken" }, 401);
      if (row.active) await this.leave(row.seat);
      return json({ ok: true });
    }
    return json({ error: "notFound" }, 404);
  }

  // MARK: WebSocket

  async webSocketMessage(ws, message) {
    if (typeof message !== "string" || message.length > MAX_MESSAGE_BYTES) return this.send(ws, { type: "error", error: "tooLarge" });
    const [seat] = this.ctx.getTags(ws);
    const now = Date.now(), seen = ws.deserializeAttachment() ?? {};
    const fresh = now - (seen.windowStart ?? 0) > MESSAGE_LIMIT.windowMs;
    const count = (fresh ? 0 : seen.count ?? 0) + 1;
    ws.serializeAttachment({ ...seen, lastSeen: now, windowStart: fresh ? now : seen.windowStart, count });
    // A flood: drop the connection. The app reconnects by itself, so a real player loses nothing.
    if (count > MESSAGE_LIMIT.count) {
      this.send(ws, { type: "error", error: "rateLimited" });
      try { ws.close(1008, "too many messages"); } catch {}
      return;
    }
    let msg;
    try { msg = JSON.parse(message); } catch { return this.send(ws, { type: "error", error: "badJSON" }); }
    const room = this.room();
    if (!room) return ws.close(4404, "room expired");
    // Away (the app left the screen) until this socket says anything else.
    const away = msg?.type === "away";
    if (away !== (seen.away === true)) {
      ws.serializeAttachment({ ...ws.deserializeAttachment(), away });
      this.broadcastRoster();
      await this.syncDirectory();
    }
    switch (msg.type) {
      case "ping": return this.send(ws, { type: "pong", t: msg.t });
      case "resume": return this.resume(ws, seat);
      case "start": return this.start(ws, seat);
      case "move": return this.move(ws, seat, msg);
      case "rematch": return this.rematch(seat);
      case "leave": return this.leave(seat);
      case "kick": return this.kick(ws, seat, msg.seat);
      case "away": case "here": return;
      case "push": return this.registerPush(ws, seat, msg);
      default: return this.send(ws, { type: "error", error: "unknownType" });
    }
  }

  async webSocketClose(ws, code) {
    try { ws.close(code === 1005 ? 1000 : code, "closing"); } catch {}
    this.broadcastRoster(ws);
    await this.syncDirectory(ws);
  }

  async webSocketError(ws) {
    this.broadcastRoster(ws);
    await this.syncDirectory(ws);
  }

  send(ws, message) { try { ws.send(JSON.stringify(message)); } catch {} }

  /** Everyone's view of the table: who's seated, who's connected, the phase, rematch votes. */
  rosterFor(seat, closing) {
    const room = this.room();
    const connected = new Set(this.ctx.getWebSockets().filter((s) => s !== closing && this.isPresent(s)).flatMap((s) => this.ctx.getTags(s)));
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

  /** Connected and on screen: the app is open on this game. */
  isPresent(ws) { return this.isLive(ws) && ws.deserializeAttachment()?.away !== true; }

  /** Stores (or clears) the seat's device token. Only ever used for this room's notifications. */
  registerPush(ws, seat, { token, sandbox }) {
    console.log(JSON.stringify({ pushToken: token ? "registered" : "cleared", sandbox: sandbox === true }));
    if (token === "") return this.sql.exec("UPDATE seats SET push_token = NULL WHERE seat = ?", seat);
    if (typeof token !== "string" || !/^[0-9a-fA-F]{64,200}$/.test(token)) return this.send(ws, { type: "error", error: "badToken" });
    this.sql.exec("UPDATE seats SET push_token = ?, push_sandbox = ? WHERE seat = ?", token.toLowerCase(), sandbox === true ? 1 : 0, seat);
  }

  /**
   * Notifies a seat whose app isn't on this game right now (away, closed, or offline), if it gave
   * us a device token. Sent in the background, so nothing waits on Apple.
   */
  notify(seat, { kind, title, body }) {
    if (this.ctx.getWebSockets(seat).some((s) => this.isPresent(s))) return;
    const row = this.sql.exec("SELECT push_token, push_sandbox FROM seats WHERE seat = ? AND active = 1", seat).toArray()[0];
    if (!row?.push_token) return;
    const key = `${seat}|${kind}`, now = Date.now();
    if (now - (this.pushedAt.get(key) ?? 0) < PUSH_THROTTLE_MS) return;
    this.pushedAt.set(key, now);
    const code = this.room().code;
    const sending = (sendPush(this.env, { token: row.push_token, sandbox: row.push_sandbox === 1 }, { title, body, collapse: kind, code })
      .then((outcome) => {
        // Visible in the Worker's logs (wrangler tail); never the token itself.
        console.log(JSON.stringify({ push: kind, sandbox: row.push_sandbox === 1, outcome }));
        if (outcome === "gone") this.sql.exec("UPDATE seats SET push_token = NULL WHERE seat = ? AND push_token = ?", seat, row.push_token);
      })
      .catch((e) => console.log(JSON.stringify({ push: kind, outcome: `error ${e.message}` }))));
    this.ctx.waitUntil?.(sending);
  }

  /** Tells players who became "up" (and aren't looking) that it's their turn. */
  notifyTurns(awaiting, except) {
    const before = new Set(JSON.parse(this.room().awaiting ?? "[]"));
    this.sql.exec("UPDATE room SET awaiting = ? WHERE id = 1", JSON.stringify(awaiting ?? []));
    const name = GAME_NAMES[this.room().game];
    for (const seat of awaiting ?? []) {
      if (seat !== except && !before.has(seat)) this.notify(seat, { kind: "turn", title: `Your turn in ${name}`, body: "Tap to make your move." });
    }
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
    const name = GAME_NAMES[room.game];
    for (const s of seats) {
      if (s.seat !== seat && !result.awaiting.includes(s.seat)) this.notify(s.seat, { kind: "start", title: `Your ${name} game started`, body: "Tap to watch the table." });
    }
    this.sql.exec("UPDATE room SET awaiting = '[]' WHERE id = 1");
    this.notifyTurns(result.awaiting, seat);
  }

  async move(ws, seat, { moveId, baseRevision, move }) {
    if (typeof moveId !== "string" || moveId.length === 0 || moveId.length > 64 || !Number.isInteger(baseRevision) || typeof move !== "object" || move === null) {
      return this.send(ws, { type: "error", error: "badMove" });
    }
    // Exactly-once: a retried move id gets its original answer and changes nothing. Ids are
    // per seat, so nobody can collide with, or read the answer to, someone else's move.
    const key = `${seat}:${moveId}`;
    const seen = this.sql.exec("SELECT outcome FROM moves WHERE move_id = ?", key).toArray()[0];
    if (seen) return this.send(ws, { type: "result", moveId, duplicate: true, ...JSON.parse(seen.outcome) });

    const room = this.room(), current = this.current();
    const record = (outcome, revision) => {
      this.sql.exec("INSERT INTO moves (move_id, seat, revision, outcome, at) VALUES (?, ?, ?, ?, ?)", key, seat, revision, JSON.stringify(outcome), Date.now());
      this.sql.exec("DELETE FROM moves WHERE rowid <= (SELECT MAX(rowid) FROM moves) - ?", MOVES_KEPT);
    };
    const refuse = (error, message) => {
      const outcome = { ok: false, error, message, revision: current?.revision ?? -1 };
      record(outcome, outcome.revision);
      this.send(ws, { type: "result", moveId, ...outcome });
    };
    if (room.phase !== "playing" || !current) return refuse("notPlaying", "This game isn't in progress.");
    // A move can't be based on a board nobody has seen yet (that would dodge the check below).
    if (baseRevision > current.revision || baseRevision < 0) return refuse("staleBoard", "The board changed before your move arrived. Try again.");

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
    if (!result.turnIndependent) this.notifyTurns(result.finished ? [] : result.awaiting, seat);
    if (result.finished) {
      const name = GAME_NAMES[room.game];
      for (const s of this.activeSeats()) if (s.seat !== seat) this.notify(s.seat, { kind: "turn", title: `${name}: that round is over`, body: "Tap to see how it ended." });
    }
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
      this.sql.exec("UPDATE room SET awaiting = '[]' WHERE id = 1");
      this.notifyTurns(result.awaiting, seat);
    } else {
      this.broadcastRoster();
      const name = GAME_NAMES[room.game];
      for (const s of seats) if (!s.rematch) this.notify(s.seat, { kind: "rematch", title: `Rematch in ${name}?`, body: "Someone wants to play again. Tap to answer." });
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
        // The earliest remaining player who has actually connected becomes the host.
        const next = this.sql.exec("SELECT seat FROM seats WHERE active = 1 ORDER BY connected DESC, idx LIMIT 1").one().seat;
        this.sql.exec("UPDATE room SET organizer = ? WHERE id = 1", next);
      }
    } else if (room.phase === "playing") {
      this.sql.exec("UPDATE room SET phase = 'ended', ended_message = ? WHERE id = 1", `${name} left the game. The match has ended.`);
      for (const s of this.activeSeats()) this.notify(s.seat, { kind: "ended", title: `Your ${GAME_NAMES[room.game]} game ended`, body: "A player left the game." });
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
    const written = this.sql.exec("UPDATE seats SET active = 0, removed = 1 WHERE seat = ? AND active = 1", target).rowsWritten;
    if (written !== 1) return;
    await this.touch();
    await this.syncDirectory();
    for (const s of this.ctx.getWebSockets(target)) { try { s.close(4001, "removed"); } catch {} }
    this.broadcastRoster();
  }

  /**
   * Lists an open lobby with a free seat in the directory, and takes it off otherwise. Only
   * while its host is connected: nobody should join (or be Quick-Played into) a lobby whose host
   * has gone. `closing`: a socket that's closing right now.
   */
  async syncDirectory(closing) {
    const room = this.room();
    if (!room || !this.env.DIRECTORY || room.open !== 1) return;
    const seats = this.activeSeats();
    const hostHere = this.ctx.getWebSockets(room.organizer).some((s) => s !== closing && this.isPresent(s));
    const listed = room.phase === "lobby" && hostHere && seats.length > 0 && seats.length < room.max_seats;
    const host = seats.find((s) => s.seat === room.organizer)?.nickname ?? "Player";
    await directory(this.env).fetch(listed ? "https://dir/upsert" : "https://dir/remove", {
      method: "POST",
      body: JSON.stringify({ code: room.code, game: room.game, host, seats: seats.length, maxSeats: room.max_seats, createdAt: room.created_at, address: room.address }),
    });
  }

  async alarm() {
    const room = this.room();
    if (!room) return;
    if (this.freeGhostSeats()) {
      this.broadcastRoster();
      await this.syncDirectory();
    }
    const expires = (room.phase === "lobby" ? room.created_at : room.updated_at) + TTL[room.phase];
    if (Date.now() < expires) return this.scheduleAlarm();
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
    try { this.sql.exec("ALTER TABLE lobbies ADD COLUMN address TEXT"); } catch {}
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/upsert") {
      const l = await request.json();
      // One address can't fill the list: past its share for this game, its lobbies are code-only.
      const others = l.address ? this.sql.exec("SELECT COUNT(*) AS n FROM lobbies WHERE address = ? AND game = ? AND code != ?", l.address, l.game, l.code).one().n : 0;
      if (others >= MAX_LISTED_PER_ADDRESS) {
        this.sql.exec("DELETE FROM lobbies WHERE code = ?", l.code);
        return json({ ok: true, listed: false });
      }
      this.sql.exec(`INSERT INTO lobbies (code, game, host, seats, max_seats, created_at, updated_at, address) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(code) DO UPDATE SET host = excluded.host, seats = excluded.seats, updated_at = excluded.updated_at`,
        l.code, l.game, l.host, l.seats, l.maxSeats, l.createdAt, Date.now(), l.address ?? null);
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
