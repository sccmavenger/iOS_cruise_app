// Push notification checks, against the local dev server and a fake APNs on :9911
// (test/dev-server.sh points the server at it). Never reaches Apple.
//   test/dev-server.sh start && node test/push.mjs
import http from "node:http";
import WebSocket from "ws";

const BASE = "http://localhost:8787", WS_BASE = "ws://localhost:8787";
const sleep = (ms) => new Promise((s) => setTimeout(s, ms));
let passed = 0, failed = 0;
const check = (name, ok, detail = "") => { ok ? passed++ : failed++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok || !detail ? "" : ` — ${detail}`}`); };
const api = async (path, body) => (await fetch(BASE + path, { method: "POST", body: JSON.stringify(body) })).json();

// The fake APNs: records every request; tokens starting "dead" answer 410 like an uninstalled app.
const pushes = [];
const apns = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const token = req.url.split("/").pop();
    pushes.push({ token, headers: req.headers, payload: JSON.parse(body || "{}"), at: Date.now() });
    if (token.startsWith("dead")) { res.writeHead(410); return res.end('{"reason":"Unregistered"}'); }
    res.writeHead(200); res.end();
  });
}).listen(9911);
const to = (token) => pushes.filter((p) => p.token === token);
const token = (tag) => (tag + "0".repeat(64)).slice(0, 64);

class Seat {
  constructor(info) { Object.assign(this, info); this.inbox = []; }
  async connect() {
    this.ws = new WebSocket(`${WS_BASE}/v1/rooms/${this.code}/socket`, { headers: { Authorization: `Bearer ${this.token}` } });
    this.ws.on("message", (d) => { const m = JSON.parse(d); if (m.type === "snapshot") this.view = m.view; if (m.type === "roster") this.roster = m; this.inbox.push(m); });
    await new Promise((resolve, reject) => { this.ws.once("open", resolve); this.ws.once("error", reject); });
    this.send({ type: "resume" });
    await sleep(200);
    return this;
  }
  send(m) { this.ws.send(JSON.stringify(m)); }
  push(t) { this.send({ type: "push", token: t, sandbox: true }); }
  away() { this.send({ type: "away" }); }
  here() { this.send({ type: "here" }); }
}
const tttUp = (seats) => {
  const s = seats[0].view.ticTacToe._0;
  return s.outcome ? null : s.players[s.turn === "x" ? 0 : 1];
};

try {
  // 1. Someone joins while the host is away.
  const created = await api("/v1/rooms", { game: "ticTacToe", nickname: "Ann", open: false });
  const host = await new Seat(created).connect();
  host.push(token("aa"));
  host.away();
  await sleep(300);
  const guestInfo = await api(`/v1/rooms/${created.code}/join`, { nickname: "Bob" });
  await sleep(600);
  const joinPush = to(token("aa"))[0];
  check("The away host is notified when someone joins", joinPush?.payload.aps.alert.title === "Your Tic-Tac-Toe game is full", JSON.stringify(joinPush?.payload));
  check("…to the right app, as an alert, replacing older lobby alerts", joinPush?.headers["apns-topic"] === "com.dannyguillory.cruiselan" && joinPush.headers["apns-push-type"] === "alert" && joinPush.headers["apns-collapse-id"] === "lobby");
  check("…signed with a provider token", /^bearer [\w-]+\.[\w-]+\.[\w-]+$/.test(joinPush?.headers.authorization ?? ""));
  check("…opening the game when tapped, with no player names in it", joinPush?.payload.route === "game" && joinPush.payload.code === created.code && !JSON.stringify(joinPush.payload).includes("Bob") && !JSON.stringify(joinPush.payload).includes("Ann"));

  // 2. Present players aren't notified.
  const guest = await new Seat(guestInfo).connect();
  guest.push(token("bb"));
  host.here();
  await sleep(300);
  check("Coming back marks the host connected again", host.roster?.players.every((p) => p.connected));
  check("Coming back to the app clears away (no more pushes while looking)", to(token("aa")).length === 1);

  // 3. Start: the away guest hears about it.
  guest.away();
  await sleep(200);
  check("Others see an away player as not connected", host.roster?.players.find((p) => p.seat === guest.seat)?.connected === false);
  host.send({ type: "start" });
  await sleep(800);
  const guestStart = to(token("bb"));
  const guestUp = tttUp([host]) === guest.seat;
  check("The away guest is told the game started (or that it's their turn)",
    guestStart.length === 1 && guestStart[0].payload.aps.alert.title === (guestUp ? "Your turn in Tic-Tac-Toe" : "Your Tic-Tac-Toe game started"), JSON.stringify(guestStart.map((p) => p.payload.aps.alert)));
  check("The host, who is looking, gets nothing", to(token("aa")).length === 1);

  // 4. Turns: a move makes it the away guest's turn.
  if (!guestUp) {
    host.send({ type: "move", moveId: "h1", baseRevision: 0, move: { ticTacToe: { cell: 4 } } });
    await sleep(800);
  }
  const turnPushes = to(token("bb")).filter((p) => p.payload.aps.alert.title === "Your turn in Tic-Tac-Toe");
  check("The away player is told it's their turn", turnPushes.length === 1 && turnPushes[0].headers["apns-collapse-id"] === "turn");

  // 5. Bad and dead tokens.
  guest.send({ type: "push", token: "not-hex", sandbox: true });
  await sleep(200);
  check("A malformed token is refused", guest.inbox.some((m) => m.type === "error" && m.error === "badToken"));
  const dead = await api("/v1/rooms", { game: "colorMatch", nickname: "Dee" });
  const deadHost = await new Seat(dead).connect();
  deadHost.push(token("dead"));
  deadHost.away();
  await sleep(200);
  await api(`/v1/rooms/${dead.code}/join`, { nickname: "E" });
  await sleep(600);
  check("A push to an uninstalled app is tried once", to(token("dead")).length === 1);
  await sleep(10500); // past the throttle, so only a forgotten token explains silence
  const late = await api(`/v1/rooms/${dead.code}/join`, { nickname: "F" });
  await sleep(600);
  check("…and the dead token is forgotten", to(token("dead")).length === 1, `${to(token("dead")).length} sent; join ${JSON.stringify(late.error ?? "ok")}`);

  // 6. Throttle: joins and leaves over and over can't spam the host.
  const spam = await api("/v1/rooms", { game: "colorMatch", nickname: "Gus", open: false });
  const spamHost = await new Seat(spam).connect();
  spamHost.push(token("cc"));
  spamHost.away();
  await sleep(200);
  for (let i = 0; i < 6; i++) {
    const j = await api(`/v1/rooms/${spam.code}/join`, { nickname: `S${i}` });
    await fetch(`${BASE}/v1/rooms/${spam.code}/leave`, { method: "POST", headers: { Authorization: `Bearer ${j.token}` } });
  }
  await sleep(600);
  check("Six joins in a row notify the host once", to(token("cc")).length === 1, `${to(token("cc")).length} pushes`);
  check("…saying how many seats are taken", to(token("cc"))[0]?.payload.aps.alert.body === "2 of 4 players. Tap to start, or wait for more.", to(token("cc"))[0]?.payload.aps.alert.body);

  // 7. Someone leaves mid-game: the away player hears the game ended.
  await sleep(10500); // past the throttle for guest's "turn"
  host.here();
  guest.away();
  await sleep(200);
  const before = to(token("bb")).length;
  host.send({ type: "leave" });
  await sleep(800);
  const ended = to(token("bb")).slice(before);
  check("When a player leaves mid-game, the away player is told it ended", ended.length === 1 && ended[0].payload.aps.alert.title === "Your Tic-Tac-Toe game ended", JSON.stringify(ended.map((p) => p.payload.aps.alert)));

  // 8. Clearing the token stops pushes.
  const quiet = await api("/v1/rooms", { game: "chess", nickname: "Hal" });
  const quietHost = await new Seat(quiet).connect();
  quietHost.push(token("dd"));
  quietHost.send({ type: "push", token: "" });
  quietHost.away();
  await sleep(200);
  await api(`/v1/rooms/${quiet.code}/join`, { nickname: "I" });
  await sleep(600);
  check("A cleared token gets nothing", to(token("dd")).length === 0);

  for (const s of [host, guest, deadHost, spamHost, quietHost]) { try { s.send({ type: "leave" }); s.ws.close(); } catch {} }
} catch (e) {
  check(`crashed: ${e.message}`, false);
}
apns.close();
console.log(`\n${passed}/${passed + failed} checks passed`);
process.exit(failed ? 1 : 0);
