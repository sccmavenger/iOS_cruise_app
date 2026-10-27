# Telemetry: measuring whether the app actually works

Status: decided, implemented. Backend **not yet deployed**. Date: 2026-10-19.

## Why

From the owner's notes:

> Implement telemetry gathering. Each signal needs to answer a question directly and/or
> collectively multiple telemetry signals need to answer a questions directly.
> Performances page - across all telemetry signals how is the apps performance.

And separately, on where it goes:

> Question is I dunno where you send the telemetry and how I view it or rationalize over it.

There is also a concrete question the data has to settle:

> I think battery saver being turned on is impacting discoverability of friends.

Right now that's a hunch with no way to confirm it. And after the LAN transport
([lan-transport.md](lan-transport.md)) shipped three discovery tiers, there's no way to know
which of them works on a real ship. Both are measurement problems.

## Principle: a signal that answers no question isn't collected

The notes are explicit that each signal must answer a question. That is enforced in the type
system rather than by convention: `TelemetrySignal.question` is non-optional and returns a
`TelemetryQuestion`, so a new signal cannot be added without naming what it's for. The
insights page is organised by question, not by counter, so an orphan number would be visibly
homeless.

The six questions:

| Question | Signals serving it |
|---|---|
| Which transport actually carries traffic, and how far does the mesh reach? | `linkConnectedByTier`, `announceHopCount`, `timeToFirstPeer`, `reachableContacts`, `tierAttemptFailed` |
| When people can't find each other, what is blocking it? | `pathProbeOutcome`, `capabilityUnavailable` |
| Does Low Power Mode reduce how many friends are discovered? | `peersVisibleByPowerMode` |
| Do messages reach their recipients, and where are they lost? | `chatSendAttempt`, `chatHeldForAway`, `packetRejected`, `rateLimitHit` |
| Do connections hold, and how quickly do they come back? | `linkDropped`, `linkLifetime`, `reconnectLatency` |
| Can a match start, stay in sync, and finish? | `matchStarted`, `matchEnded`, `moveRoundTrip`, `stateResync` |

The battery-saver question is answered by one signal recorded two ways: peers visible with
Low Power Mode on versus off. Comparing those two averages directly is the test, which turns
"I think battery saver is impacting discoverability" into a number.

## Design

### Aggregates, not events

Nothing stores a timeline. Each `(signal, dimension)` pair collapses into one `Aggregate`
(count, sum, min, max, histogram buckets) the moment it's recorded.

This is a privacy decision as much as a performance one. An event stream with timestamps
reconstructs what one person did and when — who they played, when they were in their cabin,
when they moved. An aggregate cannot. It also keeps memory flat and makes the upload small
enough to survive a bad shipboard connection.

Percentiles come from fixed histogram buckets, so they're reported as a bucket's upper bound
("most moves landed under 2s") rather than implying precision the buckets don't have.

### Bounded by construction

Both `TelemetrySignal` and `TelemetryDimension` are closed enums. The number of possible
series therefore has a compile-time ceiling, and **there is no code path that can grow the
store without a source change**.

`TelemetryDimension` being closed is the main privacy control: the only way to report a new
label is to add a case to that enum, which forces the question "should this leave the
device?" to be answered at review time rather than at some call site months later. There is
deliberately no case for a nickname, a message, a mesh id, an IP address, a Wi-Fi network
name, or a location. A reviewer only has to read one file to know everything the app can say.
`TelemetryTests.payloadCarriesNoIdentifiers` guards this.

### What is collected about the device

Only: a rotating pseudonym, app version, OS version, and device *class*.

Device class is "iPhone", not the exact model. `utsname` would give the model, but on a
TestFlight group of a few dozen people, exact model plus OS version plus timing is close to
a fingerprint.

`TelemetryInstallId` rotates every 14 days so reports can't be chained into a long-term
history of one person. It lives in `UserDefaults`, **not** the Keychain, because Keychain
items survive delete-and-reinstall — which would make deleting the app fail to reset
anything. (`MyApp` already works around exactly this for `IdentityStore`.)

### Recording is local; sharing is opt-in

Recording always runs, because the troubleshooting page reads the same numbers and that data
never leaves the phone. Upload requires `isSharingEnabled`, which defaults to **off**.

This is stricter than Apple requires — disclosure would be enough — and it's the right
default for an app whose whole pitch is privacy. "Delete everything" is offered in the UI, so
the answer to "what do you have about me" can always be "nothing, if you say so".

### No shipped credentials

