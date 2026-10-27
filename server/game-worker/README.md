# CruiseLAN online games (Cloudflare)

This hosts games when players have internet. Each room is one Durable Object, and its built-in
SQLite storage is the only database. The game rules are the app's own Swift rules
(`iso_cruise_app/Games`) compiled to WebAssembly, so online and offline games follow the exact
same rules. Design: `docs/architecture/CLOUD-MULTIPLAYER-ASSESSMENT.md`. Spike evidence:
`docs/architecture/CLOUDFLARE-SPIKE-RESULTS.md`.

## Build, test, deploy

```bash
cd server/game-worker
npm install
./build-rules.sh                  # app rules → src/rules.wasm, then a native-vs-Wasm parity check
test/dev-server.sh start          # local Cloudflare runtime on :8787
node test/scenarios.mjs           # protocol checks (34)
node test/scenarios.mjs restart1; test/dev-server.sh stop; test/dev-server.sh start; node test/scenarios.mjs restart2
npx wrangler deploy               # → https://cruiselan-games.<account>.workers.dev
BASE=https://cruiselan-games.<account>.workers.dev node test/scenarios.mjs
```

The first `build-rules.sh` downloads the swift.org 6.4.1 toolchain and its WebAssembly SDK into
`~/Library/Caches/CruiseLAN-swift-wasm`. It checks the package signature and the published
checksum. Xcode's toolchain can't target WebAssembly.

**Rebuild the rules before deploying whenever a rules file changes.** The build refuses any rules
file that imports a module, because the rules must stay standard-library-only.

## Protocol v1

The protocol is documented at the top of `src/index.js`:

- **HTTP:** `POST /v1/rooms`, `POST /v1/rooms/:code/join` and `GET /v1/health`.
- **WebSocket:** `GET /v1/rooms/:code/socket` with `Authorization: Bearer <seat token>`. Messages
  are `resume`, `start`, `move`, `rematch`, `leave` and `ping`. The server sends `roster`,
  `snapshot`, `result`, `pong` and `error`.

Behavior:

- Moves are exactly-once by `moveId`. They are refused as stale with the same rule a phone host
  uses (Call One!, Catch! and resign are exempt), and committed before they're broadcast.
- Each socket only ever receives its own seat's projection.
- If the organizer leaves the lobby, the next player becomes host. Leaving mid-game ends the
  match for everyone.

## What's stored, and for how long

Per room:

- game type and phase;
- seats: nickname, a SHA-256 hash of the seat token, rematch vote;
- the full game state and its revision;
- the move log (outcomes, for exactly-once).

An alarm deletes the room 24 h after creation if it never starts, 7 days after the last move, or
30 days after it ends. There are no accounts and no other database.
