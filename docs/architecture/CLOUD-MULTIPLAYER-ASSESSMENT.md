# Cloud multiplayer assessment

Status: investigation and plan only. Nothing has been migrated, deployed or purchased, and the
app's behavior is unchanged. Date checked: 2026-10-27.

## 1. Executive recommendation

**Move the seven games' rules into a shared Swift package, `CruiseGameRules`, and run an
authoritative Swift server on Fly.io.** Use Hummingbird 2 with WebSockets, and store data in
SQLite on a Fly volume for the pilot, moving to Fly Managed Postgres when the pilot ends. Each
room is a Swift actor on one machine. A move is committed to the database before anyone is told
about it.

Offline play stays exactly as it is: phone-hosted games over Nearby radio or usable local Wi-Fi,
using the same package.

Why this choice:

- **The rules already port.** All seven games compile and pass their tests as a standalone
  package (see §3). The rules use only the Swift standard library plus one Foundation call,
  `String.capitalized`. That's about 2,800 lines of rules and 119 tests that wouldn't need to be
  rewritten in TypeScript and then kept in sync forever.
- **Correctness comes from one implementation.** The phone host and the cloud server run the same
  `GameEngine.apply` and the same `GameEngine.projection`. So a Spades deal or a Color Match
  challenge can't behave differently online.
- **It suits a solo developer.** It's one language and one test suite. A container deploy is a
  single `fly deploy`. The pilot costs about **$4–8 a month**.
- **The platform fits long-lived WebSockets.** Fly lets you configure the proxy idle timeout, and
  a volume can attach to only one machine. That gives the pilot a single writer per database by
  construction.

**What would change this choice:** see §8. The strongest alternative is Cloudflare Durable
Objects, which has a better per-room model and is cheaper at scale. It becomes the better choice
if the Swift rules can run inside a Durable Object as WebAssembly. That's plausible, because the
rules are stdlib-only, but it hasn't been verified.

## 2. Context and requirements

Field testing on cruise ships, in hotels (for example SpringHill_GUEST, which has client isolation
and a Nomadix gateway doing proxy ARP) and on public Wi-Fi showed two problems:

- Client isolation blocks the LAN transport.
- Nearby radio (MultipeerConnectivity) works, but only at short range.

| Requirement | How this plan meets it |
| --- | --- |
| The server owns state, validates moves, manages turns and deals cards | The server runs `GameEngine.apply`/`newGame`/`rematch` (§10) |
| Each player gets only what they may see | The server sends only `GameEngine.projection(of:for:)` for that seat (§11) |
| Offline phone-hosted play is kept | `GameCoordinator` and the transports are unchanged; online is a separate path (§9) |
| Players can be on different networks or in different cities | Plain HTTPS/WSS to a public host; no LAN needed |
| The room creator disconnecting doesn't end the game | The creator has no host role online; the room lives on the server (§12) |
| Private rooms and invitations only | Invite codes and links; no matchmaking (§10.1) |
| No moving a live match between online and offline | Out of scope for v1; the two modes are separate code paths |

## 3. Swift backend compatibility

### 3.1 What was inspected

- **Engine and protocol:**
  - `iso_cruise_app/Games/GameEngine.swift`
  - `iso_cruise_app/Games/GameProtocol.swift`
  - `iso_cruise_app/Games/Cards/PlayingCard.swift`
- **Each game's rules and models:**
  - `TicTacToe/TicTacToeRules.swift`
  - `ConnectFour/ConnectFourRules.swift`
  - `Checkers/CheckersRules.swift`
  - `Chess/ChessRules.swift`
  - `ColorMatch/ColorMatchModel.swift` and `ColorMatchRules.swift`
  - `Spades/SpadesModel.swift` and `SpadesRules.swift`
  - `Tonk/TonkModel.swift` and `TonkRules.swift`
- **Coupling:**
  - `Games/GameCoordinator.swift`
  - `Networking/Envelope.swift`
  - `Networking/EnvelopeCodec.swift`
  - `Session/IdentityStore.swift`
  - `Networking/MeshIdentity.swift`
- **Build settings:** `iso_cruise_app.xcodeproj/project.pbxproj`
- **Tests:** everything in `CruiseLANTests/`

### 3.2 Findings

**Imports.**
- Every rules and model file imports only `Foundation`.
- SwiftUI is limited to views: the `*View.swift` files, `PlayingCardView.swift`, and
  `EightByEightBoard.swift:1`. No rules file depends on a view.
- None of the rules files use UIKit, Combine, Observation, Network, Security/Keychain, CryptoKit,
  MultipeerConnectivity or CoreBluetooth.

**Foundation usage.** I deleted `import Foundation` from every rules file and compiled. The only
failure was `String.capitalized`, which appears twice:
- `ColorMatchModel.swift:10` (`CardColor.name`)
- `ChessRules.swift:17` (piece kind name)

With a two-line standard-library stand-in, the package builds and all tests pass. So the rules
are effectively pure Swift standard library, which is the same on Linux. Removing this last
Foundation call also keeps a future WebAssembly build small.

