# Mesh networking

Status: decided, shipped in 1.8 (11). Date: 2026-10-16.

## Why

Apple's MultipeerConnectivity session links everyone in it to everyone else, and holds at
most 8 phones (`kMCSessionMaximumNumberOfPeers`). Before this change CruiseLAN used one
session per phone, so a group could never grow past 8, and everyone was within one radio hop
(tens of meters, and much less through a ship's steel decks). The owner wants to use the app
on a cruise, where friends and family spread across a large ship.

## What other mesh apps did, and what we took from them

| App | What happened | Lesson applied here |
|---|---|---|
| **FireChat** (Open Garden, 2014–2018/2020) | Used Multipeer. 100,000 installs in a day during the 2014 Hong Kong protests. Messages were sent unencrypted ("not meant for secure or private communications"), daily use stayed low because too few people nearby had it, and it shut down without notice. | Encrypt from day one. Make it useful with only 2–3 phones; the mesh is a bonus, not a requirement. |
| **Bridgefy** (2019–) | Royal Holloway (2020, then again with ETH Zürich after the move to Signal) found: no authentication (anyone could impersonate anyone), sender and receiver ids in plaintext (a social graph for anyone listening), unauthenticated broadcasts, a "zip bomb" message that crashed every phone in the network, and a man-in-the-middle at first contact with no way to verify keys. | Every packet is signed, and the sender's id *is* its key fingerprint. Recipients aren't named in packets. No compression, strict size limits, and a decoder that never traps. A visible tag (#A1B2) that can't be faked, for checking in person. |
| **bitchat** (Jack Dorsey, July 2025) | A Bluetooth mesh. Within a day, researchers showed the identity key was "decorative": impersonation, key interception, and a broken "favorites" trust system. The warning that it hadn't been reviewed was only added afterwards. | Same as Bridgefy: the identity is bound to the key cryptographically, not by convention. Honest wording in the app ("Names aren't verified, but the tag can't be faked"). |
| **Meshtastic / goTenna** | Radio-hardware meshes that work well using "managed flooding" with a hop limit, duplicate suppression, and small packets. | Flooding with TTL 6, duplicate ids, per-sender rate limits, and small packets. No routing tables to get wrong or poison. |
| **Developers running more than 8 phones on Multipeer** (Apple forums, Thali project, ConnectionPool) | Several sessions per phone work. Apple's DTS (Quinn) confirmed that one session auto-connects everyone, so you can't control the topology inside it. | **One two-phone session per link.** Each phone picks its own neighbors (up to 5), and nothing joins two strangers' sessions behind the user's back. |

Sources: [Breaking Bridgefy (IACR ePrint 2021/214)](https://eprint.iacr.org/2021/214.pdf),
[Royal Holloway on Bridgefy](https://www.royalholloway.ac.uk/research-and-education/subjects/information-security/news/using-messaging-service-bridgefy-could-have-dire-consequences-for-users-if-privacy-protection-issues-aren-t-fixed/),
[The Register on Bridgefy impersonation](https://www.theregister.com/security/2020/08/25/impersonating-users-of-protest-app-bridgefy-was-as-simple-as-sniffing-bluetooth-handshakes-for-identifiers/803080),
[FireChat (Wikipedia)](https://en.wikipedia.org/wiki/FireChat),
[FireChat fact check](https://88-bar.com/2015/01/fact-checking-the-hype-around-mesh-networks-and-firechat/),
[bitchat (Wikipedia)](https://en.wikipedia.org/wiki/BitChat),
[The Register on bitchat](https://www.theregister.com/off-prem/2025/07/08/jack-dorsey-floats-bitchat-messaging-app-based-on-bluetooth/672836),
[Apple forums: Multipeer topology](https://forums.developer.apple.com/forums/thread/81855),
[Dark corners of Multipeer (Thali)](https://medium.com/@baydet/dark-corners-of-multipeer-connectivity-framework-abd566422920),
[ConnectionPool](https://github.com/Olib-AI/ConnectionPool).

## Design

**Links (`MultipeerTransport`).** Every CruiseLAN phone in radio range links automatically,
up to `maxLinks` = 5. Each link is its own two-phone `MCSession`, so Apple's 8-phone limit no
longer applies to the group. Link requests are accepted without asking the user, because a
link only carries traffic (see "Safety model"). The phone that just came back invites first,
which is the reconnect rule we found in 1.7 testing. Blocked devices are refused.

**Identity (`MeshIdentity`).** Each phone has an Ed25519 signing key and an X25519 agreement
key, kept in the Keychain for 12 hours after last use and 24 hours at most (`IdentityStore`).
The id is a SHA-256 fingerprint of the signing key, and the tag shown after a name (#A1B2)
comes from the id. So no one can claim someone else's id or tag.

**Packets (`MeshPacket`).**
- Every packet is signed over everything except its hop counter.
- Private content is sealed with a fresh ChaCha20-Poly1305 key, and that key is wrapped once
  per recipient with the X25519/HKDF key the sender shares with them. Up to 64 recipients
  share one packet.
- The wrapped keys carry no names, so relays can't see who a message is for. Recipients find
  theirs by trying each one.
- Packets older than 10 minutes are dropped, so they can't be replayed later.

**Relaying (`SessionManager.handleIncoming`).** Each phone handles every packet the same way:
1. Verify it, and drop it if it's a duplicate.
2. Drop it if it's from a blocked person; those aren't even relayed.
3. Rate-limit the sender: at most 60 packets per 5 seconds at every phone, so a flood stops at
   its first neighbor.
4. Relay it to every other link with one less hop. A copy that arrives later by a shorter path
   is relayed again, so a slow long path can't cut a message short.
5. Open it if it's addressed to this phone.

The hop limit is 6.

**Directory.** Each phone floods a signed `announce` (nickname plus keys) every 20 seconds.
New links get an immediate announcement and the recent announcements of everyone else. A
contact who comes back into reach gets an answering announcement. Someone heard from within
50 seconds counts as reachable. When a link drops, people who might have been reached through
it get 8 seconds to answer a heartbeat; if this phone has no links left, they're away at once.

**Contacts and the safety model.** The mesh doesn't change who can talk to you:
- Only people you accepted, or who accepted you, are contacts.
- Chat, games, and notifications only happen between contacts. Anything else is dropped,
  however it arrives.
- Requests travel through the mesh and wait in People › Requests, with the same limits as
  before: no pop-ups, at most 5 waiting, and 10 minutes of quiet after a decline.
- Your phone relays other people's packets but can never read them.

**What other people learn.** Anyone running CruiseLAN within six phones of you can see your
nickname, your tag, and that you're online, the same as before but further than one radio hop.
Relays also see the *sender* of a packet. That's needed so every phone can rate-limit floods,
and the alternative (hiding it) would let anyone flood the mesh without being slowed. Relays
can't see who a packet is for, or what's in it.

## Considered and rejected

- **One big session per group of up to 8, plus "leader" bridges** (from the Apple forums). It's
  fragile: if a leader leaves, the groups split. It also still lets one person's session pull in
  strangers.
- **Bluetooth LE mesh like bitchat.** Too slow for chess snapshots, and Multipeer already uses
  Bluetooth and peer-to-peer Wi-Fi.
- **Routing tables / shortest paths** (as in ConnectionPool). They add state that can be wrong or
  poisoned. With the tens of phones on a ship, flooding is simpler and fast enough.
- **Signal-style ratchets (forward secrecy).** Identities already rotate within 24 hours and
  history isn't stored. A ratchet over a lossy, reordering mesh is a large project; we can
  revisit it if the app grows beyond family use.
- **Hiding the sender from relays.** That would make flood control impossible (see above).

## Known limits

- **Every phone that relays uses some battery and radio time,** and only while CruiseLAN is open.
  iOS ends peer-to-peer links in the background. Bluetooth nudges still reach contacts whose
  app is closed, but only within direct Bluetooth range.
- **First contact can be intercepted.** A person in the middle could intercept the first request,
  the same weakness the Bridgefy researchers found. The tag (#A1B2) is our answer: check it
  with the person.
- **Phones on 1.7 and earlier can't talk to 1.8.** The protocol version is now 2, so older
  phones aren't found.
- **Simulators share one network,** so real range and multi-hop behavior have to be tested on
  phones. The debug `-CruiseLANLinkOnly` switch forces a chain on simulators.

## Export compliance

The app now encrypts message content itself, with CryptoKit (ChaCha20-Poly1305, X25519,
Ed25519). These are all standard algorithms provided by Apple's operating system, which
Apple's App Store Connect guidance says requires no documentation. The build still declares
`ITSAppUsesNonExemptEncryption = NO`. Some guides argue that end-to-end messaging should
answer "yes" and claim the mass-market classification instead. **Confirm with an
export-compliance advisor before public release.** TestFlight is unaffected.

## Verified

- **Unit tests (257):**
  - Packets: signatures, tampering, impersonation (three ways), stale replay, multi-recipient
    sealing, and recipients not named on the wire.
  - Relaying: relaying, hop limit, flood control, and discovery through relays.
  - Contacts: requests, accept, and decline; reachability, link drop, and the outbox.
  - Two contacts chatting and playing Tic-Tac-Toe through a phone in between that can't read
    anything.
  - Twelve phones (beyond Apple's 8), and a twelve-phone line where the far ends are past the
    hop limit.
- **Three simulators on real MultipeerConnectivity, forced into a chain (Ana – Ben – Cal):**
  - Ana and Cal became contacts and swapped private messages through Ben within 2 seconds.
  - Ben received no chat and saw no contacts, and no packets were rejected on any phone.
  - When Ben left, Ana and Cal lost each other at once. When he returned, they reconnected
    within 3 seconds.
  - When Ana backgrounded, Cal saw her away at once, and they reconnected within 0.2 seconds
    of her return.
- **UI on a simulator:**
  - Cal showed under "Connected" as "Through 1 phone".
  - Ben showed under "People on CruiseLAN" as "Nearby" with Invite, then "Waiting…" after tapping.
