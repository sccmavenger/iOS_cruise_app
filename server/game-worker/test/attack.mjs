// Security tests: a hostile client trying to cheat, snoop, squat, flood and spoof.
// Each check passes when the attack fails.   BASE=… node test/attack.mjs
import WebSocket from "ws";

const BASE = process.env.BASE ?? "http://localhost:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
const sleep = (ms) => new Promise((s) => setTimeout(s, ms));
let passed = 0, failed = 0;
const check = (name, ok, detail = "") => { ok ? passed++ : failed++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok || !detail ? "" : ` — ${detail}`}`); };
const post = (path, body, headers = {}) => fetch(BASE + path, { method: "POST", headers, body: typeof body === "string" ? body : JSON.stringify(body) });
const api = async (path, body) => (await post(path, body)).json();
const listed = async (game) => (await (await fetch(`${BASE}/v1/lobbies?game=${game}`)).json()).lobbies;

class Client {
  constructor(seat) { this.seat = seat; this.inbox = []; }
  connect(token = this.seat.token, code = this.seat.code) {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`${WS_BASE}/v1/rooms/${code}/socket`, { headers: { Authorization: `Bearer ${token}` } });
      this.ws.on("open", () => resolve(this));
      this.ws.on("unexpected-response", (_, res) => reject(new Error(String(res.statusCode))));
      this.ws.on("error", (e) => reject(e));
      this.ws.on("message", (d) => this.inbox.push(JSON.parse(d)));
      this.ws.on("close", (code) => { this.closed = code; });
    });
  }
  send(m) { this.ws.send(typeof m === "string" ? m : JSON.stringify(m)); }
  async next(type, ms = 3000) {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const i = this.inbox.findIndex((m) => m.type === type);
      if (i >= 0) return this.inbox.splice(i, 1)[0];
      await sleep(25);
    }
    return null;
  }
  async latest(type, ms = 600) { await sleep(ms); const all = this.inbox.filter((m) => m.type === type); this.inbox = []; return all.at(-1); }
  close() { try { this.ws.close(); } catch {} }
}

async function table(game, players, open = false) {
  const first = await api("/v1/rooms", { game, nickname: "Host", open });
  const seats = [first];
  for (let i = 1; i < players; i++) seats.push(await api(`/v1/rooms/${first.code}/join`, { nickname: `P${i}` }));
  const clients = await Promise.all(seats.map((s) => new Client(s).connect()));
  for (const c of clients) { c.send({ type: "resume" }); await c.next("roster"); }
  return { code: first.code, seats, clients };
}

// 1. Cheating in a game.
{
  const { seats, clients: [a, b] } = await table("ticTacToe", 2);
  a.send({ type: "start" });
  await a.next("snapshot"); await b.next("snapshot");
  const xSeat = seats[0].seat; // the rules give seat0 x in a new game? Find out from the snapshot.
  b.send({ type: "move", moveId: "m1", baseRevision: 0, move: { ticTacToe: { cell: 0 } } });
  a.send({ type: "move", moveId: "m2", baseRevision: 0, move: { ticTacToe: { cell: 0 } } });
  const ra = await a.next("result"), rb = await b.next("result");
  check("Only the player who's up can move", [ra?.ok, rb?.ok].filter(Boolean).length === 1, JSON.stringify({ ra, rb }));
  const mover = ra?.ok ? a : b, other = ra?.ok ? b : a;
  mover.send({ type: "move", moveId: "m3", baseRevision: 1, move: { ticTacToe: { cell: 1 } } });
  check("…and can't move twice in a row", (await mover.next("result"))?.ok === false);
  other.send({ type: "move", moveId: "m4", baseRevision: 1, move: { ticTacToe: { cell: 0 } } });
  check("…or play an occupied square", (await other.next("result"))?.ok === false);
  other.send({ type: "move", moveId: "m5", baseRevision: 1e15, move: { ticTacToe: { cell: 4 } } });
  const future = await other.next("result");
  check("A move claiming a revision from the future is refused", future?.ok === false, JSON.stringify(future));
  // Replaying someone else's move id doesn't apply anything or leak their result as ours.
  other.send({ type: "move", moveId: ra?.ok ? "m2" : "m1", baseRevision: 1, move: { ticTacToe: { cell: 8 } } });
  const replay = await other.next("result");
  check("Reusing another player's move id changes nothing", replay?.duplicate !== true || replay?.ok === false, JSON.stringify(replay));
  a.close(); b.close(); void xSeat;
}

// 2. Hidden cards: a player only ever receives their own hand.
{
  const { clients } = await table("spades", 4);
  clients[0].send({ type: "start" });
  const views = await Promise.all(clients.map((c) => c.next("snapshot")));
  const hands = views.map((v) => Object.values(v.view)[0]._0.hand);
  const all = hands.flat();
  check("Each Spades player gets a different 13-card hand", hands.every((h) => h.length === 13) && new Set(all).size === 52);
  const viewers = views.map((v) => Object.values(v.view)[0]._0.viewer);
  check("…and the view is addressed to them", viewers.every((v, i) => v === clients[i].seat.seat));
  check("…with no other hands in it", !JSON.stringify(views[0]).includes(`"hands"`));
  clients[1].send({ type: "resume" });
  const again = await clients[1].next("snapshot");
  check("Resume returns only your own hand", Object.values(again.view)[0]._0.viewer === clients[1].seat.seat);
  clients.forEach((c) => c.close());
}

// 3. Seats and tokens.
{
  const { code, seats, clients: [a, b] } = await table("chess", 2);
  const other = await api("/v1/rooms", { game: "chess", nickname: "Elsewhere" });
  const wrongRoom = await new Client(other).connect(other.token, code).then(() => "connected", (e) => e.message);
  check("A seat token doesn't work in another room", wrongRoom === "401", wrongRoom);
  const forged = await new Client(seats[0]).connect("0".repeat(64)).then(() => "connected", (e) => e.message);
  check("A made-up token is refused", forged === "401", forged);
  const noToken = await new Client(seats[0]).connect("").then(() => "connected", (e) => e.message);
  check("No token is refused", noToken === "401", noToken);
  const leaveForged = await post(`/v1/rooms/${code}/leave`, "", { Authorization: "Bearer nope" });
  check("Leaving needs the seat's token", leaveForged.status === 401);
  b.send({ type: "start" });
  check("Only the host can start", (await b.next("error"))?.error === "notAllowed");
  b.send({ type: "kick", seat: seats[0].seat });
  check("Only the host can remove players", (await b.next("error"))?.error === "notAllowed");
  a.send({ type: "kick", seat: "seat99" });
  a.send({ type: "kick", seat: { $ne: 1 } });
  await sleep(300);
  check("Kicking nonsense seats changes nothing", (await api(`/v1/rooms/${code}/join`, { nickname: "Third" })).error === "full");
  a.send({ type: "start" });
  await a.next("snapshot");
  a.send({ type: "kick", seat: seats[1].seat });
  check("Nobody can be removed once the game is on", (await a.next("error"))?.error === "notAllowed");
  const late = await api(`/v1/rooms/${code}/join`, { nickname: "Late" });
  check("Nobody can join a game in progress", late.error === "alreadyStarted");
  other.code && (await post(`/v1/rooms/${other.code}/leave`, "", { Authorization: `Bearer ${other.token}` }));
  a.close(); b.close();
}

// 4. Malformed and oversized input.
{
  const { clients: [a, b] } = await table("checkers", 2);
  a.send({ type: "start" });
  await a.next("snapshot");
  for (const bad of ["not json", "[]", "null", "{}", '{"type":"move"}', '{"type":"move","moveId":"x","baseRevision":"0","move":{}}',
    JSON.stringify({ type: "move", moveId: "y".repeat(65), baseRevision: 0, move: {} }), JSON.stringify({ type: "__proto__" }),
    JSON.stringify({ type: "move", moveId: "deep", baseRevision: 0, move: JSON.parse("[".repeat(2000) + "]".repeat(2000)) })]) a.send(bad);
  a.send("x".repeat(20000));
  await sleep(800);
  a.inbox = [];
  a.send({ type: "resume" });
  check("The room survives malformed messages", (await a.next("snapshot"))?.revision === 0);
  const big = await post("/v1/rooms", JSON.stringify({ game: "chess", nickname: "x".repeat(1e6) }));
  check("Oversized request bodies are refused", big.status === 400);
  const weird = await api("/v1/rooms", { game: "chess", nickname: "‮evil​\u0007⁦Admin⁩  " });
  const w = await new Client(weird).connect();
  w.send({ type: "resume" });
  const shown = (await w.next("roster"))?.players[0]?.nickname;
  check("Nicknames lose invisible and direction-flipping characters", shown === "evil Admin" || shown === "evilAdmin", JSON.stringify(shown));
  w.close();
  await post(`/v1/rooms/${weird.code}/leave`, "", { Authorization: `Bearer ${weird.token}` });
  for (const path of ["/v1/rooms/..%2F..%2Fx/join", "/v1/rooms/%00%00%00%00%00%00%00%00/info", "/v1/rooms/ABCDEFGHJ/info", "/v1/rooms/ABCD1234/socket", "/v1//rooms", "/v1/rooms/ABCD1234/../../health"]) {
    const r = await fetch(BASE + path, { method: path.endsWith("join") ? "POST" : "GET", body: path.endsWith("join") ? "{}" : undefined });
    if (r.status >= 500) check(`Odd path ${path} doesn't crash`, false, String(r.status));
  }
  check("Odd paths don't crash the service", true);
  a.close(); b.close();
}

