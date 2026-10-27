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

## Update (same day): games first, chat off, open games

The owner, verbatim:

> I feel like I shouldn't have to connect to people to get a game going. I should be able to go
> straight to hosting a game and anyone using the app should be able to join.

And: "open the default and private the option. i will want to reintroduce chat later but for now
we can turn it off."

- **Chat off.** `AppFeatures.chatEnabled = false`. Games is the whole app, and Profile is in its
  toolbar. The chat code and its tests are untouched; flipping the flag restores the Chat tab,
  People, the connect guide, the match's Chat button and notifications.
- **Open by default, private as the option.** Online, an open game appears in the service's
  open-games list (a `LobbyDirectory` Durable Object) until it fills, starts or ends; a private
  game is code-only. Offline, an open game is offered to everyone nearby; a private one only to
  invitees.
- **No connecting needed offline.** Game traffic, and only game traffic, now flows with anyone
  nearby running CruiseLAN who isn't blocked (`SessionManager.playerIds`). Chat stays
  contacts-only.
- **Quick Play.** It joins the open game that has waited longest, or hosts a new open one, both
  online and nearby.
- **Safety for open games.** There's no chat in games. Nicknames are filtered. The host can
  remove a player before the start: online, that seat can't reconnect and Quick Play avoids that
  game; nearby, the removed player can't rejoin the lobby. Anyone can report a player from the
  lobby or the match; nearby reports also block. The privacy policy covers the open list.
