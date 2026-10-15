# CruiseLAN

Offline, nearby chat and turn-based games for iPhone. Phones talk directly to each other over MultipeerConnectivity (peer-to-peer Wi-Fi, infrastructure Wi-Fi, or Bluetooth). No internet, accounts, servers, or analytics.

> **Feasibility MVP.** CruiseLAN reaches devices *near* you. It is not a ship-wide network, and some Wi-Fi networks (including many on ships and in hotels) block devices from seeing each other. See [Known limitations](#known-limitations).

## Status

| Milestone | State |
|---|---|
| M1 — Offline chat | Done |
| M2 — Games tab, lobby, Tic-Tac-Toe | Done |
| M3 — Connect Four, Color Match | Done |
| M4 — Checkers, Chess | Done |
| M5 — Notifications, away-and-back matches, Bluetooth nudges | Done |
| App Store submission | Prepared. See [docs/app-store/SUBMISSION.md](docs/app-store/SUBMISSION.md) |

## Requirements

- Xcode 27 (built and tested with 27.0, build 27A266a)
- iOS **26.1** or later, iPhone only. 26.1 adds `tabViewBottomAccessory(isEnabled:)`, used for the "Back to game" bar.
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

**Identity:** each launch generates a random id, and the short `#TAG` next to names comes from it, so the tag changes every launch. Separately, the MultipeerConnectivity peer ID is reused across launches (Apple's recommendation) until the nickname changes. Its hash is how a phone remembers people it has blocked, and it never leaves that phone. Nicknames are not verified.

## Safety (kids)

- **Content filter** (`Safety/ContentFilter.swift`): runs fully on-device, on the sender (blocked messages are never sent) **and** on every receiver (so a modified app can't bypass it).
  - **Normalization:** look-alike Unicode letters, accents, full-width forms, invisible characters, leetspeak, stretched letters, spaced-out letters, and run-together names.
  - **Matching:** about 500 patterns in `Resources/SafetyTerms.txt` plus an allowlist so innocent words ("class", "Scunthorpe", "cockpit") pass.
  - **Personal info:** blocks phone numbers, emails, links, social handles, and cabin numbers.
  - **Nicknames:** inappropriate nicknames are rejected on onboarding and shown as "Player" when they come from others.
- **Term list** is generated by `Tools/build_safety_terms.py` from the `obscenity` dataset (MIT) and LDNOOBW (CC-BY-4.0, modified). Attribution is in Profile › Acknowledgements.
  - To regenerate: download the sources into a folder (see the script docstring), then run `python3 Tools/build_safety_terms.py <folder>`.
- **Block and Report:** touch and hold a message, or swipe a connected person in People.
  - Blocking hides that person's messages, lobbies, and invitations, and is remembered by device fingerprint across launches.
  - Three filtered messages from someone in one session blocks them automatically.
  - Report always blocks. It opens a pre-filled email once `SafetyConfig.reportEmail` is set. If Mail isn't set up, it shows the address instead. **That address must be set before App Store submission** (Guideline 1.2 requires published contact info). See `docs/app-store/SUBMISSION.md`.
- **Limitation:** MultipeerConnectivity can't drop a single peer from a session. A blocked person stays linked at the transport level, but nothing they send is shown and nothing is sent to them.

## Known limitations

- **Ship and hotel Wi-Fi:** client isolation and multicast filtering can prevent discovery. Being on the same SSID is not enough. Not tested on ship Wi-Fi.
- **Range:** limited to nearby devices. There is no relaying through other phones.
- **Background:** iOS stops MultipeerConnectivity when the app is backgrounded or the phone locks, so there are no message notifications while the phone is in a pocket. A Bluetooth Low Energy "doorbell" is the only server-free option; it's not built. A match does not survive the host disconnecting; it ends with an explanation.
- **Fairness:** the host device runs the game. This is a casual trust model, not cheat-proof.
- **Physical devices:** see TEST-REPORT.md. Simulator-to-simulator runs do not prove real-world discovery reliability.
