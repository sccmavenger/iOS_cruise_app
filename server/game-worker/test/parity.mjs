// Replays every request the native Swift build recorded through the WebAssembly build and
// requires byte-identical responses. Exits non-zero on any difference.
import fs from "node:fs";
import { createRules } from "../src/rules.js";
const rules = createRules(new WebAssembly.Module(fs.readFileSync(new URL("../src/rules.wasm", import.meta.url))));
const lines = fs.readFileSync(process.argv[2], "utf8").trim().split("\n");
let different = 0;
for (const line of lines) {
  const { request, response } = JSON.parse(line);
  if (rules.callRaw(JSON.stringify(request)) !== JSON.stringify(response)) {
    if (different++ < 3) console.log("DIFFERENT:", JSON.stringify(request).slice(0, 200));
  }
}
console.log(`parity: ${lines.length - different}/${lines.length} responses identical to native Swift`);
process.exit(different ? 1 : 0);
