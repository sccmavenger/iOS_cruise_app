// Hostile-input fuzz of the rules (the same Swift rules a phone host runs): random and malformed
// moves from every seat, in and out of turn. Checks that nothing crashes the module, that only
// the player who's up can change the game (except Call One!/Catch!/resign), and that refused
// moves change nothing.   node test/fuzz.mjs [gamesPerType] [movesPerGame]
import fs from "node:fs";
import { createRules } from "../src/rules.js";
import { candidates, inner } from "./soak.mjs";

const GAMES = Number(process.argv[2] ?? 40), STEPS = Number(process.argv[3] ?? 400);
const rules = createRules(new WebAssembly.Module(fs.readFileSync(new URL("../src/rules.wasm", import.meta.url))));
const SEATS = { ticTacToe: 2, connectFour: 2, checkers: 2, chess: 2, colorMatch: 4, tonk: 3, spades: 4 };
const problems = [];
const pick = (a) => a[Math.floor(Math.random() * a.length)];
const EDGE = [-1, -2147483649, 0, 1, 7, 8, 9, 42, 51, 52, 63, 64, 107, 108, 2147483648, 9007199254740991, 1e300, 0.5, "3", null, true, [], {}];
const int = () => (Math.random() < 0.5 ? pick(EDGE) : Math.floor(Math.random() * 120) - 5);

/** A random move, usually the right shape for some game, sometimes nonsense. */
function hostileMove(game, seats) {
  const r = Math.random();
  if (r < 0.04) return pick([null, 5, "x", [], {}, { [game]: null }, { [game]: { _0: "drop" } }, { chess: {}, spades: {} }]);
  if (r < 0.06) return JSON.parse("[".repeat(3000) + "]".repeat(3000)); // deep nesting
  if (r < 0.08) return { colorMatch: { _0: { catchOne: { target: "x".repeat(5000) } } } };
  const g = Math.random() < 0.85 ? game : pick(Object.keys(SEATS));
  const target = Math.random() < 0.7 ? pick(seats) : pick(["", "seat9", "seat0 ", "__proto__"]);
  switch (g) {
    case "ticTacToe": return { ticTacToe: { cell: int() } };
    case "connectFour": return { connectFour: { column: int() } };
    case "checkers": return { checkers: { _0: Math.random() < 0.05 ? { resign: {} } : { move: { from: int(), to: int() } } } };
    case "chess": return { chess: { _0: Math.random() < 0.05 ? { resign: {} } : { move: { from: int(), to: int(), promotion: pick([null, "queen", "king", "pawn", "x", undefined]) } } } };
    case "spades": return { spades: { _0: pick([{ bid: { tricks: int() } }, { play: { cardId: int() } }, { play: { cardId: int() } }, { resign: {} }]) } };
    case "tonk": return { tonk: { _0: pick([{ drawFromStock: {} }, { takeDiscard: {} }, { discard: { cardId: int() } }, { spread: { cardIds: Array.from({ length: Math.floor(Math.random() * 7) }, int) } }, { hit: { spreadId: int(), cardId: int() } }, { drop: {} }]) } };
    case "colorMatch": return { colorMatch: { _0: pick([{ play: { cardId: int(), chosenColor: pick(["red", "wild", null, 3]), callOne: pick([true, false, "yes"]) } }, { draw: {} }, { pass: {} }, { respondToDrawFour: { challenge: pick([true, false]) } }, { callOne: {} }, { catchOne: { target } }]) } };
  }
}

let calls = 0, accepted = 0, refused = 0;
function call(request) {
  calls++;
  try { return rules.call(request); } catch (e) { problems.push(`${request.op} threw: ${e.message.slice(0, 200)} — ${JSON.stringify(request.move)?.slice(0, 200)}`); return null; }
}

for (const game of Object.keys(SEATS)) {
  for (let n = 0; n < GAMES; n++) {
    const seats = Array.from({ length: SEATS[game] }, (_, i) => `seat${i}`);
    let current = call({ op: "new", game, seats });
    if (!current?.ok) { problems.push(`${game}: new failed`); continue; }
    for (let step = 0; step < STEPS && !current.finished; step++) {
      const seat = Math.random() < 0.9 ? pick(seats) : pick(["seat9", "", "seat0\u0000"]);
      // Mostly hostile moves; some real ones so games progress into later phases.
      const up = current.awaiting[0];
      const real = up && Math.random() < 0.35 ? candidates(game, current.views[up]) : null;
      const move = real?.length ? real[0] : hostileMove(game, seats);
      const mover = real?.length ? up : seat;
      const out = call({ op: "apply", state: current.state, seat: mover, move });
      if (!out) continue;
      if (!out.ok) {
        refused++;
        if (out.state) problems.push(`${game}: a refused move returned a state`);
        continue;
      }
      accepted++;
      if (!seats.includes(mover)) problems.push(`${game}: a move by unknown seat "${mover}" was accepted: ${JSON.stringify(move)}`);
      if (!out.turnIndependent && !current.awaiting.includes(mover)) problems.push(`${game}: ${mover} moved out of turn (awaiting ${current.awaiting}): ${JSON.stringify(move)}`);
      // Hidden information: no seat's view shows another seat's hand.
      for (const s of seats) {
        const v = inner(out.views[s]);
        if (v.viewer !== undefined && v.viewer !== s) problems.push(`${game}: ${s} got ${v.viewer}'s view`);
      }
      current = out;
    }
  }
  // The module must still work after everything above.
  if (!call({ op: "new", game, seats: ["a", "b", "c", "d"].slice(0, SEATS[game]) })?.ok) problems.push(`${game}: module broken after fuzzing`);
}
// Bad requests of every other kind.
for (const raw of ["", "{", "null", "[]", '{"op":"apply"}', '{"op":"new","game":"chess","seats":[]}', '{"op":"new","game":"chess","seats":["a","a"]}',
  '{"op":"new","game":"spades","seats":["a","b"]}', '{"op":"new","game":"tonk","seats":["a","b","c","d","e","f","g","h","i"]}', '{"op":"views","state":{"chess":{}}}',
  '{"op":"rematch","state":5}', '{"op":"apply","state":{"ticTacToe":{"_0":{"board":[],"players":["a"],"turn":"x"}}},"seat":"a","move":{"ticTacToe":{"cell":0}}}']) {
  calls++;
  try { const out = JSON.parse(rules.callRaw(raw)); if (out.ok && /seats":\[\]|"a","a"|"a","b"\]|"i"\]/.test(raw)) problems.push(`accepted bad request ${raw}`); }
  catch (e) { problems.push(`raw ${raw.slice(0, 60)} threw: ${e.message.slice(0, 160)}`); }
}
console.log(`${calls} calls, ${accepted} moves accepted, ${refused} refused, memory ${(rules.memory() / 1048576).toFixed(1)} MB`);
console.log(problems.length ? `PROBLEMS (${problems.length}):\n${[...new Set(problems)].slice(0, 30).join("\n")}` : "No problems.");
process.exit(problems.length ? 1 : 0);
