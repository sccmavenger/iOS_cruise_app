# Security testing of CruiseLAN 2.0 (online games)

Date: 2026-10-27. Scope: the online game service (`server/game-worker`, Cloudflare Workers +
Durable Objects), the app's online layer (`iso_cruise_app/Online`, the online part of
`GameCoordinator`), invite links, and the offline open-games path (game traffic from nearby
strangers). The goal was to break it: cheat, snoop, impersonate, squat, flood and spoof, as a
hostile player with a modified client or a script would.

Everything below can be re-run:

| Script | What it does | Run |
|---|---|---|
| `server/game-worker/test/attack.mjs` | 29 attacks against a running service; each check passes when the attack fails | `BASE=<url> node test/attack.mjs` (add `SPAM=1` for list flooding, `SQUAT_WAIT=95000` for seat squatting) |
| `server/game-worker/test/fuzz.mjs` | Hostile moves straight into the game rules (the same Swift rules a phone host runs, compiled to WebAssembly) | `node test/fuzz.mjs [gamesPerType] [movesPerGame]` |
| `server/game-worker/test/scenarios.mjs` | 56 protocol checks (regressions) | `BASE=<url> node test/scenarios.mjs` |
| `server/game-worker/test/soak.mjs` | Every game played to the end with random connection drops | `BASE=<url> node test/soak.mjs 2 0.04` |

## Attacks, results and fixes

"Before" is the service as shipped in 2.0 (25); "After" is after the fixes (deployed the same day).

### Cheating in a game

| Attack | Before | After |
|---|---|---|
| Two players move at once; the one who isn't up tries to move | Refused | Refused |
| Move twice in a row | Refused | Refused |
| Play an occupied square | Refused | Refused |
| Send a move "based on" revision 10^15, a board nobody has seen, to skip the stale-board check | **Accepted** | Refused (server and phone host) |
| Reuse another player's move id | **Got their result back** (`ok: true, duplicate: true`) | Ids are per seat; no collision, nothing leaked |
| Out-of-range cells, cards, squares, bids; wrong game's move; wrong types; 3,000-deep nesting; 5,000-character Catch target; unknown seats (fuzz, 74,291 calls) | No crash, no out-of-turn move accepted, no hand leaked | Same |

### Snooping on hidden cards

| Attack | Result |
|---|---|
| Read other players' hands from the start-of-game snapshot (Spades, 4 players) | Each player gets only their own 13 cards; all 52 distinct |
| Ask for a resync (`resume`) to get someone else's view | Only your own view is returned |
| Fuzz: any accepted move's views addressed to the wrong player | Never |

### Forging seats and authority

| Attack | Result |
|---|---|
| Use a seat token from another room | 401 |
| Made-up token / no token | 401 |
| Make someone else leave without their token | 401 |
| Non-host starts the game / removes a player | `notAllowed` |
| Host "removes" `seat99`, or an object instead of a seat | No effect |
| Remove a player after the game started | `notAllowed` |
| Join a game in progress | `alreadyStarted` |

### Malformed and oversized input

| Attack | Before | After |
|---|---|---|
| Non-JSON, `[]`, `null`, missing fields, string revision, 65-character move id, `__proto__` type, 20 KB message | Room survives | Same |
| 1 MB request body | Refused, but read into memory first | Refused while reading (2 KB cap, checked as it streams) |
| Odd paths: `..%2F`, `%00`, 9-character codes, double slashes | No 5xx | Same |

### Spoofing names and the invite page

| Attack | Before | After |
|---|---|---|
| Nickname with a right-to-left override, zero-width space, bell, bidi isolates (`‮evil` shows as "live") | **Kept** (only control characters were removed) | Stripped on the server (control, format, private-use, unassigned, separators; the zero-width joiner stays for emoji). The app already stripped them too |
| HTML in a nickname on the invite page (`<img onerror>`) | Escaped | Escaped, and names aren't shown at all |
| Abusive or misleading host name on the public invite page (unfiltered there; the app's filter doesn't run on the web) | **Shown** ("X invited you") | Page says "You're invited to play <game>" |
| Invite page scripting / framing (clickjacking) | **No CSP or frame protection** | `Content-Security-Policy: default-src 'none' …; frame-ancestors 'none'`, `X-Frame-Options: DENY`, `nosniff`, `no-referrer` |
| Junk code with a `<script>` in the invite URL | Not reflected | Not reflected |
| Room info for a private code reveals the host's name | **Yes** | No names returned |