The app holds no API key, because a key in an iOS binary is not a key. The endpoint comes
from the `CruiseLANTelemetryEndpoint` Info.plist key, must be HTTPS, and when it's absent
uploads are simply skipped — so the repo carries no hostname and a build without an endpoint
is distinguishable from one with a broken endpoint.

The endpoint is protected server-side instead: strict schema validation, every label checked
against the known `TelemetryDimension` vocabulary, a 64 KB body cap, and Cloudflare's
per-IP rate limiting. The worst an attacker can do is add noise to aggregate counters, which
is why no decision should rest on a single install's numbers.

Uploads are marked `.background` service type with expensive and constrained network access
refused, so telemetry never competes with the mesh for the radio or delays a launch. Minimum
six hours between uploads.

## Where it goes and how to read it

**Chosen: a Cloudflare Worker writing to D1.** Reasons: the free tier is genuinely free at
this volume (100k requests/day, 5 GB D1), it needs no server to maintain, and it terminates
TLS and rate-limits at the edge without extra configuration.

Alternatives rejected:
- **OneDrive / Dropbox share** (floated in the notes for logs) — no way to accept writes from
  an app without shipping a credential.
- **Hosted analytics (Firebase, Amplitude, PostHog)** — all want an event stream and a stable
  install id, which is the shape this design specifically avoids. Also adds an SDK that reads
  far more than this collects, which would have to be disclosed on the App Store privacy card.
- **GitHub issues as a datastore** — needs a token in the app. Same problem.

The Worker, schema, and deployment steps live in `server/telemetry-worker/`. Viewing is by SQL
against D1 (`wrangler d1 execute`), with the insights page in the app as the live local view.

**Status: the Worker is written but not deployed, and no endpoint is configured.** Until
`CruiseLANTelemetryEndpoint` is set, the app collects locally and uploads nothing. The
insights page works regardless, because it reads the local store.

## App Store declarations

Adding telemetry made the existing privacy manifest wrong: `PrivacyInfo.xcprivacy` declared
`NSPrivacyCollectedDataTypes` as empty, which was true before and isn't now. It now declares
three types, all **not linked to identity** and **not used for tracking**, all for Analytics:

| Type | What it covers here |
|---|---|
| `NSPrivacyCollectedDataTypeProductInteraction` | Match and chat counts — how often features are used, never their content |
| `NSPrivacyCollectedDataTypePerformanceData` | Timings: link lifetime, move round trip |
| `NSPrivacyCollectedDataTypeOtherDiagnosticData` | Connectivity diagnostics: which transport carried traffic, what blocked it |

`NSPrivacyTracking` stays `false` — nothing is combined with other companies' data, used for
advertising, or shared with a broker, and there are no third-party SDKs.

**The App Store Connect "App Privacy" questionnaire has to match this**; the manifest alone
isn't sufficient. Answer: collects Usage Data → Product Interaction, and Diagnostics →
Performance Data + Other Diagnostic Data; not linked to identity; not used for tracking.

Two judgement calls worth knowing, since they're arguable:
- **The rotating install pseudonym is not declared as its own data type.** It isn't an
  advertising or device identifier — it's an app-generated random value that rotates every
  14 days and is cleared on delete. It exists only to group one device's aggregates together,
  so it's treated as a property of the declared types rather than as collected Identifier
  data. If a reviewer disagrees, adding `NSPrivacyCollectedDataTypeDeviceID` (not linked, not
  tracking) is the conservative fix.
- **Exporting a diagnostics file is not collection.** The user initiates the share and
  chooses the destination; the developer receives nothing automatically.

## Consequences and open questions

- The performance grades (what counts as Good / Fair / Needs work) are first guesses stated
  explicitly in `PerformanceReport`, e.g. "median link lifetime of five minutes is Good".
  Every finding carries the `detail` string explaining how it was graded so the thresholds can
  be argued with rather than trusted. Expect to move them after real data.
- A 14-day pseudonym rotation means a voyage longer than 14 days splits into two cohorts.
  Acceptable; cruises are mostly shorter.
- Aggregates are cleared on successful upload. A failed upload keeps the window, so a phone
  offline for a week accumulates one long window rather than losing it — but also reports one
  coarse window instead of several. Acceptable trade.
- There is no crash reporting here. Xcode Organizer already covers it and is linked from the
  insights page rather than duplicated.

## Sources

- [Cloudflare Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [Cloudflare D1](https://developers.cloudflare.com/d1/)
- [Apple: describing data use in privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [`isLowPowerModeEnabled`](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled)
  and `NSProcessInfoPowerStateDidChange`, used for the battery-saver comparison.