**Concurrency and isolation.**
- **App target:** `SWIFT_VERSION = 5.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
  `SWIFT_STRICT_CONCURRENCY = complete`, approachable concurrency on (project.pbxproj around
  lines 360–365 and 412–417).
- **Test target:** no default isolation (around lines 438 and 464).
- **Rules types:**
  - Every type is explicitly marked `nonisolated`, for example `GameProtocol.swift:5` and
    `GameEngine.swift:5`, so none of them pick up the app's default MainActor isolation.
  - They are all `Sendable` value types.
  - There's no global mutable state, no `@MainActor`, no `Task`, and no use of `Date`, clocks or
    timers.
- **Result:** in a package with default nonisolated isolation and Swift 6 language mode, they
  compile with **zero errors and zero warnings**.

**Randomness.**
- The rules take `inout some RandomNumberGenerator`, for example
  `ColorMatchRules.newMatch(players:using:)`, so they can be tested deterministically.
- `GameEngine` creates `SystemRandomNumberGenerator()` internally in `newGame` (line 32), `apply`
  (line 50) and `rematch` (line 73), so the server can't inject its own generator.
- `SystemRandomNumberGenerator` is cryptographically secure on Linux too (it uses `getrandom`).
  So this is a testability gap, not a security problem.

**Iteration order.** Swift randomizes `Set` and `Dictionary` ordering in each process. I checked
every use in the rules:
- They feed order-independent reductions: `allSatisfy`, `reduce`, and `Set(...).count`.
- Outward-facing arrays are sorted explicitly, for example `SpadesRules.swift:320`
  `legalPlays...sorted()`.
- Ties are broken deterministically, for example `SpadesRules.swift:285–286`.

So results don't depend on which process computes them.

**Codable and wire format.**
- **Public types are Codable already:** `GameMove`, `GameStateSnapshot`, every board state, and
  every snapshot type use synthesized `Codable`.
- **Hidden-hand states are not.** `ColorMatchState` (`ColorMatchModel.swift:80`), `SpadesState`
  (`SpadesModel.swift:28`), `TonkState` (`TonkModel.swift:60`) and `GameEngine.State`
  (`GameEngine.swift:8`) are deliberately not `Codable`, because they must never go on the wire.
  A server must persist them, so they need `Codable` for storage only. Adding synthesized
  conformance worked in the probe.
- **Size:** snapshots must fit in `EnvelopeCodec.maxEnvelopeBytes = 32 KiB`
  (`EnvelopeCodec.swift:18`). The largest host state I saw was Color Match at about 5.8 KB.

**Hidden-information projections.**
- `GameEngine.projection(of:for:)` (`GameEngine.swift:86`) is already the single
  information boundary.
- Board games send the full public state.
- The three card games send a per-viewer snapshot: own hand, counts, public piles.
- Event text (`lastEvent`) only names cards that are already face up: played, discarded, or taken
  from the discard pile. For example, `TonkRules.swift:138` says "Drew from the stock." and
  doesn't name the card.

**Coupling to the session layer.**
- The authority logic lives inside `GameCoordinator` (`@Observable`, MainActor by default,
  `GameCoordinator.swift:16`). That logic is:
  - exactly-once move ids (`seenMoveIds`);
  - revision and `turnRevision` stale-move checks (`hostHandleMove`, line 701);
  - commit and projection fan-out (`commit`, line 740);
  - rematch votes.
- It's mixed in with lobby management, `SessionManager` sends, Bluetooth relay to an away host,
  and `Task.sleep` timers.
- The comment at `GameCoordinator.swift:14–15` says it outright: "There is no host migration: if
  the host never returns, the match ends."
- None of this is portable as it stands. The pure part should be pulled out into a value type
  (§9).

**Other shared types.**
- **`GameType`** lives in `Networking/Envelope.swift:206`, a file that imports `CryptoKit` and
  holds chat, mesh and lobby payloads.
- **`MoveRequestPayload` and `StateSnapshotPayload`** (`Envelope.swift:301` and `:309`) are
  portable, but sit in the same file.
- **Identity and crypto:**
  - `IdentityStore` uses Security/Keychain, which is Apple-only.
  - `MeshIdentity` uses CryptoKit. That's Apple-only, but swift-crypto offers the same API on
    Linux.
  - Neither is needed by the rules.

**Tests.**
- The rules tests import only `Foundation` and `Testing`.
- They don't use `SessionManager`, `GameCoordinator` or a simulator.
- Their only app dependency is the constant `EnvelopeCodec.maxEnvelopeBytes`, used in size
  assertions.
- The 8 Tic-Tac-Toe tests are inside the mixed `CruiseLANTests.swift` (lines 146–220).
- `GameCoordinatorTests.swift` (44 tests) and the session tests are MainActor and coupled to
  `SessionManager`, so they stay in the app.

### 3.3 Per-game compatibility

| Game | Portable now? | Blocking dependencies | Required changes | Reusable tests |
| --- | --- | --- | --- | --- |
| Tic-Tac-Toe | Yes. Compiled and tested in the package on macOS; Linux not yet run | None | `public` API; move `GameType` into the package | 8 (`CruiseLANTests.swift:146–220`; move them to their own file) |
| Connect Four | Yes. Same status | None | `public` API | 9 (`ConnectFourRulesTests.swift`) |
| Checkers | Yes. Same status. The views use SwiftUI `EightByEightBoard` and stay in the app | None | `public` API | 11 (`CheckersRulesTests.swift`) |
| Chess | Yes. Same status | `String.capitalized` (`ChessRules.swift:17`); Foundation, not a blocker | `public` API; switch to a stdlib capitalize | 18 (`ChessRulesTests.swift`; one size test needs the 32 KiB constant) |
| Color Match | Rules yes. Server persistence needs a change | `ColorMatchState` and `PendingDrawFour` aren't `Codable`; `String.capitalized` (`ColorMatchModel.swift:10`) | Storage-only `Codable`; injectable RNG through `GameEngine.apply`; **add a `resign`/leave action** (Color Match has none, unlike the other six games) | 26 (`ColorMatchRulesTests.swift`) |
| Spades | Rules yes. Server persistence needs a change | `SpadesState` isn't `Codable` | Storage-only `Codable`; injectable RNG | 18 (`SpadesRulesTests.swift`) plus 1 size test |
| Tonk | Rules yes. Server persistence needs a change | `TonkState` isn't `Codable` | Storage-only `Codable`; injectable RNG | 25 (`TonkRulesTests.swift`) plus 1 size test |

**Shared files.** `GameEngine.swift`, `GameProtocol.swift` and `PlayingCard.swift` are portable
as they are. `GameType`, `MoveRequestPayload` and `StateSnapshotPayload` need to move out of
`Envelope.swift`.

## 4. Compilation and test results

The experiments ran in `/tmp/cruise-rules-probe` and `/tmp/cruise-rules-nofoundation`, outside the
repository. Rules and test files were **copied** in, with the only edit being the import line, so
no repository file changed.

| Experiment | Toolchain | Result |
| --- | --- | --- |
| The 13 rules/model/engine files plus `GameType` in a SwiftPM library, Swift 6 mode, default nonisolated | Xcode Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS arm64 | **Builds; 0 errors, 0 warnings** |
| The existing rules tests, copied unchanged except `@testable import CruiseGameRules`: Checkers, Chess, Color Match, Connect Four, Spades, Tonk, card snapshot sizes, Tic-Tac-Toe | same | **117 tests pass** in about 0.3 s, no simulator |
| Same sources with `import Foundation` removed | same | Only `String.capitalized` fails; with a stdlib stand-in it **builds and all tests pass** |
| Probe test: storage-only `Codable` on the hidden states | same | Builds. Plays each game with seeded random legal moves, up to its finish or a 400-move cap. The state is encoded and decoded before every move and is identical each time; the reloaded state accepts the same move (and gives the same result in the board games); moves by the wrong player are always refused |
| Probe test: projection leak check (Color Match, Spades, Tonk) | same | **Passes.** No viewer's projection contains another player's card ids or any `hands`/`drawPile`/`stock`/`discardPile` key |

Total: **119 tests passed**. Measured state sizes, as JSON:

| Game | Bytes |
| --- | --- |
| Tic-Tac-Toe | 169 |
| Connect Four | 429 |
| Checkers | 551 |
| Tonk | 819 |
| Spades | 856 |
| Chess | 1,765 |
| Color Match | 5,818 |

**Limitations:**

- **No Linux build was run.** This Mac has no Docker, Podman, Apple `container` tool, Linux VM
  or Swift Linux SDK. Installing Homebrew packages is blocked in this environment. A
  cross-compiling SDK would also need a swift.org toolchain, and it can't run tests anyway.
- **Unverified on Linux:**
  - that the package compiles there;
  - that the tests pass there;
  - `String.capitalized`, which swift-foundation provides on Linux but which hasn't been checked;
  - that JSON from Darwin Foundation and swift-foundation decodes the same both ways.

  The Foundation-free build strongly suggests the first two will hold, but that is not proof.
- **The probe's fuzz test** checks storage round-trips, not game strategy. For card games, a
  reshuffle draws fresh randomness, so only the board games compare outcomes after reload.
- **Not tested:** Hummingbird, the WebSocket layer, persistence code, and any hosting platform.

**How to verify on Linux.** Recreate the probe from the repository root, then run its tests in the
official Swift image. Use the tag matching the current release; swift.org lists 6.4.1, so try
`swift:6.4.1-noble`, then `swift:6.4-noble`.

```bash
P=/tmp/cruise-rules-probe; G=iso_cruise_app/Games
mkdir -p $P/Sources/CruiseGameRules $P/Tests/CruiseGameRulesTests
cp $G/GameProtocol.swift $G/GameEngine.swift $G/Cards/PlayingCard.swift \
   $G/TicTacToe/TicTacToeRules.swift $G/ConnectFour/ConnectFourRules.swift \
   $G/Checkers/CheckersRules.swift $G/Chess/ChessRules.swift \
   $G/ColorMatch/ColorMatchModel.swift $G/ColorMatch/ColorMatchRules.swift \
   $G/Spades/SpadesModel.swift $G/Spades/SpadesRules.swift \
   $G/Tonk/TonkModel.swift $G/Tonk/TonkRules.swift $P/Sources/CruiseGameRules/
