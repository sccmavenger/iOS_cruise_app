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
node test/scenarios.mjs           # protocol checks (56)
node test/attack.mjs              # security: cheating, snooping, squatting, flooding, spoofing (SPAM=1, SQUAT_WAIT=95000 for the slow ones)
node test/fuzz.mjs                # hostile moves straight into the rules (no server needed)
node test/soak.mjs 2 0.04         # every game to the end with random connection drops
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

- Moves are exactly-once by `moveId`, scoped to the seat (one player's ids can't touch another's). They are refused as stale with the same rule a phone host
  uses (Call One!, Catch! and resign are exempt), and committed before they're broadcast.
- Each socket only ever receives its own seat's projection.
- If the organizer leaves the lobby, the next player becomes host. Leaving mid-game ends the
  match for everyone.

## Abuse limits

- Per address: 60 room creates and 120 joins a minute; 240 invite-page or room-info lookups.
- Per socket: 40 messages in 10 s, or it's closed (the app reconnects). At most 2 sockets per seat.
- Lobby seats whose player never connects are freed after 90 s, so open games can't be squatted.
- One address lists at most 10 open lobbies per game; more are code-only. Hostless lobbies aren't listed.
- Moves must be based on a revision that exists. Bodies over 2 KB are refused without reading them.
- Nicknames lose control, format (direction overrides, zero-width) and private-use characters.
- The invite page shows no player names, runs no script, and can't be framed.

## What's stored, and for how long

Per room:

- game type and phase;
- seats: nickname, a SHA-256 hash of the seat token, rematch vote, join time, whether it ever connected;
- a keyed hash of the creating address (for the open-list limit; secret `ADDRESS_KEY`), never the address itself;
- the full game state and its revision;
- the move log (outcomes, for exactly-once).

An alarm deletes the room 24 h after creation if it never starts, 7 days after the last move, or
30 days after it ends. There are no accounts and no other database.
