# LAN transport: working across a whole ship

Status: decided, implemented, **not yet validated on a ship**. Date: 2026-10-19.

Supersedes nothing. Builds on [mesh.md](mesh.md).

## Why

From the owner's notes, written aboard:

> Users will be on complete opposite sides of the ship. So users could potentially be
> hundreds of feet from each other. Right now the app only seems to work when users are
> nearby but the app should work via local LAN so no matter where a user is in a cruise ship
> as long as they are connected to the internal network they should be able to play the
> multiplayer games.

This is correct, and the cause is architectural rather than a bug or a tuning problem.

MultipeerConnectivity chooses its own bearers: Bluetooth, peer-to-peer Wi-Fi (AWDL), and
infrastructure Wi-Fi. For it to use the ship's actual network, three things all have to hold
at once:

1. both phones are on the same layer-2 subnet,
2. the network forwards multicast, because Bonjour/mDNS discovery depends on it, and
3. the access points allow client-to-client traffic at all.

Cruise guest Wi-Fi commonly withholds all three. "Client isolation" (also sold as AP
isolation or guest isolation) is the default on hospitality networks precisely to stop guests
reaching each other's devices. Multicast is usually rate-limited or dropped because it is
expensive on large wireless networks. And guests are frequently placed on per-AP or per-area
VLANs behind NAT, so two cabins aren't on the same subnet even when they're on the same SSID.

When those fail, Multipeer silently falls back to AWDL and Bluetooth. Both are proximity
radios. That is why the app behaved like a same-room app: it *was* one. The 1.8 mesh relay
extends this by hops, but a relay chain needs a continuous line of CruiseLAN users across the
ship, which won't exist.

**No amount of tuning the Multipeer transport fixes this.** Reaching the far end of a ship
needs a transport that uses the ship's network directly.

## What was considered

| Option | Verdict |
|---|---|
| **Tune Multipeer / raise `maxLinks`** | Rejected. Doesn't change which bearer Multipeer picks, and the bearer is the problem. More links only make the proximity mesh denser, not longer. |
| **Server on the internet** | Rejected. Shipboard internet is a paid add-on, often metered and slow. An app whose premise is "works without the internet" cannot require it. Also puts message content on someone else's machine, which [mesh.md](mesh.md) deliberately avoids. |
| **Bonjour over the ship LAN only** | Insufficient alone. Free and correct when it works, but it's exactly the mechanism client isolation and multicast filtering break. Kept as tier 1 because when it works it costs nothing. |
| **Direct IP with manual address entry only** | Works almost everywhere, but asking people to read out `192.168.14.203` is a bad experience and error-prone over dinner. Kept, but as the last resort and behind a short code. |
| **Subnet sweep (scan every host on the /24)** | Rejected. Hundreds of connection attempts per cycle is battery-hostile, looks exactly like hostile port scanning to any monitoring the ship runs, and risks the app being blocked outright. |
| **Layered tiers with telemetry** | **Chosen.** See below. |

## Decision

Add `LANTransport`, a second `PeerTransport` that speaks plain TCP over whatever network the
phone is on, and run it *alongside* `MultipeerTransport` rather than instead of it.

### Why both at once

`CompositeTransport` fans out to both and merges their events behind the single
`PeerTransport` that `SessionManager` already expects. The session layer needed no changes at
all: mesh logic is identical whether a neighbour is one deck away over Wi-Fi or across the
table over Bluetooth.

Running both also means the failure modes don't overlap. Bluetooth works when there's no
usable network; the LAN works when people are far apart. A phone with Wi-Fi off still works
exactly as it does today.

The same person may be reachable on both paths, producing two links and two copies of every
packet. **This is left uncorrected on purpose.** `SessionManager` already drops duplicates by
packet id, so the cost is a little radio time and the benefit is real redundancy — if one
path dies mid-game the other carries on with no reconnect. Collapsing the paths would mean
guessing which is better before we have any evidence, and the whole point of the telemetry is
that we don't yet know.

### Three discovery tiers

The owner asked how to make this "bullet proof guaranteed to work", and the honest answer is
that no single discovery mechanism survives every network. So each tier trades convenience
for reach, and all three run:

| Tier | Mechanism | Works when | Cost |
|---|---|---|---|
| 1. `lanBonjour` | `NWListener` advertising `_cruiselan-lan._tcp`, `NWBrowser` finding it | mDNS is forwarded between clients | None — fully automatic |
| 2. `lanBroadcast` | Small UDP beacon to `255.255.255.255` every 4s | Multicast is dropped but broadcast still passes | Negligible battery; still automatic |
| 3. `lanJoinCode` | One phone shows an 8-character code encoding its IPv4; the other types it | Discovery is blocked entirely but unicast still works | Needs a human to read a code aloud |

Tier 2 exists because multicast and broadcast are filtered independently on most hospitality
gear — a network that drops mDNS often still passes broadcast. Tier 3 exists because it is
the only tier that needs no discovery at all, and therefore the only one that can work on a
network that forwards nothing between clients.