sed -n '206,245p' iso_cruise_app/Networking/Envelope.swift > $P/Sources/CruiseGameRules/GameType.swift
for t in Checkers Chess ColorMatch ConnectFour Spades Tonk; do
  sed 's/@testable import iso_cruise_app/@testable import CruiseGameRules/' \
      CruiseLANTests/${t}RulesTests.swift > $P/Tests/CruiseGameRulesTests/${t}RulesTests.swift; done
sed 's/@testable import iso_cruise_app/@testable import CruiseGameRules/' \
    CruiseLANTests/CardGameSnapshotSizeTests.swift > $P/Tests/CruiseGameRulesTests/CardGameSnapshotSizeTests.swift
{ printf 'import Foundation\nimport Testing\n@testable import CruiseGameRules\n\n'; sed -n 146,220p CruiseLANTests/CruiseLANTests.swift; } \
    > $P/Tests/CruiseGameRulesTests/TicTacToeRulesTests.swift
echo 'enum EnvelopeCodec { static let maxEnvelopeBytes = 32 * 1024 }' > $P/Tests/CruiseGameRulesTests/Shims.swift
cat > $P/Package.swift <<'EOF'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "CruiseGameRules", targets: [
    .target(name: "CruiseGameRules", swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "CruiseGameRulesTests", dependencies: ["CruiseGameRules"], swiftSettings: [.swiftLanguageMode(.v6)]),
])
EOF
docker run --rm -v "$P":/pkg -w /pkg swift:6.4.1-noble swift test
```

Once the package exists in the repo, CI should run the same check on every push:

```yaml
# .github/workflows/rules-linux.yml
on: [push, pull_request]
jobs:
  linux:
    runs-on: ubuntu-latest
    container: swift:6.4-noble
    steps:
      - uses: actions/checkout@v4
      - run: swift test --package-path Packages/CruiseGameRules