// 5. Invite page: names can't inject HTML, and the page can't be framed.
{
  const evil = await api("/v1/rooms", { game: "chess", nickname: `<img src=x onerror=alert(1)>"'` });
  const page = await fetch(`${BASE}/join/${evil.code}`);
  const html = await page.text();
  check("Invite page escapes names", !html.includes("<img src=x") && !html.includes("onerror=alert(1)>"));
  check("Invite page forbids scripts and framing", /script-src 'none'|default-src 'none'/.test(page.headers.get("content-security-policy") ?? "") && /frame-ancestors 'none'/.test(page.headers.get("content-security-policy") ?? ""));
  const junk = await fetch(`${BASE}/join/%3Cscript%3Ealert(1)%3C%2Fscript%3E`);
  check("Invite page with a junk code shows no script", !(await junk.text()).includes("<script>alert"));
  await post(`/v1/rooms/${evil.code}/leave`, "", { Authorization: `Bearer ${evil.token}` });
}

// 6. Squatting: seats taken by someone who never shows up are freed, so open games can't be blocked.
{
  const host = await api("/v1/rooms", { game: "colorMatch", nickname: "Squatted", open: true });
  const h = await new Client(host).connect();
  h.send({ type: "resume" }); await h.next("roster");
  for (let i = 0; i < 3; i++) await api(`/v1/rooms/${host.code}/join`, { nickname: `Ghost${i}` });
  check("Ghost joins fill the lobby", (await api(`/v1/rooms/${host.code}/join`, { nickname: "Real" })).error === "full");
  await sleep(Number(process.env.SQUAT_WAIT ?? 0));
  if (process.env.SQUAT_WAIT) {
    const real = await api(`/v1/rooms/${host.code}/join`, { nickname: "Real" });
    check("…but seats nobody connected to are freed for real players", !!real.seat, JSON.stringify(real));
  }
  h.send({ type: "leave" }); h.close();
}

