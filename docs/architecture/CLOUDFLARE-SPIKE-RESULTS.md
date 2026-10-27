# Cloudflare spike results: Swift rules in a Durable Object

Date: 2026-10-27. Status: **local and real-Cloudflare tests complete. Phone-on-real-networks
test ready for the owner** (§6.2).
The code is in `spikes/cloudflare-online/`; rerun everything with
`spikes/cloudflare-online/run.sh`.

The question: can our existing Swift game rules run on Cloudflare (Workers and Durable Objects),
so online games use the same code as offline games and nothing gets ported to TypeScript?

## 1. Answer

**Yes, as far as it can be tested on this Mac.**

- All seven games compile to WebAssembly with the official swift.org toolchain.
- In 5,339 recorded requests, the WebAssembly build gives byte-identical results to native Swift.
- They run in about 0.1–0.5 ms per move.
- In Cloudflare's own runtime (workerd, run locally), a room passed every pilot behavior the
  plan asks for, including a hard kill of the server with no committed move lost.

The same tests then ran **on real Cloudflare**, deployed to a `*.workers.dev` test address on the
owner's account (Free plan). All scenarios passed there too:
- rooms hibernate while idle and keep their sockets;
- **a deploy doesn't disconnect players**, and their open sockets are served by the new version;
- moves take about 70–110 ms from this Mac.

The only test left is two phones on real networks (§6.2).

## 2. What was built

| Piece | What it does |
| --- | --- |
| `swift/` | The app's rules, copied in by `run.sh`, with the Phase 0 changes applied to the copies: no Foundation, storage-only `Codable`, injectable randomness, and a 64-bit shuffle (§4). A JSON bridge (`Bridge.handle`) exposes four operations, `new`, `apply`, `rematch` and `views`, through four WebAssembly exports |
| `worker/src/rules.js` | Loads the WebAssembly module with a small WASI shim. Randomness comes from `crypto.getRandomValues`. File and other system calls refuse cleanly; the rules never use them |
| `worker/src/index.js` | A Worker that creates rooms and admits players by 8-character invite code and seat token, plus one `Room` Durable Object per room: SQLite tables `room`/`seats`/`state`/`moves`, hibernation-API WebSockets, a revision-checked commit before every broadcast, exactly-once move ids, per-seat projections, and a lobby-expiry alarm |
| `worker/*.mjs` | Tests: native-vs-WebAssembly parity, pilot scenarios, a restart test, a load test (local), plus hibernation and deploy tests (`deploytest.mjs`, `deploy-survival.mjs`) against the deployed Worker |
| `worker/src/page.js` | Spike-only browser test page for the phone test (§6.2) |

§3 was run locally with no account. §6 used a test Worker deployed to the owner's Cloudflare
account on the Free plan. The app is unchanged.

## 3. Results

### 3.1 Build

| Measure | Result |
| --- | --- |
| Toolchain | swift.org 6.4.1 (signed "Swift Open Source", notarized) and the 6.4.1 Wasm SDK (checksum matches swift.org) |
| Compile | All seven games plus the bridge build for `wasm32-unknown-wasip1` with **no errors and no warnings** |
| Size | **13.4 MB** raw, **3.8 MB** gzip, with `-Osize`, stripped. Cloudflare's limit is 64 MiB uncompressed. Most of it is Swift's JSON and Unicode support (FoundationEssentials), not our rules |
| Imports and exports | Imports 32 standard WASI functions; exports `cg_alloc`, `cg_free`, `cg_call`, `cg_out_len` |

### 3.2 Same results as native Swift (golden parity)

- A native Swift program played 3 seeded games of each title, up to 400 turns. It recorded every
  request and response: deals, legal moves, refused moves (wrong player, illegal card, occupied
  square and so on), rematches and reshuffles. That's **5,339 requests**.
- The WebAssembly build replayed them.
  - **First run: 27 mismatches, all at shuffles.** Swift's built-in `shuffle(using:)` draws
    random numbers sized to the platform's integer: 64-bit on iPhone and Mac, 32-bit in
    WebAssembly. So the same seed dealt a different deck. Every non-shuffle result already
    matched.
  - **After switching to a 64-bit Fisher–Yates shuffle (`portableShuffle`): 5,339 of 5,339
    byte-identical.**
- This doesn't affect fairness. Real games use fresh secure randomness, not seeds. But the fix
  belongs in Phase 0 so the cross-platform tests can cover dealing.

