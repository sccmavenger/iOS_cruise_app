# Onboarding: teaching the connection ritual, not the tabs

Status: decided, Layer 1 shipped in 1.9 (17). Date: 2026-10-20.

## Why

The owner asked what a tour for a new user should look like. Reading the app first changed
the answer.

`OnboardingView` already handles "what is this": hero image, one-line pitch, nickname entry,
three feature rows, and a heads-up about the permission prompts. It's a good screen. Adding a
swipeable carousel after it would teach navigation nobody needs — **there are two tabs.**

The actual problem is **cold start**. A new user opens CruiseLAN alone and nothing happens:
empty People list, empty chat, games that can't start. Every other messaging app arrives
already knowing your contacts; this one arrives empty and stays empty until a second human
does something. Worse, "nobody is here yet" and "this is broken" look identical.

The owner hit exactly this at a hotel — the confusion was never "where is the button", it was
"why can't I see the other phone".

## Decision: three layers, not a carousel

Upfront carousels get swiped past. One deliberate screen for the thing that blocks everything,
then teach the rest in context.

### Layer 1 — "Get Connected" (shipped)

`GetConnectedView`, shown once after onboarding. Its only job is the **first connection**. It
adapts to where the user's group actually is:

| Situation | What it offers |
|---|---|
| We're together | Three numbered steps, plus the **live peer list inline** |
| We're far apart | Straight into the QR flow |
| I'm on my own | A share link, because a solo user has no other path |

The live list matters: the user watches a friend appear *while* being told what's happening,
rather than reading a description of it. When nothing appears, the waiting hint reads real
conditions (`NetworkPathProbe`) and says "allow Local Network access" or "turn on Wi-Fi"
instead of spinning forever.

### Layer 2 — Just-in-time hints (designed, not built)

`ProfileStore.Milestone` is in place with the cases; the hints that consume it are not built
yet. Triggered by state rather than a script: empty list after ~20s, first peer seen, first
connection, first lobby, first card turn, first friend going away. Deliberately deferred —
Layer 1 may make most of them unnecessary, and guessing before that is how you end up with
six tooltips nobody needed.

### Layer 3 — Replayable (shipped)

"How to connect" and "Show first-run tips again" in Profile. Guidance you can only see once
is guidance you can't get back when you finally need it.

## Decisions made on the owner's behalf

The owner asked for best judgement on three open questions:

1. **Before or after the permission prompts?** → **After**, by two seconds. Before means
   explaining discovery abstractly; after means the live peer list actually works. A
   demonstration beats an explanation.
2. **Push "invite someone"?** → **Yes.** It's the only honest answer for a solo user, and
   it's one share button on a branch they chose to open, not a nag.
3. **Design for kids?** → **Yes.** The safety model already assumes younger users, so the
   copy avoids jargon ("network", not "subnet"; "reach each other", not "client isolation").

## Hotspot escape hatch (shipped alongside)

`LANAddress.hotspotRole()` detects a Personal Hotspot — `bridge100` when sharing,
`172.20.10.x` on `en0` when joined. A hotspot is a private network with no client isolation,
so CruiseLAN always works across one.

This turns the worst diagnosis into an actionable one. When `reach == .blocked`,
Troubleshooting now offers the hotspot as the way around it; and a user already on one is
told so rather than left wondering.

The `172.20.10.0/28` range is an Apple convention, not a documented guarantee, so it's only
ever used to *add* reassurance — never to rule anything out.

## What was deliberately not built

- **A 5-screen swipeable intro.** The existing single screen carries the "what is this" load.
- **Coach marks over the tab bar.** Two tabs.
- **A blocking tour.** Everything is skippable in one tap.
- **A simulated-friend sandbox.** `DemoMode` exists for screenshots and could power one, but
  a fake friend risks a user believing they've connected when they haven't. Rejected unless
  it can be labelled unmistakably.

## Side fix

`OnboardingView` hard-coded five game names and went stale the moment Spades and Tonk shipped.
It's now derived from `GameType.allCases`, with a test asserting the list stays complete.

## Open questions

- Layer 2 is unbuilt on purpose. Revisit only after watching someone use Layer 1.
- Hotspot detection is verified only by a totality test; the real check is on-device with a
  hotspot actually running.
- "Get Connected" has never been seen by a new user. Its whole premise — that watching a peer
  appear teaches more than prose — is a hypothesis.
