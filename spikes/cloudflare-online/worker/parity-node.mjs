// Replays every golden request through the WebAssembly rules and compares with native Swift.
import fs from "node:fs";
import { createRules } from "./src/rules.js";
const t0 = performance.now();
const module = new WebAssembly.Module(fs.readFileSync(new URL("./src/rules.wasm", import.meta.url)));
const t1 = performance.now();
const rules = createRules(module);
const t2 = performance.now();
const lines = fs.readFileSync(process.argv[2], "utf8").trim().split("\n");
let exact = 0, sameJSON = 0, different = 0; const firstDiffs = [];
const timing = {};
for (const line of lines) {
  const { request, response } = JSON.parse(line);
  const requestText = JSON.stringify(request);
  const start = performance.now();
  const actual = rules.callRaw(requestText);
  const ms = performance.now() - start;
  const game = request.game ?? Object.keys(request.state)[0];
  (timing[`${game}.${request.op}`] ??= []).push(ms);
  const expected = JSON.stringify(response);
  if (actual === expected) exact++;
  else if (JSON.stringify(JSON.parse(actual)) === expected) sameJSON++;
  else { different++; if (firstDiffs.length < 3) firstDiffs.push({ game, op: request.op, expected: expected.slice(0, 300), actual: actual.slice(0, 300) }); }
}
console.log(JSON.stringify({ requests: lines.length, exact, sameJSON, different, firstDiffs,
  compileMs: +(t1 - t0).toFixed(1), instantiateMs: +(t2 - t1).toFixed(1), memoryMB: +(rules.memory() / 1048576).toFixed(1) }, null, 1));
const pct = (a, p) => a.sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * p))];
for (const [k, a] of Object.entries(timing).sort()) console.log(`${k.padEnd(20)} n=${String(a.length).padStart(4)}  p50 ${pct(a, .5).toFixed(2)} ms  p99 ${pct(a, .99).toFixed(2)} ms  max ${Math.max(...a).toFixed(2)} ms`);