### 3.3 Speed of the rules in WebAssembly

These were measured in Node 24, which uses the same V8 engine as Cloudflare. Inside workerd the
clock is frozen while code runs, as a timing-attack defense, so the server can't time itself
precisely.

| Game | Move p50 | Move p99 | Worst |
| --- | --- | --- | --- |
| Tic-Tac-Toe | 0.14 ms | 1.97 ms | 1.97 ms |
| Connect Four | 0.19 ms | 0.51 ms | 0.51 ms |
| Checkers | 0.17 ms | 0.32 ms | 0.88 ms |
| Chess | 0.40 ms | 0.64 ms | 2.40 ms |
| Color Match | 0.51 ms | 2.40 ms | 5.28 ms |
| Spades | 0.11 ms | 0.61 ms | 0.76 ms |
| Tonk | 0.11 ms | 0.34 ms | 1.11 ms |

Each time includes decoding the stored state from JSON, applying the move, building every
seat's projection, and encoding the result.

- **Module load:** 16.5 ms to compile, 4.9 ms to start an instance.
- **Memory:** 2.7 MB.
- **Inside workerd:** the room reported 2–5 ms to initialize the rules on first use.

### 3.4 Pilot behaviors in a Durable Object (local workerd)

`node scenarios.mjs all`: **17 of 17 passed**, plus the restart test's **2 of 2**.

| Plan requirement | Check | Result |
| --- | --- | --- |
| Room admission | Create returns an 8-character code and a 64-hex seat token; a full or started room refuses joins | Pass |
| Players can't reach others' rooms | Wrong token → 401; a token from room Y can't open room X → 401 | Pass |
| Invalid moves can't corrupt state | Out of turn → `notYourTurn`; cell 9 → `outOfBounds`; occupied → `occupied`; old base revision → `staleBoard` | Pass |
| Duplicate moves can't corrupt state | The same move id 10 more times: same answer, revision still 1, board still has one mark | Pass |
| Room creator disconnects without losing the match | The creator's socket closes; the other player's move commits; the creator returns to the current state, including that move | Pass |
| Returning players get the correct state | `resume` returns the committed revision and that seat's view | Pass |
| A full game | Plays to a win; both players see the same final board | Pass |
| No access to others' private cards | Spades with 4 players, bids plus 20 cards played: 124 messages checked, none containing another seat's cards or any `hands`/`deck`/`stock`/`drawPile` | Pass |
| Server restart keeps committed moves | 4 Connect Four moves → **`kill -9` of the runtime** → restart → revision 4 with an identical view → the game continues at revision 5 | Pass |

### 3.5 Load (local, one process)

| Setup | Throughput | p50 | p95 | p99 |
| --- | --- | --- | --- | --- |
| 100 rooms, 200 WebSockets, Connect Four played to a win, 2,240 moves | ~1,050 moves/s | 27 ms | 62 ms | 83 ms |

- All 100 rooms shared one local process here. On Cloudflare each room is its own object spread
  across machines, so this is a floor, not a ceiling.
- For scale: the cost model's 1,000 concurrent players produce about **7 moves/s in total**.

## 4. Changes the spike shows the real package needs (Phase 0)

1. Remove `import Foundation` from the rules and replace `String.capitalized` (2 places).
   Confirmed sufficient.
2. Add storage-only `Codable` to `ColorMatchState` (with `PendingDrawFour`), `SpadesState`,
   `TonkState` and `GameEngine.State`. Confirmed.
3. Add `GameEngine.apply`/`rematch` overloads that take a generator. Confirmed.
4. **New:** use a 64-bit `portableShuffle` in Color Match, Spades and Tonk so seeded tests deal
   identically on iOS and WebAssembly. Confirmed. It's a 15-line function, and offline play is
   unaffected because real deals stay random.
5. **Wire format detail:** moves for games whose action has an unlabeled payload (Color Match,
   Checkers, Chess, Spades, Tonk) encode as `{"spades":{"_0":{"bid":{"tricks":3}}}}`, while
   Tic-Tac-Toe and Connect Four are `{"ticTacToe":{"cell":4}}`. That's fine, because the app and
   the server share the Swift types, but the v1 protocol should freeze it with a version field.

## 5. Risks and limits found

- **Binary size (13.4 MB)** is well inside the limit. A smaller binary would start faster on cold
  isolates. Possible savings: hand-written JSON instead of FoundationEssentials, or Embedded
  Swift (no `Codable`, so more work). Measure the real cold start before optimizing (§6).