### Denial of service and abuse

| Attack | Before | After |
|---|---|---|
| Open 12+ sockets for one seat (multiplies everything the room sends) | **All 12 stayed open** | At most 2 per seat; older extras closed (code 4002) |
| Flood 400 messages on one socket | **All 400 processed** | Over 40 in 10 s closes the socket (1008); the app reconnects by itself. Text pings don't count (Cloudflare answers them) |
| Take every seat of an open lobby over HTTP and never connect, so it can never start | **Lobby blocked until it expired (24 h)** | Seats that never connect are freed after 90 s (alarm), so real players get in |
| One address creates 25 open lobbies and keeps their hosts connected, filling the open list and catching Quick Play | **All 25 listed** | At most 10 listed per game per address; the rest are code-only |
| Unlimited refused moves growing the move log | **Unbounded** | Log trimmed to the last 2,000 (plus the flood limit) |
| Probing codes through the invite page and room info (not throttled) | **Unthrottled** | 240 a minute per address (joins stay 120/min, creates 60/min) |
| Ghost seat becomes host when the real host leaves | Possible | The earliest seat that actually connected takes over |

The address used for the open-list cap is stored only as an HMAC with a server secret
(`ADDRESS_KEY`, a Worker secret), so it can't be reversed by trying every IPv4 address. The
privacy policy says so.

### App-side review

| Area | Finding |
|---|---|
| Names from the server (roster, open list) and from nearby players | Already cleaned (`Nickname.sanitize`) and filtered (`ContentFilter`) before display |
| Server text shown to the user (ended message, move refusal) | Filtered; shown as plain `Text`, not Markdown |
| Snapshots from the online service | **Weren't structurally checked** (nearby ones were). Fixed: same `isStructurallyValid` check, so a broken or impersonated server can't hand the game screens a board they'd crash on |
| Phone host accepting a move "from the future" | **Same loophole as the server.** Fixed, with a unit test (`futureMoveRequest`) |
| Seat token storage | Keychain, `AfterFirstUnlockThisDeviceOnly`, never synced or backed up; cleared on fresh install, leave and game end; never logged or in diagnostics |
| Transport security | HTTPS/WSS only; no App Transport Security exceptions; the URL override exists only in Debug builds |
| Invite links | Only `cruiselan://join/CODE` and `https://<service>/join/CODE` are accepted; codes are normalized to the 8-character alphabet. A link while you're in a game asks before switching |
| Nearby game traffic from strangers | Packets are signed, rate-limited per link and per sender, blocked people dropped; envelopes are validated (seat counts, nicknames, codes, moves, snapshots); only the lobby's host is believed for rosters, starts, snapshots and events; one advertised game per host; strangers' invitations never pop up; removed players can't rejoin |

## End-to-end check after the fixes

On the simulator, against production: a private Tic-Tac-Toe game by code played to a draw; a
wrong code shows "There's no game with that code."; an open Color Match game with three bots,
joined from the open list (including a Wild Draw Four); hosting an open game with the share
sheet; 11 s in the background mid-game, then a clean reconnect. No 401, 403 or 429 and no
refused moves in normal play.

Final numbers: attacks 29/29 blocked, scenarios 56/56, soak 14 rooms / 2,179 moves / 91 forced
drops with no problems, fuzz 74,291 calls with no problems, app unit tests 387/387.

## Accepted risks

- **Code guessing.** Codes are 40 bits (about a trillion); guessing is throttled per address.
  Someone with many addresses can try faster, but finding a live game stays impractical.
- **Leaving ends the match** for everyone. By design; a griefer can only end games they're in.
- **Web pages can open invite links.** iOS asks before opening the app from a page, and the
  worst case is joining a game under your nickname.
- **Nicknames aren't filtered on the server.** The app filters every name it displays; the only
  web surface (the invite page) no longer shows names.
- **One ship shares one address,** so the per-address limits are generous; a determined attacker
  with many addresses could still add noise to the open list. The host can remove players and
  anyone can report.
