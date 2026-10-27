# Online games: the cloud hosts when the internet is reachable

Status: decided, implemented in 2.0 (25). Date: 2026-10-27.

## Why

Field tests on ships, in hotels (SpringHill_GUEST) and on public Wi-Fi found that client isolation
blocks phones from seeing each other on the network, and Nearby radio only reaches a few steps.
The owner's expectation, verbatim:

> when internet is reachable (online mode) the cloud service will host the game and when the
> device is on a network that has client isolation on or the internet is not reachable (offline
> mode) a device will host the game.

## What was decided

- **Hosting picks itself.**
  - `OnlineStatus` asks the service's `/v1/health`. A network merely being up doesn't count, so
    captive portals and not-yet-signed-in guest Wi-Fi read as offline.
  - Online: `GameCoordinator.hostLobby` creates a cloud room.
  - Otherwise, or if creating the room fails, the game is hosted on the phone exactly as in 1.x.
  - Client isolation with internet is **online**, because online games don't need phones to see
    each other.
  - A setting, "Profile › Games › Online games", turns online off for testing.
- **Same game screens.** The game views are untouched.
  - An online lobby is a normal `Lobby` with a `cloudCode`.
  - Player ids are the room's seats (`seat0`…), and `localId` is this phone's seat.
- **Joining.**
  - By an 8-character code, from anywhere.
  - Nearby friends also see online games in their list, because the lobby offer carries
    `cloudCode`; they join through the service, not the host's phone.
  - Older versions ignore the field. If an older version asks the host's phone to join, it gets
    "no longer available".
- **No migration.** A game stays where it started. If the internet drops mid-game, the app shows
  "Reconnecting…" and sends queued moves (same `moveId`, so exactly once) when the connection is
  back.
- **Relaunch.** The seat (code and token) is kept in the Keychain, and the app goes back into the
  game at launch. It's cleared when the game ends or the player leaves.
- **Rules.** The service runs the app's own Swift rules compiled to WebAssembly. Rules files must
  import nothing (`build-rules.sh` enforces it), and shuffles use 64-bit draws so seeded deals
  match on iOS and WebAssembly. See `server/game-worker/README.md` and
  `docs/architecture/CLOUDFLARE-SPIKE-RESULTS.md`.
- **Not in 2.0.**
  - Online chat. Chat stays mesh-only and end-to-end encrypted, which avoids server-side
    moderation of free text.
  - Push notifications for online turns.
  - Public matchmaking.

## Privacy

- The policy (`docs/site/privacy.html`) and `PrivacyInfo.xcprivacy` now declare Gameplay
  Content, used for app functionality, not linked and not tracked.
- **Still to do by hand.** The App Store Connect "App Privacy" answers must change from "Data Not
  Collected" to declare Gameplay Content (not linked to identity, not used for tracking) before
  2.0 is submitted for review.