- **The server can't time itself inside Workers.** Use client-side round trips and Cloudflare
  analytics for latency.
- **Deploys don't disconnect sockets** (§6.1), contrary to the documentation that was quoted.
  Clients still need reconnect plus `resume` for network changes and server restarts; the
  scenarios show that works.
- **Turn-independent moves** (Color Match's Call One!/Catch!, resign) aren't exempted from the
  stale-revision check in this spike. The real version reuses
  `GameEngine.isTurnIndependent`, as the app's host does.

## 6. Real-Cloudflare results

Deployed as `cruiselan-online-spike` to `https://cruiselan-online-spike.dguilloryjr.workers.dev`
(Free plan). The Mac reached Cloudflare's Newark (EWR) location: TCP about 40 ms, TLS finished at
about 100 ms. The test scripts are `scenarios.mjs`, `deploytest.mjs` and `deploy-survival.mjs`,
run with `BASE=<url>`.

### 6.1 Measured

| Test | Result |
| --- | --- |
| Upload | 13.1 MB (3.9 MB gzip) accepted; Cloudflare-measured Worker startup **2 ms** (the rules load on first use) |
| All 17 pilot scenarios (§3.4) against the real service | **17/17 pass** |
| Move round trip (commit plus broadcast), warm | **70–120 ms**, typically about 75 ms |
| Creating a room (a brand-new Durable Object) | **0.6–0.9 s**, once per room on "create" |
| First move after a deploy (new isolate, rules loaded fresh) | **~100 ms**; reconnecting both players and resuming took 0.4–0.7 s |
| Hibernation: both sockets idle 20 s | Sockets stayed open; **the object was rebuilt** (new instance id), so it was evicted from memory and not billed for duration while idle. The next move committed normally |
| Deploy while a game is active | Deploy took 10–12 s. **Sockets were not disconnected.** For 40–70 s afterwards they stayed open, `stats` replies came from the **new version id**, and a move on a pre-deploy socket committed |
| Deploy while the room is asleep | Same: sockets open, served by the new version, the move committed |
| Restart durability | Each deploy restarts every object; committed state was intact every time (revision and board identical) |

**One correction to the assessment.** It said "every deploy disconnects every WebSocket", quoting
Cloudflare's documentation. With the hibernation API, that didn't happen in four tests. The new
code took over the open sockets. Clients must still reconnect and resume after network changes,
but routine updates shouldn't kick players out of games.

**Not measured.** Billing totals, which only show up in the dashboard a day later, and alarm-based
expiry (set for 24 h, not waited for).

### 6.2 The test only the owner can run: phones on real networks

The deployed Worker also serves a test page (`src/page.js`, spike only) at
`https://cruiselan-online-spike.dguilloryjr.workers.dev`. It plays Tic-Tac-Toe through the cloud
room and shows connect time, move round trips and a running ping.

1. Phone A opens the page and taps **New Tic-Tac-Toe room**, then reads the code to phone B.
2. Phone B opens the page, enters the code, and taps **Join**.
3. Try these combinations:
   - one phone on cellular, the other on Wi-Fi;
   - both on an isolated guest Wi-Fi (the hotel case);
   - one phone in another city.
4. Mid-game, turn one phone's Wi-Fi off and on, or lock it for a minute. The page reconnects by
   itself and the board should be exactly where it was.

Note the ping and round-trip numbers in the **Connection** box.

When the tests are finished, delete the test Worker with
`cd spikes/cloudflare-online/worker && npx wrangler delete`. The page uses `?token=` in the
socket URL because browsers can't set headers; the app will send the token as a header.

## 7. How to decide

| If the real-Cloudflare tests show… | Then |
| --- | --- |
| Cold start under ~1 s and phone round trips that feel instant (under ~300 ms) | **Go with Cloudflare and the Swift rules**, as planned. On this Mac: room creation 0.6–0.9 s, moves about 75 ms, which meets this bar |
| Cold start of several seconds | Shrink the module (hand-written JSON or Embedded Swift), or keep rooms warm; retest |
| Hibernation not working (duration billed while idle) | Fix the socket handling, or fall back to a Swift server on a container host (Fly.io), which uses the same rules package |
| Reconnects after deploys feel bad | Deploy off-peak with client auto-resume; it's an operations issue, not a design one |
