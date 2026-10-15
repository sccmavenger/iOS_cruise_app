# CruiseLAN Test Report

**Date:** 2026-10-15
**Build:** 1.0 (2), branch `cruiselan-mvp`
**Tooling:** Xcode 27.0 (27A266a), iOS Simulator runtime 27

Results are **PASS**, **FAIL**, or **NOT RUN**. Anything run only in the Simulator is marked as such: a Simulator pass does **not** establish that discovery works on real devices or real networks.

## Automated tests

Swift Testing, target `CruiseLANTests`, run from the Xcode scheme `iso_cruise_app` on the iPhone Simulator.
**135 / 135 passed, 0 failed.**

| Suite | Tests | Covers |
|---|---|---|
| Envelope codec | 16 | Round-trip of all 15 kinds and the wire fields. Rejects garbage, truncated, empty, unknown-kind, kind/payload mismatch, oversized, wrong-version, and out-of-bounds payloads. |
| Nickname sanitizing | 4 | Whitespace, control and bidi-override stripping, empty input, character and byte limits. |
| Session manager (fake transport) | 14 | Hello binding. Duplicate packets. 20 messages in order. No traffic before hello. Spoofed sender. Identity hijack. Stale sequence. Malformed data. Rate limit. Send requires a peer. Disconnect notice. Invitations. Hello arriving before the connected callback. Late packet after disconnect. |
| Tic-Tac-Toe rules | 11 | X first. Row, column, and both diagonal wins. O wins. Draw. Occupied cell. Out of turn. Non-player. Lock after result. Rematch alternates. |
| Content filter | 69 | Clean kid phrases allowed (including Scunthorpe-style words). Profanity and sexual terms blocked. 17 evasion tricks caught (leetspeak, spacing, full-width, zero-width, Cyrillic, diacritics). Personal info blocked. Nickname handling. Performance. |
| Session safety (added to the session suite above) | 5 | Outgoing filtered messages never sent. Incoming bad messages hidden. Three strikes auto-blocks. Manual block removes messages and declines invitations. Blocks persist and can be undone. Bad nicknames shown as "Player". |
| Lobby and match sync (in-memory multi-device network) | 16 | Offer, join, ready, start. Identical win on both devices. Invalid client moves. Duplicate move id applied once. Stale base revision. Stale snapshot ignored. Snapshots and events from a non-host ignored. Forged sender. Host disconnect. Guest leave. Full lobby. Invite accept and decline. Rematch voting. Ended lobby not relisted. Blocking during games. Broadcast contents. |

**Bug found by tests and fixed:** a peer's `hello` could arrive before the local "connected" callback and get dropped, so that side never bound the peer's identity. Both builds 1 and 2 include the fix.

## Two-simulator end-to-end run (real MultipeerConnectivity)

**Setup:** two iOS Simulators on one Mac (iPhone 18 Pro as host, iPhone 18 Pro Max as guest).

**Result:** all 10 scripted steps passed.
- Discovery took a few seconds; it was too fast to time.
- Invite and accept worked.
- Chat worked in both directions with correct sender labels.
- Open-game join worked.
- Ready and start worked.
- A 5-move game ended in a win shown identically on both phones.
- Rematch started round 2 with the first player swapped.
- When the guest left, the host saw "Game over" with the reason.

**UI issues found in that run, all fixed:**
- The keyboard covered "Get Started" on onboarding.
- The chat keyboard was hard to dismiss.
- An ended game was still listed as open.
- Winning cells had low contrast.
- The leave dialog had no visible cancel button.
- The VoiceOver label read "You plays".

The winning-cell style and the leave alert were changed after the last simulator pass and have **not** been re-checked visually.

## Three-simulator group chat and safety run (2026-10-15)

**Setup:** iPhone 18 Pro (A), iPhone 18 Pro Max (B), and iPhone Air (C) simulators.

**Result:** all six checks passed.
- **Mesh:** A invited B, then C. B and C connected to each other automatically.
- **Group chat:** all six one-to-many deliveries arrived.
- **Onboarding:** the nickname "SexyKid" was rejected.
- **Sender-side filter:** "this is shit" and "add me on snapchat" were blocked with a kind explanation and never sent.
- **Report and block:** both worked, the blocked person's messages disappeared, and unblocking worked.

**Follow-ups:**
- The onboarding field now scrolls into view above the keyboard.
- The banner icon is now hidden from VoiceOver.

## Acceptance tests (05-ACCEPTANCE-TESTS.md)

| ID | Result | Evidence and notes |
|---|---|---|
| NET-01 | **NOT RUN** (physical) | Passed simulator to simulator only. A two-iPhone test on a router with the WAN unplugged is still needed. |
| NET-02 | **NOT RUN** (physical) | The Simulator doesn't show the Local Network prompt. The app shows tips and an "Open Settings" button after 20 s with no peers. Needs a check on a device. |
| NET-03 | PARTIAL | Disconnect status and notice are unit-tested, and the guest-leave path passed in the simulator. A physical reconnect hasn't been run. |
| NET-04 | **NOT RUN** | Needs a network with client isolation. The app shows troubleshooting guidance and never reports success without a bound peer. |
| MSG-01 | PASS (unit) / PARTIAL (sim) | 20 in-order messages tested in a unit test. One message each way checked in the simulator. |
| MSG-02 | PASS (unit) | Oversized and malformed envelopes are rejected and counted. |
| UI-01 | PASS (sim) | The Games tab shows all 3 titles. Connect Four and Color Match are marked "Coming soon", which is allowed for interim builds. |
| LOB-01 | PASS (unit) / PARTIAL (sim) | Invite, accept, decline, and full lobby are unit-tested. Open-game join passed in the simulator. |
| TTT-01 | PASS (unit) / PARTIAL (sim) | All lines tested in units. A row win was checked on both simulators. |
| TTT-02 | PASS (unit) / PARTIAL (sim) | Draw, wrong turn, occupied cell, and rematch tested in units. Rematch checked on both simulators. |
| C4-01, C4-02 | **NOT RUN** | Connect Four isn't implemented yet (M3). |
| CM-01 … CM-09 | **NOT RUN** | Color Match isn't implemented yet (M4). |
| SYNC-01 | PASS (unit) | A repeated move id produces exactly one transition. A stale base revision is rejected. |
| SYNC-02 | PASS (unit) | Host disconnect ends the match with an explanation. Not run on physical devices. |
| PRIV-01 | PARTIAL | Tic-Tac-Toe has no hidden information. The per-player projection hook exists for Color Match but isn't exercised yet. |
| A11Y-01 | PARTIAL | Cells, players, and actions have labels. A full VoiceOver pass on a device hasn't been done. |

## Not verified

- Anything on physical iPhones, including the Local Network permission prompt.
- 4-device sessions, and any multi-device session on physical phones (3 simulators passed).
- Ship or hotel Wi-Fi.
- Background and foreground transitions on a device.
- One unconfirmed observation: once, right after onboarding, the simulator briefly reported "Application is not responding". It recovered on its own and didn't happen again. Watch for it on devices.

## TestFlight

| Build | Contents | State |
|---|---|---|
| 1.0 (1) | Chat (M1, plus the hello fix) | Archived. Upload is **blocked** until the App Store Connect app record exists. |
| 1.0 (2) | Chat plus Tic-Tac-Toe (M2) | Archived. Upload is **blocked** for the same reason. |
