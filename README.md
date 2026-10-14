# CruiseLAN

Offline, nearby chat and turn-based games for iPhone. Phones talk directly to each other over MultipeerConnectivity (peer-to-peer Wi-Fi, infrastructure Wi-Fi, or Bluetooth). No internet, accounts, servers, or analytics.

> **Feasibility MVP.** CruiseLAN reaches devices *near* you. It is not a ship-wide network, and some Wi-Fi networks (including many on ships and in hotels) block devices from seeing each other. See [Known limitations](#known-limitations).

## Status

| Milestone | State |
|---|---|
| M1 — Offline chat | Done |
| M2 — Games tab, lobby, Tic-Tac-Toe | Done |
| M3 — Connect Four | Not started ("Coming soon" tile) |
| M4 — Color Match | Not started ("Coming soon" tile) |
| M5 — Hardening and handoff | Partial (see TEST-REPORT.md) |

## Requirements

- Xcode 27 (built and tested with 27.0, build 27A266a)
- iOS **26.0** or later, iPhone only. Chosen as the oldest OS with the Liquid Glass APIs the UI uses, so testers who haven't moved to iOS 27 can still install it.
- Team `CB4AAVWWUD`, bundle ID `com.dannyguillory.cruiselan`

## Build and test

```sh
open iso_cruise_app.xcodeproj         # scheme: iso_cruise_app
# Product › Test (⌘U) runs the Swift Testing suite in CruiseLANTests
```

Regenerate the app icon and illustration (rendered with SwiftUI, opaque PNGs):

```sh
xcrun swiftc -module-cache-path /tmp/swiftcache -o /tmp/render_artwork Tools/RenderArtwork.swift
/tmp/render_artwork iso_cruise_app/Assets.xcassets
```

## Testing on real iPhones

1. Install on two or more iPhones (TestFlight, or run from Xcode with a development profile).
2. On each phone: open CruiseLAN, pick a nickname, and **Allow** when iOS asks to find devices on your local network.
3. Keep Wi-Fi and Bluetooth **on**. You don't have to join a network; for an offline test, join a router with its WAN cable unplugged, or join nothing.
4. Phone A: **Chat › People** (top right) › tap the other phone under *Nearby* › **Invite**.
5. Phone B: **Accept** the "… wants to connect" alert within 30 seconds.
6. Chat: messages go to everyone you're connected to.
7. Games: **Games › Tic-Tac-Toe › Host a New Game**. The other phone sees "1 open game nearby" and can **Join**, or the host can **Invite** them from the lobby. The guest taps **I'm Ready**, then the host taps **Start Game**.

If nobody appears after about 20 seconds, the People screen shows troubleshooting tips. The most common cause is that Local Network permission is off: Settings › Privacy & Security › Local Network › CruiseLAN.

## Architecture

| Layer | Files | Notes |
|---|---|---|
| Transport | `Networking/PeerTransport.swift`, `MultipeerTransport.swift` | Protocol plus an MPC implementation. `MCSession` encryption `.required`. Advertiser, browser, and invitation accept/decline with a 30 s timeout. Refuses streams and resources. |
| Envelope codec | `Networking/Envelope.swift`, `EnvelopeCodec.swift` | Versioned JSON envelope `{version,id,kind,sessionId,senderId,sequence,payload}`. 32 KB cap. Strict per-kind validation. Typed errors, no `try!`. |
| Session | `Session/SessionManager.swift` | A `hello` handshake binds each transport peer to one announced id. Spoofed, replayed, stale, malformed, and flooding (more than 40 per 5 s) traffic is dropped. Routes chat and game traffic. |
| Lobby and game coordination | `Games/GameCoordinator.swift`, `GameEngine.swift` | The host is authoritative. Clients send `moveRequest`. The host checks seat, phase, turn, legality, move-id replay, and base revision, then sends a revisioned `stateSnapshot` to each player. A per-player projection hook is ready for Color Match's hidden hands. |
| Rules | `Games/TicTacToe/TicTacToeRules.swift` | Pure and deterministic. |
| UI | `ContentView`, `Chat/*`, `Games/*`, `Onboarding/*`, `Settings/*` | SwiftUI with Liquid Glass. Artwork is drawn with SwiftUI. VoiceOver labels on cells and actions. |

**Protocol addition:** a `hello` kind (identity handshake) was added to the v0.2 kind list. This lets receivers bind and verify `senderId` instead of trusting the payload.

**Identity:** each launch generates a random id. The short `#TAG` shown next to names comes from that id, so it changes every launch and can't be used to track anyone across sessions. Nicknames are not verified.

## Known limitations

- **Ship and hotel Wi-Fi:** client isolation and multicast filtering can prevent discovery. Being on the same SSID is not enough. Not tested on ship Wi-Fi.
- **Range:** limited to nearby devices. There is no relaying through other phones.
- **Background:** iOS pauses discovery and sessions when the app is backgrounded. A match does not survive the host disconnecting; it ends with an explanation.
- **Fairness:** the host device runs the game. This is a casual trust model, not cheat-proof.
- **Physical devices:** see TEST-REPORT.md. Simulator-to-simulator runs do not prove real-world discovery reliability.