```

The two probe tests are reproduced in §15 so they can be kept as permanent tests.

## 5. Hosting comparison

Sources were checked 2026-10-27 and are listed in §16.

### 5.1 Candidates

- **A1. Swift with Hummingbird 2 on Fly.io Machines.** Pilot storage is SQLite on a Fly
  volume; later, Fly Managed Postgres.
- **A2. Swift with Hummingbird 2 on Azure Container Apps (Consumption plan).** Storage is Azure
  Database for PostgreSQL Flexible Server.
- **B. TypeScript on Cloudflare Workers with Durable Objects.** One Durable Object per room,
  using its built-in SQLite storage. This needs a TypeScript port of all seven games.

Vapor would work as well as Hummingbird. Hummingbird 2 is preferred because it is smaller,
async/await-native, and has a first-party `hummingbird-websocket` package. Its Linux support and
exact version still need to be confirmed when Phase 2 starts.

### 5.2 Comparison

| Criterion | A1 Swift on Fly.io | A2 Swift on Azure Container Apps | B TypeScript on Cloudflare Durable Objects |
| --- | --- | --- | --- |
| Rule reuse | Full: same package as the app | Full | **None.** Seven games ported to TypeScript, plus parity tests kept forever, plus the Swift copy for offline |
| WebSockets and timeouts | Supported. Proxy idle timeout set by `http_options.idle_timeout`; Fly removed its TCP idle-close in 2023. Proxy restarts drain for up to 10 min, then drop | Supported. **Ingress request timeout is 240 s**; a longer idle timeout (up to 30 min) needs "premium ingress" on a dedicated D4+ workload profile. Heartbeats needed under 4 min | Supported. **Hibernation API:** clients stay connected while the object sleeps, and ping/pong is answered automatically. **Every deploy disconnects every WebSocket** |
| Durable state and restarts | A committed move is in SQLite on the volume before any broadcast. A restart reloads rooms lazily from disk. The volume lives on **one host and isn't replicated**; daily snapshots are kept 5 days by default (1–60) | State in Postgres (managed backups). Replicas restart on revision deploys and scaling | Each object has "durable, transactional, and strongly consistent storage". In-memory state is reset on hibernation, so it's rebuilt from storage |
| Two instances making conflicting moves | A volume attaches to only one machine, so there's one writer by construction. Also a compare-and-swap on `revision` in every write. When scaling out, route each room to its owner (`fly-replay`) and keep the compare-and-swap | Rolling revisions and scale-out mean **several replicas can run at once**. Needs a database compare-and-swap on `revision` plus per-room leases or session affinity | Built in: each object has a **globally unique name** and is **single-threaded** |
| Deployment complexity | Dockerfile plus `fly.toml`, `fly deploy`. Volume and backups to watch | Resource group, environment, registry, Postgres server, managed identity; the most moving parts | `wrangler deploy`. The repo already has a Worker scaffold (`server/telemetry-worker`) |
| Ongoing maintenance | Swift toolchain and image updates; SQLite file; later Postgres | Azure resources, Postgres version upgrades, ingress quirks | **Two rules implementations**, Cloudflare API changes |
| Idle cost and cold starts | Always-on machine from $3.69/mo; no cold start if autostop is off | One always-on replica ~ $14/mo; scale-to-zero would drop sockets and adds cold starts | $5/mo minimum covers the pilot; hibernation means no duration charge while idle |
| Scaling | Vertical first; then several machines with per-room routing | Horizontal replicas, but rooms must be pinned | Automatic, per room |
| Regional latency | One region near most testers (for example `iad`). Turn-based games tolerate about 100–200 ms | One region | A room is created near its first player and stays there |
| Storage and backups | Pilot: SQLite plus volume snapshots. Later: Managed Postgres (HA, automatic backups) from $38/mo | Flexible Server B1ms $0.017/h plus storage; managed backups | Included in the object; 5 GB-month included |
| Future Android | Server speaks JSON over WSS; an Android client only renders snapshots online. Offline Android hosting would need the rules in Kotlin, or Swift for Android (unverified) | Same as A1 | Same as A1 for online. Offline Android would mean a third implementation |
| Push notifications | APNs token auth from Swift (APNSwift); FCM over HTTP later | Same | APNs ES256 JWT signing with WebCrypto in a Worker; workable |
| Observability | Fly logs and Prometheus metrics; `swift-log` and `swift-metrics` | Azure Monitor and Log Analytics (extra cost) | Workers Logs, tail, analytics |
| Abuse controls | In the app: per-key and per-IP rate limits, size limits; optional App Attest | Same, plus IP restrictions at ingress | Same in the Worker; Cloudflare WAF and rate limiting available |

**Where authoritative state lives (all options).** It lives in durable storage, never only in
memory. An open WebSocket and an in-memory room are both treated as disposable caches.

Recovery after any restart works the same way:

1. The client reconnects and sends `resume {roomId, seatToken, lastRevision}`.
2. The server loads the room row (state, revision, seats) from storage.
3. The server sends that seat's projection.
4. The client re-sends any move it never saw acknowledged, using the same `moveId`.

## 6. Cost estimates

### 6.1 Assumptions

| Assumption | Value |
| --- | --- |
| Players per room | 2.5 on average (board games 2, card games 3–4) |
| Daily active hours | The stated concurrency, sustained for 6 h/day, 30 days |
| Moves per room | 4 a minute, all accepted |
| Messages | Each move sends a snapshot to every seat. Average snapshot 2 KB; Color Match up to ~6 KB |
| Heartbeats | One every 30 s, about 100 B with framing |
| Egress per connected player-hour | About 0.55 MB |
| Moves persisted per move | One move-log row (~300 B) plus an in-place state update |
| Retention | Finished rooms and their move logs purged after 30 days; abandoned lobbies after 24 h |
| Region | One US region (Fly `iad`, Azure `eastus`). Cloudflare places rooms automatically |

| Load | Rooms | Player-hours/mo | Moves/mo | Egress/mo | Stored data |
| --- | --- | --- | --- | --- | --- |
| Pilot | a few | under 1,000 | under 0.1 M | under 1 GB | under 0.1 GB |
| 100 concurrent | 40 | 18,000 | 1.7 M | ~10 GB | ~0.5 GB |
| 1,000 concurrent | 400 | 180,000 | 17 M | ~100 GB | ~5 GB |

### 6.2 Verified provider prices (2026-10-27)

**Fly.io:**
- `shared-cpu-1x`: $2.19/mo (256 MB), $3.69 (512 MB), $6.70 (1 GB)
- Volumes $0.15/GB-month
- Snapshots $0.08/GB-month, first 10 GB free
- Outbound data (North America/Europe) $0.02/GB
- Dedicated IPv4 $2/mo; shared IPv4/IPv6 free
- Stopped machines $0.15/GB-month of rootfs
- Managed Postgres: Basic $38/mo (shared-2x, 1 GB), Starter $72; storage $0.28/GB-month

**Azure (Retail Prices API, `eastus`, Consumption):**
- vCPU active $0.000024/s, idle $0.000003/s
- Memory $0.000003/GiB-s
- Requests $0.40 per million
- Free each month: 180,000 vCPU-s, 360,000 GiB-s, 2 M requests per subscription
- PostgreSQL Flexible B1ms $0.017/h; backup storage $0.095/GB-month
- Egress: first 100 GB/month $0, then $0.087/GB

**Cloudflare:**
- Workers Paid minimum $5/mo: 10 M requests and 30 M CPU-ms included
- No egress charges
- Durable Objects (Paid): 1 M requests/mo included, then $0.15/M; 400,000 GB-s included, then
  $12.50/M GB-s
- Incoming WebSocket messages billed 20:1
- Objects eligible for hibernation aren't billed for duration
- Durable Objects SQLite storage: 50 M rows written included, then $1.00/M; 5 GB-month included,
  then $0.20/GB-month

### 6.3 Monthly estimates

These are **estimates** built from the verified prices above and the assumptions in §6.1.

| Option | Pilot | 100 concurrent | 1,000 concurrent |
| --- | --- | --- | --- |
| **A1 Fly.io** | **≈ $4**: 1 × shared-1x 512 MB $3.69 + 1 GB volume $0.15 + egress ~$0.02. Adding a stopped standby machine adds ~$0.15 | **≈ $14**: 2 × shared-1x 1 GB $13.40 (one active, one for deploys) + 3 GB volume $0.45 + egress $0.20. **≈ $52** if moved to Managed Postgres Basic | **≈ $56–100**: 2 × 1 GB machines $13.40, or larger (not priced) + Managed Postgres Basic $38 + ~10 GB storage $2.80 + egress ~$2 |
| A2 Azure Container Apps | **≈ $30**: one always-on replica (0.25 vCPU, 0.5 GiB), billed at the active rate because an open WebSocket may not count as idle (unverified), ≈ $14.04 + Postgres B1ms $12.41 + storage ~$3–4 (storage rate not verified) | **≈ $50** with 1 replica (0.5 vCPU, 1 GiB) ≈ $33.48 + Postgres ~$16. **≈ $89** with a second replica for zero-downtime deploys | **≈ $185–200**: 2 replicas (1 vCPU, 2 GiB) ≈ $150 + a larger Postgres tier (not priced) ~$25–50; egress within the free 100 GB |
| B Cloudflare Durable Objects | **$5** minimum | **≈ $5**: ~0.1 M billable DO requests, ~11k GB-s, ~5 M rows written, all included | **≈ $7**: ~1.2 M DO requests (+$0.03), ~110k GB-s (included), ~52 M rows written (+$2) |

### 6.4 Main cost risks

- **Cloudflare, hibernation:** if anything stops an object hibernating (a `setTimeout`, unfinished
  work, or a non-hibernation WebSocket handler), duration is billed for as long as a socket is
  open. At 1,000 concurrent players that's 400 rooms × 0.125 GB × 648,000 s ≈ 32 M GB-s, about
  **$400/mo**. Turn timers must use Durable Object alarms.
- **Azure, idle billing:** with WebSockets open, the "idle" rate may not apply (a replica counts as
  idle only when it processes no HTTP requests, uses under 0.01 vCPU and receives under
  1,000 B/s). The estimates assume the active rate. Premium ingress for longer timeouts needs a
  dedicated profile and a $0.10/h plan management fee (≈ $73/mo).
- **Fly, durability:** a single volume is a single point of failure until Managed Postgres
  ($38/mo) or a replicated SQLite setup is in place. That's acceptable for a pilot and not for a
  public launch.
- **Every option, push notifications:** APNs is free. The risk is repeated sends on reconnect
  storms, so throttle per seat.
- **Every option, logs:** paid log retention (Azure Log Analytics in particular) can cost more
  than compute. Keep logs structured and short, and never log game state.

## 7. Recommendation

**A1: shared Swift rules, a Hummingbird 2 server on Fly.io, SQLite on a volume for the pilot, then
Fly Managed Postgres.** The reasons, grounded in this codebase:

1. **Correct game behavior.**
   - `GameEngine.apply` and `GameEngine.projection` already encode every rule and the hidden-card
     boundary.
   - Running the identical code on the server removes a whole class of "online behaves
     differently" bugs.
   - Color Match is the riskiest game to port: draw-four challenges and the Call One! window
     (`ColorMatchRules.swift:132–235`).
   - Spades nil and bag scoring is also intricate.
2. **Reuse of tested rules.** 2,805 lines of rules, models and engine, with 117 of their tests,
   move as they are. A TypeScript port would also need cross-language golden tests to stay
   trustworthy.
3. **Low effort for a solo developer.** It's one language, with the same `swift test` for the
   app's rules and the server, and one container on one host for the pilot.
4. **Predictable early costs.** About $4–14 a month until there's real demand, and the
   Fly prices are flat per machine.
5. **Reliable reconnects and saved games.**
   - Moves are committed to disk before they're broadcast.
   - Move ids are deduplicated in storage.
   - Rooms reload after a restart.
   - The single-volume, single-writer setup makes conflicting writers impossible during the
     pilot.

**Why not Azure Container Apps.** It works, but its 240 s ingress timeout, frequent replica
turnover and multi-replica rollouts all push extra work into the app. It's the most expensive of
the three, and it's the most to operate for a solo developer.

**Why not Cloudflare yet.** Its per-room model is the best fit for this problem, and it's the
cheapest. But choosing it today means keeping two rules implementations for as long as offline
play exists, which is permanently.

## 8. What would change the choice

- **Swift running inside a Durable Object.** Swift 6.2+ ships official WebAssembly SDKs. Our rules
  are stdlib-only apart from `capitalized`, which suits a small Wasm or Embedded Swift build.
  Workers allow 64 MiB of uncompressed script and 128 MB of memory per isolate. If a spike shows
  `GameEngine.apply`/`projection` running in a Durable Object under about 10 ms per move, at an
  acceptable binary size, then **Cloudflare with Swift-Wasm rules** gets both advantages and
  should replace A1. That's worth a one-day spike after Phase 3.
- **Scale beyond one machine.** At thousands of concurrent rooms, or if multi-region latency
  starts to matter, the per-room routing that Durable Objects provide becomes valuable. With
  Fly, you'd shard rooms across machines with `fly-replay` and move to Postgres.
- **Hosting evidence.** If Fly's proxy restarts drop sockets often enough to annoy players
  (measured through reconnect telemetry), or Fly regions are unreliable, A2 is the fallback. The
  Swift server is a plain container, so it moves without code changes.

## 9. Proposed structure

```
Packages/
  CruiseGameRules/            # new: pure rules, no Apple-only imports, builds on Linux
    Sources/CruiseGameRules/
      GameType.swift          # moved from Networking/Envelope.swift:206
      GameEngine.swift  GameProtocol.swift  PlayingCard.swift
      TicTacToe/ ConnectFour/ Checkers/ Chess/ ColorMatch/ Spades/ Tonk/   (Rules + Model only)
      MatchAuthority.swift    # new: pure host logic pulled out of GameCoordinator (below)
      Wire/GamePayloads.swift # MoveRequestPayload, StateSnapshotPayload, protocol version
    Tests/CruiseGameRulesTests/   # the 117 rules tests + MatchAuthority tests + probe tests
  CruiseOnlineProtocol/       # optional, later: client<->server message enums (Codable)
