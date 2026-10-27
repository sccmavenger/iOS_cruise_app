# TestFlight tester feedback, October 2026

Status: addressed in 1.9 (18). Date: 2026-10-20.

Pulled from App Store Connect with `Tools/asc/review_feedback.py`. Four screenshot
submissions, **no crash submissions**, and no App Review feedback — version 1.8 is still
`PREPARE_FOR_SUBMISSION`, so nothing has ever been submitted or rejected.

## 1 & 2. Chat from a game reached the wrong people

> "Top right when I hit chat I should be dropped in a chat with the person or persons that I
> am in the game with."

> "I am playing only Captain Sam once he accepted, everybody got added to the chat. I only
> wanna be able to invite certain people."

Two reports, one cause. The in-game Chat button did `app.selectedTab = .chat`, landing on the
conversation list, where the default conversation is **"Everyone"** — a broadcast to every
connected contact. So chatting with the person you were playing had no obvious path, and the
obvious path messaged people who weren't in the game.

**Fixed.** `SessionManager.matchConversation(lobbyId:named:players:)` returns the chat for
whoever is at the table: the existing one-to-one chat for a single opponent, otherwise a
group **keyed by the lobby id**. Using the lobby id means every player derives the same
conversation without negotiating one over the network, and asking twice is idempotent rather
than minting duplicate groups. The in-game button now opens it directly.

## 3. Tab bar width changes when a game is minimised

> "UI for chat and games at the bottom is not consistent with the rest of the app. If you
> look at chat and games on other screens it's not as wide."

**Not our bug — and worth saying so rather than chasing it.** From the screenshot, the width
change happens when the "Return to game" accessory is attached. Apple documents this:

> "On iPhone, the placement of the bottom accessory depends on the tab bar size: when the tab
> bar is normal size, the accessory appears above it; when the tab bar is collapsed, the
> accessory displays inline."
> — `tabViewBottomAccessory(isEnabled:content:)`

The tab bar and accessory render as one group at full width by system design. Matching the
narrower floating pill would mean dropping `tabViewBottomAccessory`, and with it the
return-to-game bar — a real feature traded for a cosmetic match. Declined.

**But the report did surface a genuine latent bug.** `MatchAccessoryView` rendered the same
content in both placements, and inline it has far less room — two stacked lines of text plus
"Return" would have overflowed once the tab bar collapses on scroll. It now reads
`tabViewBottomAccessoryPlacement` and collapses to a single line when inline.

## 4. A departed phone kept showing as "Nearby"

> "How does discovery work? I closed the app on test-phone but it's still showing up several
> minutes after the app was closed on test-phone."

**Investigated; could not reproduce from the code, and did not guess at a tuning change.**

What the screenshot shows: the phone is in "People on CruiseLAN" (a discovered peer, not a
contact), labelled "Nearby". That list filters on `SessionManager.nearbyWindow` = 60s of
`lastHeard`, and `PeersView` re-evaluates every 5s via its own ticker, so the row should
clear about a minute after the last announcement.

The obvious suspect was the cached-announcement replay refreshing `lastHeard` on arrival.
It doesn't: `updateDirectory` uses the packet's own `sentAt`, clamped to now, and takes
`max(previous.lastHeard, sentAt)` — so a replayed announcement can only ever restore the age
it already had. That path is correct.

Remaining possibilities are the tester's sense of elapsed time against a 60s window, or the
app having been left in the app switcher (`.inactive`, where nothing is torn down) rather
than fully closed. Neither justifies changing a timing constant blind.

**What changed instead:** discovered rows now show how long ago the peer was last heard
("Nearby · seen 45s ago"), and away contacts show when they left. A correct list with no
sense of *when* reads as a stuck one; with an age, "why is this still here" answers itself —
and if something really is refreshing `lastHeard`, the label will expose it on the next test
rather than requiring another round of inference.

`nearbyWindow` left at 60s deliberately. Announcements are every 20s, so 60s is three missed
announcements; tightening it without evidence trades a real property (tolerating a dropped
announcement) for a perception problem.

## Tooling added

`Tools/asc/review_feedback.py` — read-only. Version states, beta review submissions, tester
screenshot and crash feedback, and build health including missing export-compliance answers.
Resolution Center prose has no public API, so when a version is rejected it says where to
look rather than pretending to read it.
