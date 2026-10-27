# Persistent contacts: not re-adding friends every day

Status: **designed, not implemented.** Date: 2026-10-19.

Needs an explicit decision from the owner before coding, because it changes the mesh protocol
and touches game seating.

## Why

From the cruise notes:

> Not a fan of having to re-add people every time I open the app. If I added a friend then I
> should not have to re-add them later.

This is real and the cause is exact: `IdentityStore.lifetime` is 12 hours since last use, with
`maxAge` capping any identity at 24 hours. After that the saved identity — and with it the
entire contact list — is deleted and a new one is generated. On a seven-day cruise that means
re-adding everyone roughly daily.

## Why it was built that way

It isn't an oversight. The mesh id is a fingerprint of the signing key, and `NudgeService`
derives the Bluetooth service UUID that friends scan for from that same id
(`Nudge.serviceUUIDString(for:)`). So the id *is* the Bluetooth beacon.

A permanent id therefore means a permanent BLE beacon. Anyone with a cheap scanner — on the
ship, or anywhere else — could log that specific phone appearing at the pool at 2pm, the
casino at 9pm, the same bar every night, for the whole week and beyond. Rotating the id every
12–24 hours is what stops that, and [mesh.md](mesh.md) treats resisting that kind of tracking
as a first-order goal.

**So this is a genuine conflict, not a bug:** contacts want to be permanent, the beacon wants
to be ephemeral, and today they are the same value.

## Options

| Option | Keeps friends | Keeps anti-tracking | Cost |
|---|---|---|---|
| **A. Extend `lifetime` to ~10 days** | Yes | **No** — static beacon for the whole voyage | One line |
| **B. Persist the contact list but keep rotating the id** | No — friends survive a relaunch but their ids still change, so re-pairing still happens, just less often | Yes | Small |
| **C. Split the identity: stable contact key, rotating beacon** | Yes | Yes | Protocol change |

### Option A is a real regression

Tempting because it's one line, and worth being honest about: it would silently undo a
deliberate privacy property to fix an annoyance. If the owner wants it anyway as a stopgap for
the next voyage, it should at least be stated in the app's privacy copy, because
`ProfileView` currently implies the opposite.

### Option B doesn't actually solve the complaint

Saving contacts separately from the session identity makes them survive a relaunch, but
friends are still *keyed* by a mesh id that rotates. When their id changes they're a stranger
again. It reduces the frequency of re-adding without removing it, so it doesn't answer the
note.

### Option C is the right answer

Give each phone **two** identities:

- **Contact identity** — a long-lived Ed25519 key in the Keychain with no expiry. This is who
  you are to your friends. Never used for Bluetooth, never broadcast in the clear.
- **Session identity** — the existing key, rotating on today's 12/24-hour schedule. Drives the
  BLE beacon and the mesh id exactly as now.

The `announce` payload gains the contact public key, signed by the session key. A friend
receiving it verifies the signature, looks the contact key up in their saved list, and
recognises you even though your session id changed overnight. The beacon keeps rotating
because it's still derived from the session key.

This is the same shape as Find My and Exposure Notification: a stable long-term identity that
only trusted parties can link, plus a rotating public identifier that nobody else can follow.

## Why it isn't implemented yet

The change is larger than it sounds, and most of the cost is not in the crypto:

- `SessionManager` keys `knownIdentities`, `reachableIds`, `directory`, `outbox`,
  `inboundNudgeKeys` and `outboundNudgeKeys` by mesh id. All of those become contact-keyed.
- **`GameCoordinator` seats players by identity id** (`lobby.seats`, `StartGamePayload.seats`,
  `GameStateSnapshot.playerIds`). A mid-match identity rotation currently can't happen because
  the identity outlives any match; with two identities the seating must be pinned to whichever
  one is stable, or a rotation at the wrong moment unseats a player mid-game.
- `ChatStore` derives one-on-one conversation ids from identity ids
  (`ConversationRef.directId(localId, senderId)`), so existing conversations would need
  migrating or they'd fork.
- It's a wire-format change, so `protocolVersion` goes to `"3"` and phones on 1.8 can't link —
  meaning everyone has to update together.

None of that is hard, but it is a lot of surface to change without being able to test with
several real phones, and getting it wrong breaks games rather than just contacts. Shipping it
half-done would be worse than the current annoyance.

## Recommendation

Do option C as its own release, with the protocol bump, and test it with three or more devices
before the next voyage. If a voyage is imminent and C can't be finished in time, option A is
an acceptable *temporary* stopgap **only if** the privacy copy in `ProfileView` is updated to
match and it's reverted when C lands.

## Sources

- [mesh.md](mesh.md) — the identity and anti-tracking design this has to preserve.
- [Exposure Notification cryptography specification](https://covid19-static.cdn-apple.com/applications/covid19/current/static/contact-tracing/pdf/ExposureNotification-CryptographySpecificationv1.2.pdf)
  — rotating proximity identifiers derived from a stable key.
- [Find My network](https://support.apple.com/guide/security/find-my-security-sec6cbc80fd0/web)
  — the same split between a long-term key and rotating public identifiers.