server/
  game-server/                # new: Swift executable (Hummingbird 2 + hummingbird-websocket)
    Sources/GameServer/  (RoomActor, RoomStore protocol, SQLiteRoomStore, Auth, RateLimit, APNs)
    Dockerfile  fly.toml
iso_cruise_app/               # app: views, GameCoordinator (offline), new OnlineMatchClient
```

**Changes inside the package:**

- Add `public` to the API the app and server use. About 880 declarations need review, mostly
  mechanical.
- Replace `capitalized` with a standard-library equivalent.
- Add `using rng:` overloads for `GameEngine.newGame`, `apply` and `rematch`. Keep the existing
  overloads, which use `SystemRandomNumberGenerator`.
- Add storage-only `Codable` to `ColorMatchState` (with `PendingDrawFour`), `SpadesState`,
  `TonkState` and `GameEngine.State`.
- Add a Color Match `resign` action.

**`MatchAuthority`** is a pure value type holding:

- `state: GameEngine.State`
- `revision` and `turnRevision`
- `seats`
- processed move ids, with their results
- `rematchVotes`

It has `mutating func handle(_ request: MoveRequestPayload, from seat: String) -> MoveOutcome` and
`func projections() -> [String: StateSnapshotPayload]`.

`GameCoordinator.hostHandleMove`/`commit` (lines 701–751) are rewritten to call it, so phone
hosting and the server share it. Offline behavior must stay byte-for-byte the same: the 44
`GameCoordinatorTests` are the guard.

**In the app:**

- A new `OnlineMatchClient` (`@Observable`, MainActor) built on `URLSessionWebSocketTask`.
- It feeds the same `GameStateSnapshot` to the existing game views, through the snapshot and
  `play(_:)` interface that `MatchContainerView` already uses.
- The offline `GameCoordinator`, `SessionManager` and the transports aren't touched.

## 10. Rooms, identity, moves and persistence

### 10.1 Room admission and identity

**No accounts in v1.** Credentials are scoped to a single room:

1. **Create.** `POST /v1/rooms {gameType, nickname}` returns:
   - `roomId`;
   - an organizer **seat token** (256-bit random, stored only as a SHA-256 hash on the server);
   - an **invite code**: 8 characters of Crockford base32 (about 40 bits), shown as `ABCD-EFGH`,
     plus a universal link `https://<domain>/join/ABCD-EFGH`.
2. **Join.** `POST /v1/rooms/join {code, nickname}` returns a seat token. Codes stop working when
   the room starts or fills, or after 24 h. The organizer can regenerate a code before start.
   Failed code lookups are rate-limited per IP: 10 a minute, with backoff.
3. **Storage on the phone.** The seat token is kept in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) under the room id, and deleted when the room
   ends.
4. **Why this design:**
   - There's no stable user id, so one person's rooms can't be linked together.
   - It matches the privacy stance of the current rotating mesh identity
     (`MeshIdentity.swift:12`).
   - The mesh identity itself is **not** reused online, because it rotates every few hours.
5. **Nicknames** go through the same sanitizing and filtering as offline:
   - `Nickname.sanitize`, then `ContentFilter`;
   - run on the server too, by moving `SafetyTerms.txt` and the filter into the package later;
   - for v1, sanitized on the server and filtered by both client and server.
6. **Optional hardening (Phase 4):** App Attest on room creation and joining, so scripts can't
   mass-create rooms.

### 10.2 WebSocket session and reconnect

- **Connect:** `wss://…/v1/rooms/{roomId}/socket` with `Authorization: Bearer <seatToken>`.
- **The client's first message** is `resume {lastRevision, protocolVersion}`.
- **The server replies** with `snapshot {revision, state}`, which is that seat's projection, plus
  the roster, presence and any rematch votes.