// 7. Flooding.
{
  const { seats, clients: [a, b] } = await table("connectFour", 2);
  const extra = [];
  for (let i = 0; i < 12; i++) extra.push(await new Client(seats[1]).connect().catch(() => null));
  await sleep(500);
  const open = [a, b, ...extra].filter((c) => c?.ws.readyState === WebSocket.OPEN && c.seat === seats[1]).length;
  check("One seat can't hold many sockets at once", open <= 3, `${open} still open`);
  extra.forEach((c) => c?.close());
  a.send({ type: "start" });
  await a.next("snapshot");
  for (let i = 0; i < 400; i++) a.send({ type: "move", moveId: `spam${i}`, baseRevision: 0, move: { connectFour: { column: 99 } } });
  await sleep(1500);
  const answered = a.inbox.filter((m) => m.type === "result").length;
  check("A message flood is cut off", answered < 400 || a.closed !== undefined, `${answered} answered, closed ${a.closed}`);
  a.close(); b.close();
}

// 8. Open list spam from one address.
if (process.env.SPAM) {
  const hosts = [];
  for (let i = 0; i < 25; i++) {
    const s = await api("/v1/rooms", { game: "tonk", nickname: `Spam${i}`, open: true });
    if (!s.code) break;
    const c = await new Client(s).connect(); c.send({ type: "resume" }); hosts.push(c);
  }
  await sleep(800);
  const mine = (await listed("tonk")).filter((l) => l.host.startsWith("Spam")).length;
  check("One address can't fill the open list", mine <= 12, `${mine} listed`);
  for (const c of hosts) { c.send({ type: "leave" }); c.close(); }
}

console.log(`\n${passed}/${passed + failed} checks passed`);
process.exit(failed ? 1 : 0);