**If all three fail, the network has true client isolation and no peer-to-peer app can work
on it.** In that case the app falls back to the radio transport, which is exactly today's
behaviour — so this change can only improve reach, never reduce it. The troubleshooting page
says so plainly instead of leaving the user guessing.

### Why telemetry decides the rest

Per the owner's instruction: ship all tiers, measure, decide later. Every tier reports
`linkConnectedByTier` on success and `tierAttemptFailed` on failure, so after one voyage
"which of these actually works on a ship" becomes a measured fact. Tiers that never carry
traffic can then be dropped, and the default order changed, with evidence. See
[telemetry.md](telemetry.md).

## Security

**Link encryption.** TLS 1.2 with a pre-shared key, `TLS_PSK_WITH_AES_128_GCM_SHA256`. (Originally TLS 1.3, but Network.framework doesn't support external PSKs over 1.3: every handshake failed with -9858, so no LAN link connected until 1.9 (21). Verified with a standalone listener/connection pair on macOS.)

**The PSK is not a secret, and nothing depends on it being one.** It's derived from a fixed
label compiled into the app, so every CruiseLAN user has it, and anything in an iOS binary is
recoverable with `strings`. It buys confidentiality against someone passively sniffing the
ship's network who doesn't have the app. It buys *no* authentication.

Authentication is `MeshPacket`, unchanged: every packet is signed by a key its sender's id is
derived from, private content is sealed per recipient, and relays can't read what they carry.
A link is only ever a pipe. This is the same bargain `MultipeerTransport` already makes —
`encryptionPreference: .required` with `certificateHandler(true)` — so the LAN tier is no
weaker than the radio tier it sits beside.

**Join codes are addresses, not credentials.** Anyone who guesses a code can open a TCP
connection, which is no more than any device already on the network can do. The one-byte
checksum catches typos; it is not a security control. Whether you may actually *talk* to
someone is still decided by the contact request the user answers.

**Hostile input.** The frame reader enforces a 4-byte length prefix capped at
`MeshPacket.maxPacketBytes + 1` and drops the link on violation, so a peer can't make the app
allocate without bound. Beacons are capped at 512 bytes. Unknown frame kinds are ignored. The
listener refuses connections past `maxLinks`. Handshakes that stall are abandoned after 12s
so a half-open connection can't hold a link slot.

**Cellular is prohibited** on these parameters. Carrying mesh traffic over cellular at sea
would be someone's roaming bill.

## Privacy

`LANNodeId` is a per-install random id, broadcast in Bonjour TXT records and UDP beacons so
the two automatic tiers don't show one friend twice, and so a blocked person's phone stays
blocked.

It **rotates every 14 days** and lives in `UserDefaults`, not the Keychain. Both choices
matter: a permanent broadcast identifier would let anyone running a packet capture on the
ship's network log which decks and bars a given phone passed through all week, and Keychain
items survive delete-and-reinstall, which would make "remove the app" stop meaning "start
over".

The nickname is broadcast in the clear in beacons and TXT records. This is the name the user
already chose to show other guests, and `Nickname.sanitize` is applied on receipt. It is not
linked to the mesh identity, which stays signed and separate.

## Consequences and open questions

- `SessionManager.shouldLink` still caps links using `MultipeerTransport.maxLinks`, so the
  cap is shared across both transports rather than per-transport. That's conservative and
  fine for now, but it means a phone with five LAN links won't open a radio link. Worth
  revisiting once telemetry shows how many links a real phone actually holds.
- **Unvalidated.** None of this has run on an actual cruise ship network. The tiers are
  reasoned from how hospitality Wi-Fi is normally configured, not from measurement aboard.
  That is the entire reason the telemetry shipped with it.
- The UDP beacon's 4-second interval is a guess balancing "a friend walking into coverage
  appears quickly" against battery. Telemetry on `timeToFirstPeer` should settle it.
- Bonjour service endpoints are handed to `NWConnection` unresolved, letting Network.framework
  resolve them. If that proves unreliable across subnets, resolving to an address explicitly
  is the fallback.

## Sources

- [MultipeerConnectivity](https://developer.apple.com/documentation/multipeerconnectivity) —
  bearer selection is not under app control.
- [Network framework](https://developer.apple.com/documentation/network) — `NWListener`,
  `NWBrowser`, `NWParameters`, and the `includePeerToPeer` / `prohibitedInterfaceTypes` knobs.
- [`nw_path_unsatisfied_reason_local_network_denied`](https://developer.apple.com/documentation/network/nw_path_unsatisfied_reason_local_network_denied)
  — how a denied Local Network prompt is detected.
- [RFC 4279](https://www.rfc-editor.org/rfc/rfc4279) — TLS PSK ciphersuites.
- [Crockford base32](https://www.crockford.com/base32.html) — the join-code alphabet, chosen
  because it omits I, L, O and U.