- **Heartbeats** every 25 s, below every platform's idle limit. Three missed heartbeats mark the
  seat as away.
- **Reconnect** with exponential backoff and jitter: 1, 2, 4 … up to 30 s. Reconnect immediately
  on a `NWPathMonitor` change or when the app returns to the foreground.
- A client never assumes its socket survives a background period, a network switch or a server
  deploy.

### 10.3 Move ordering, idempotency and persistence

- **Client to server:** `move {moveId: UUID, baseRevision, move: GameMove}`, reusing
  `MoveRequestPayload`. A move is retried with the **same** `moveId` until the server answers it.
- **The server processes moves for a room one at a time** in that room's actor, in arrival order:
  1. Look up `(roomId, moveId)` in `moves`. If it's there, re-send the stored outcome
     (accepted with its revision, or rejected with its reason) and stop. That's the idempotency
     guarantee.
  2. Check the seat, then apply the revision and `turnRevision` rules exactly as in
     `GameCoordinator.swift:707–710`. Turn-independent moves stay exempt
     (`GameEngine.isTurnIndependent`).
  3. Run `GameEngine.apply`. A thrown `MoveError` is stored as a rejected move and nothing else
     changes; the value types guarantee the state is untouched.
  4. **In one transaction:**
     - `INSERT INTO moves(room_id, move_id UNIQUE, seat, revision, move_json, outcome, at)`;
     - `UPDATE rooms SET state=?, revision=revision+1, updated_at=? WHERE id=? AND revision=?`.
     - If the update changes 0 rows, the write raced another writer: abort and reload. This
       compare-and-swap is the final guard against conflicting writers.
  5. **Only after commit:** send the result and each seat's projection to every connected seat.
- **SQLite settings:** WAL mode with `synchronous=FULL`, so a committed move survives a process
  crash or a machine restart. Volume snapshots cover machine loss up to the last daily snapshot.
  That gap is accepted for the pilot, and is the reason to move to Managed Postgres afterwards.
- **What's stored:**
  - `rooms` holds id, game type, phase, the full state as JSON, revision, turn revision, seats
    with token hashes, organizer, created, updated and expiry times.
  - `moves` holds the log described above.
  - The full state is stored at every revision rather than replayed from the log, because card
    games draw fresh randomness. The log is kept for auditing and debugging.

## 11. Hidden-card information boundaries

- The full `GameEngine.State` exists only in server memory and in the `rooms.state` column. It's
  never sent, logged, or returned by any endpoint.
- Every outbound state is `GameEngine.projection(of: state, for: seatId)`. The seat comes from
  the authenticated token, **never** from the request. There are no spectators in v1.
- Rejection messages come from `MoveError.message`, which never names another player's card.
- Server logs record room id, revision, seat index and move *type*, never card ids.
- **Tests** (carry the probe test forward; see §15):
  - no projection contains another seat's card ids or a `hands`/`drawPile`/`stock`/
    `discardPile` key;
  - a server integration test connects as seat A and checks every message it receives against
    seat B's hand.
- **Database access** is limited to the deployer. Purging after 30 days limits how much hidden
  state is kept.

## 12. Disconnects, turn timeouts, expiry and organizer departure

| Situation | v1 rule |
| --- | --- |
| A player disconnects | The seat shows as "away" after about 75 s (three missed heartbeats). The game continues. When they return, they get the current projection (§10.2). |
| It's an away player's turn | Others see "Waiting for Sam". After **5 minutes** away on their own turn, the other players may choose **End match** (recorded as abandoned, no winner) or keep waiting. There are no automatic moves in v1. |
| A connected player stalls | No timer in v1 (these are family games). A per-room turn limit can come later, implemented as a server timer, which becomes a Durable Object alarm if the hosting ever moves. |
| The organizer leaves before the start | The organizer role passes to the earliest-joined player. If nobody is left, the room closes. |
| The organizer disconnects or leaves during play | **Nothing special happens.** Online, the organizer has no host role; the server holds the game. Leaving counts as a normal player leaving. |
| A player leaves for good | Board games, Spades and Tonk: `resign`, which ends the match under the existing rules. Color Match: the new `resign` action, which ends the match. Removing a seat mid-game isn't supported in v1. |
| Room expiry | Lobby rooms not started within 24 h expire. Active rooms expire after **7 days** with no moves. Finished rooms are purged, with their move logs, **30 days** after they end. Seat tokens stop working when a room expires. |
| Server restart | Transparent: sockets reconnect, rooms reload from storage, and un-acknowledged moves are retried with the same `moveId`. |

## 13. Privacy disclosures

Online mode breaks claims the app makes today, so these must change **before** online mode ships,
even to TestFlight:

- **`docs/site/privacy.html`** currently says "no servers", "Nothing passes through us", and that
  chats and games are "kept only in memory". The policy needs a new **Online games** section
  covering:
  - what the server receives: nickname, game moves and state, seat tokens (stored as hashes),
    IP address while connected, and the push token if notifications are enabled;
  - the purpose;
  - retention: 30 days after a room ends, 24 h for unused lobbies;
  - the hosting provider and region;
  - that nothing is used for ads or tracking;
  - how to delete data: leaving a room deletes your seat token, and a contact route for
    deletion requests.
- **App Store "App Privacy":**
  - the current answer is "Data Not Collected";
  - online games mean declaring at least **User Content → Gameplay Content** (App
    Functionality);
  - possibly **Identifiers → User ID** if seat tokens or push tokens count as identifiers;
  - **Not used for tracking.**
  - Check each category against Apple's definitions when Phase 3 starts.
- **`PrivacyInfo.xcprivacy`:** add the matching `NSPrivacyCollectedDataTypes` entries.
- **Children:** the app is family-oriented. With no accounts, no free text online in v1 (no
  online chat), and filtered nicknames, the data stays minimal. Say so explicitly in the policy.
- **Export compliance:** HTTPS/WSS uses standard encryption only, which matches the current
  exempt answer. Re-check it when filing.

## 14. Phased implementation

Each phase ends with all existing app tests green (344 at last count) and the offline checks in
§14.1 passing.

**Phase 0: extract the rules package** (no behavior change)
1. Create `Packages/CruiseGameRules`. Move the rules, models, engine, `PlayingCard` and
   `GameType`. Move the game payloads out of `Envelope.swift`.
2. Add `public`, replace `capitalized`, add the `using rng:` overloads, add storage-only
   `Codable` to the hidden states, and add the Color Match `resign` action.
3. Move the rules tests, including the Tic-Tac-Toe suite pulled out of `CruiseLANTests.swift`,
   plus the two probe tests.
4. Add the Linux CI workflow from §4. **This settles the open Linux question.**
5. Link the package to the app target locally.

**Phase 1: `MatchAuthority`.** Pull the pure host logic out of `GameCoordinator`. Unit-test
exactly-once handling, stale revisions, turn-independent moves and rematch votes in the package,
and run them on Linux.

**Phase 2: server skeleton, local only.**
- Build the Hummingbird 2 app: room endpoints, the WebSocket protocol, the `RoomStore` protocol
  with a SQLite implementation (choose a Linux-supported driver such as `sqlite-nio`), seat-token
  auth, and rate limits.
- Build the Docker image.
- Integration tests run against the container.

**Phase 3: cloud-hosted Tic-Tac-Toe pilot.**
- Deploy to Fly: one `shared-cpu-1x` machine with 512 MB, a 1 GB volume, and autostop off.
- In the app, add **Play online → Tic-Tac-Toe** with create, invite link or code, and join, using
  `OnlineMatchClient` and the existing `TicTacToeView`.
- Ship the privacy updates in the same build.
- Run the pilot demonstrations (§14.2).

**Phase 4: hardening.** Optional App Attest, APNs "your turn" pushes (adds the `aps-environment`
entitlement, which the app doesn't have; it uses local notifications only today), structured logs
and metrics, a backup restore drill, and reconnect telemetry.

**Phase 5: remaining games.** Connect Four, Checkers and Chess first, since they have no hidden
information. Then Spades, Tonk and Color Match, with the server-side leak integration test
required for each.

**Phase 6: decision point.** Run the Swift-Wasm Durable Object spike (§8). Move to Managed
Postgres before any public release.

### 14.1 Acceptance tests that protect offline behavior

These run at every phase.

- All existing unit tests pass: Envelope, Session, GameCoordinator, Mesh, Nudge, Telemetry and
  rules.
- **No network:** with airplane mode on and Bluetooth on, a Nearby-radio Tic-Tac-Toe game and a
  Spades game run from start to finish between two phones, with no regressions in away, resume or
  relay behavior.
- **Local Wi-Fi without isolation, Nearby radio off:** an offline game still links over the LAN
  transport.
- **The online code stays idle unless chosen:** a network trace of an offline session shows no
  connections to the game server.
- The offline lobby, invites and `GameCoordinator` flows are unchanged. The `GameCoordinatorTests`
  are unmodified apart from the `MatchAuthority` refactor.

### 14.2 Pilot demonstrations (Phase 3 exit criteria)

| # | Demonstration | How |
| --- | --- | --- |
| 1 | **Nearby radio disabled** | Profile → Connections, Nearby radio off on both phones; the online game still works |
| 2 | **Players on different networks** | Phone A on home Wi-Fi, phone B on cellular (or in another city); both play to the end |
| 3 | **Isolated guest Wi-Fi with internet** | Both phones on a hotel or guest network with client isolation (the SpringHill_GUEST profile); the LAN transport fails, online play works |
| 4 | **Room creator disconnects** | The creator force-quits mid-game; the other player sees "away"; the creator reopens and finishes. Also: the creator leaves for good, and the room stays playable or ends under the §12 rules |
| 5 | **Returning players see the correct state** | Airplane mode for 2 minutes mid-game; on return the board and revision match the server, and moves queued while away were either applied once or refused |
| 6 | **Server restart keeps committed moves** | `fly machine restart` (and separately `kill -9` of the process) after move N; on reconnect the revision is N and the board matches |
| 7 | **Duplicate or invalid moves can't corrupt state** | A test client re-sends the same `moveId` 10 times, sends a stale `baseRevision`, plays out of turn, sends an occupied cell and an out-of-range cell. The state advances exactly once, every other attempt is rejected with the right reason, and the revision stays consistent |
| 8 | **No access to other players' private data** | Tic-Tac-Toe has none, so use automated tests: a seat token for room X can't open room Y; a missing or bad token is refused. For card games (Phase 5), the leak integration test from §11 |

## 15. Probe tests to keep

`Tests/CruiseGameRulesTests/ServerPersistenceProbeTests.swift`, as it was run in the probe:

- **`roundTripDuringPlay`** (all seven games):
  - plays seeded random legal moves until the game finishes or 400 moves have been played;
  - before every move, encodes and decodes `GameEngine.State` and expects equality;
  - checks that the reloaded state accepts the same move, with an identical result for the
    deterministic games;
  - checks that a non-acting player can't make a turn-bound move.
- **`projectionsHideOtherHands`** (Color Match, Spades, Tonk):
  - walks every `id` in each viewer's encoded projection;
  - expects none of them to be in another player's hand;
  - expects no `hands`/`drawPile`/`stock`/`discardPile` keys.

These need the storage-only `Codable` conformances from Phase 0.

## 16. Sources (checked 2026-10-27)

**Azure:**
- Container Apps pricing (page shows no rates; rates came from the Retail Prices API):
  https://azure.microsoft.com/en-us/pricing/details/container-apps/
- Retail Prices API queries used:
  - `https://prices.azure.com/api/retail/prices?$filter=serviceName eq 'Azure Container Apps' and armRegionName eq 'eastus' and priceType eq 'Consumption'`
  - same API for `Azure Database for PostgreSQL` (B1MS) and `Bandwidth`
- Container Apps billing, idle rules and free grants:
  https://learn.microsoft.com/en-us/azure/container-apps/billing
- Container Apps ingress (WebSocket support, 240 s request timeout, session affinity):
  https://learn.microsoft.com/en-us/azure/container-apps/ingress-overview
- Premium ingress idle timeout:
  https://learn.microsoft.com/en-us/azure/container-apps/ingress-environment-configuration and
  https://learn.microsoft.com/en-us/answers/questions/2280978/unable-to-use-premium-ingress-mode-to-extend-http

**Fly.io:**
- Pricing: https://docs.fly.io/about/pricing
- Volumes (single host, no replication, snapshots): https://docs.fly.io/volumes/overview/
- Managed Postgres: https://docs.fly.io/postgres/
- `fly.toml` `http_options.idle_timeout`: https://fly.io/docs/reference/configuration/
- TCP idle timeout removed: https://community.fly.io/t/tcp-idle-timeouts-restrictions-have-been-removed/15160
- Machine lifecycle and autostop: https://docs.fly.io/blueprints/long-running-tasks

**Cloudflare:**
- Durable Objects pricing: https://developers.cloudflare.com/durable-objects/platform/pricing/
- Durable Objects WebSockets and hibernation: https://developers.cloudflare.com/durable-objects/best-practices/websockets/
- What Durable Objects are (unique, single-threaded, storage): https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/
- Workers pricing (and D1): https://developers.cloudflare.com/workers/platform/pricing/
- Workers limits: https://developers.cloudflare.com/workers/platform/limits/
- Workers languages and Wasm: https://developers.cloudflare.com/workers/languages/
- WASI on Workers: https://blog.cloudflare.com/announcing-wasi-on-workers/

**Swift:**
- Linux install (6.4.1, Static Linux SDK, Wasm SDK): https://www.swift.org/install/linux/
- WebAssembly getting started: https://www.swift.org/documentation/articles/wasm-getting-started.html
- Swift Wasm sizes (secondary source): https://patchrelease.com/blog/swift-to-webassembly
- Hummingbird WebSocket: https://github.com/hummingbird-project/hummingbird-websocket
- Vapor: https://github.com/vapor/vapor

## 17. Verified vs. uncertain

| Verified | Still uncertain |
| --- | --- |
| The rules compile as a Swift 6 package with no isolation warnings (macOS) | Linux compile and test run (command in §4) |
| 117 existing rules tests pass outside the app, with no simulator | `String.capitalized` on Linux Foundation (it's being removed anyway) |
| The rules' only Foundation use is `String.capitalized` | That Darwin and Linux JSON round-trips match (expected; checked by CI in Phase 0) |
| The hidden states persist and reload exactly once `Codable` is added | Hummingbird 2 and SQLite driver versions and their Linux behavior |
| Card-game projections don't leak other hands at the deal | How often Fly proxy restarts drop sockets in practice |
| Provider list prices in §6.2 (as of 2026-10-27) | Azure Postgres storage price, and whether Azure bills an open WebSocket as idle |
| The Durable Object single-instance model, and that deploys disconnect sockets | Swift-Wasm in Durable Objects (size and speed) |
| | Every cost figure in §6.3 (estimates from the stated assumptions) |
| | The exact App Privacy categories for online mode |

## Appendix: probe test source

This is the exact file that ran in `/tmp/cruise-rules-probe`. It needs the storage-only `Codable`
conformances: `extension ColorMatchState: Codable {}`, `extension ColorMatchState.PendingDrawFour: Codable {}`,
`extension SpadesState: Codable {}`, `extension TonkState: Codable {}` and `extension GameEngine.State: Codable {}`, each
added in the file that declares the type.

```swift
import Foundation
import Testing
@testable import CruiseGameRules

/// Probe for a server that persists the authoritative state after every committed move:
/// a stored-and-reloaded state must be identical and must keep playing identically.
struct ServerPersistenceProbeTests {
    /// Every structurally possible move for a game, tried in a seeded random order.
    static func candidates(_ type: GameType, _ state: GameEngine.State) -> [GameMove] {
        switch state {
        case .ticTacToe: return (0..<9).map { .ticTacToe(cell: $0) }
        case .connectFour: return ConnectFourRules.columnRange.map { .connectFour(column: $0) }
        case .checkers(let s): return CheckersRules.legalSteps(in: s).map { .checkers(.move(from: $0.from, to: $0.to)) }
        case .chess(let s): return ChessRules.legalMoves(in: s).map { .chess(.move(from: $0.from, to: $0.to, promotion: $0.promotion)) }
        case .colorMatch:
            return (0..<ColorMatchRules.deckSize).flatMap { id in CardColor.allCases.map { GameMove.colorMatch(.play(cardId: id, chosenColor: $0, callOne: true)) } }
                + [.colorMatch(.draw), .colorMatch(.pass), .colorMatch(.respondToDrawFour(challenge: false)), .colorMatch(.respondToDrawFour(challenge: true))]
        case .spades: return (0...13).map { .spades(.bid(tricks: $0)) } + PlayingCard.deckRange.map { .spades(.play(cardId: $0)) }
        case .tonk(let s):
            let hand = s.hands[s.currentPlayer] ?? []
            return [.tonk(.drawFromStock), .tonk(.takeDiscard)] + hand.map { .tonk(.discard(cardId: $0.id)) }
        }
    }

    static func awaiting(_ state: GameEngine.State, players: [String]) -> [String] {
        let anyViewer = players[0]
        let ids = GameEngine.projection(of: state, for: anyViewer).awaitingPlayerIds
        return players.filter { ids.contains($0) }
    }

    @Test("Stored state reloads identically and keeps playing identically", arguments: GameType.allCases)
    func roundTripDuringPlay(type: GameType) throws {
        let players = (0..<type.maxPlayers).map { "player-\($0)" }
        var rng = SeededGenerator(seed: 7)
        var state = try #require(GameEngine.newGame(type, seats: players, using: &rng))
        var committed = 0
        var rejected = 0
        for _ in 0..<400 where !state.isFinished {
            let data = try JSONEncoder().encode(state)
            let reloaded = try JSONDecoder().decode(GameEngine.State.self, from: data)
            #expect(reloaded == state)
            guard let actor = Self.awaiting(state, players: players).first else { break }
            var applied = false
            for move in Self.candidates(type, state).shuffled(using: &rng) {
                // A move from someone else must never be accepted out of turn.
                if let other = players.first(where: { $0 != actor }), !GameEngine.isTurnIndependent(move) {
                    #expect((try? GameEngine.apply(move, by: other, to: state)) == nil)
                }
                do {
                    let next = try GameEngine.apply(move, by: actor, to: state)
                    // Reloaded state accepts the same move. (Card draws reshuffle with fresh
                    // randomness, so compare outcomes only for deterministic games.)
                    let fromReloaded = try GameEngine.apply(move, by: actor, to: reloaded)
                    if case .ticTacToe = state { #expect(fromReloaded == next) }
                    if case .connectFour = state { #expect(fromReloaded == next) }
                    if case .checkers = state { #expect(fromReloaded == next) }
                    if case .chess = state { #expect(fromReloaded == next) }
                    state = next
                    committed += 1
                    applied = true
                    break
                } catch {
                    rejected += 1 // value semantics: `state` is untouched by a refused move
                }
            }
            if !applied { break }
        }
        #expect(committed > 0)
        print("PROBE \(type.rawValue): committed \(committed) moves, refused \(rejected), finished \(state.isFinished), state \(try JSONEncoder().encode(state).count) bytes")
    }

    @Test("A projection never contains another player's hand or the deck", arguments: [GameType.colorMatch, .spades, .tonk])
    func projectionsHideOtherHands(type: GameType) throws {
        let players = (0..<type.maxPlayers).map { "player-\($0)" }
        var rng = SeededGenerator(seed: 11)
        let state = try #require(GameEngine.newGame(type, seats: players, using: &rng))
        let hands: [String: Set<Int>]
        switch state {
        case .colorMatch(let s): hands = s.hands.mapValues { Set($0.map(\.id)) }
        case .spades(let s): hands = s.hands.mapValues { Set($0.map(\.id)) }
        case .tonk(let s): hands = s.hands.mapValues { Set($0.map(\.id)) }
        default: return
        }
        for viewer in players {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GameEngine.projection(of: state, for: viewer)))
            let text = String(decoding: try JSONEncoder().encode(GameEngine.projection(of: state, for: viewer)), as: UTF8.self)
            for key in ["\"hands\"", "\"drawPile\"", "\"stock\"", "\"discardPile\""] { #expect(!text.contains(key), "\(key) leaked to \(viewer)") }
            // Every card id that appears anywhere in the viewer's projection is theirs or public.
            var seen = Set<Int>()
            func walk(_ node: Any, parentKey: String?) {
                if let dict = node as? [String: Any] { for (k, v) in dict { if k == "id", let n = v as? Int { seen.insert(n) }; walk(v, parentKey: k) } }
                else if let array = node as? [Any] { array.forEach { walk($0, parentKey: parentKey) } }
            }
            walk(json, parentKey: nil)
            for other in players where other != viewer {
                let leaked = seen.intersection(hands[other] ?? [])
                #expect(leaked.isEmpty, "\(viewer) can see \(other)'s cards \(leaked)")
            }
        }
    }
}
```
