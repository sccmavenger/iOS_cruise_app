# Connection requests: no pop-ups

Status: decided, shipped in 1.7 (10). Date: 2026-10-15.

## What happened

A tester installed CruiseLAN on a new phone, picked a nickname, and immediately got two
full-screen alerts: "Ben wants to connect" and "Ana wants to connect". The tester asked whether
40 people nearby would mean 40 pop-ups.

## Why it happened

Two causes:

1. **The immediate trigger was our own test devices.** "Ana" and "Ben" were two iOS simulators on
   the development Mac. They were still running a debug build launched with
   `-CruiseLANAutoConnect`, a test-only switch that invited every nearby CruiseLAN user. The new
   phone was on the same Wi-Fi network, so the simulators found it and invited it. Release builds
   never had this switch (it's compiled out), but a debug test should never reach a real person's
   phone.
2. **The product flaw was the alert itself.** Every incoming connection request was shown as a
   modal alert the moment it arrived, from anyone in range. The transport accepted up to three
   waiting requests and declined the rest silently, so a crowd meant a queue of alerts, one after
   another. Nothing stopped someone who was declined from asking again right away.

## Decision

Connection requests are never shown as pop-ups. They wait quietly in a list, and the app says
how many are waiting.

- **Requests list.** People › "Requests" lists each request with Accept and Decline. The person
  asking isn't also listed under Nearby. The footer says: "Only accept people you recognize.
  Names aren't verified. If you decline, that phone can't ask again for 10 minutes."
- **A calm indicator, not an interruption.** The status banner at the top of Chats reads
  "1 person wants to connect" (or "N people…"). Tapping it opens People.
- **No repeat asking.** After a decline, further requests from the same phone are declined
  silently for 10 minutes (`SessionManager.declineMute`).
- **A cap on waiting requests.** At most 5 can wait (`SessionManager.maxWaitingRequests`, matched by
  `MultipeerTransport.maxPendingInvitations`). Beyond that they're declined silently. 40 people
  can't flood anyone.
- **More time to answer.** Requests now wait 60 s instead of 30 s
  (`MultipeerTransport.invitationTimeout`), because they're no longer in your face.
- **Unchanged:** people you already accepted still reconnect automatically after the app was in
  the background, with no new request (see `TrustedPeersStore`). Blocked people's requests are
  still declined automatically.
- **Test tooling can't reach real phones.** `-CruiseLANAutoConnect` now takes the exact test
  nicknames to connect with (for example `-CruiseLANAutoConnect Ana,Ben`). Anyone else is treated
  normally. It remains debug-only.

## Why this approach

- **Apple's Human Interface Guidelines** say to use alerts sparingly: an alert interrupts and
  demands an answer before anything else can happen. A stranger asking to connect isn't urgent,
  and a crowd of strangers makes alerts unusable.
- **Established practice for contact from strangers.** Instagram and Messenger put messages from
  people you aren't connected with into a separate "Message requests" inbox, not the main inbox
  and without interrupting. Meta tightened this further for teens in 2024
  (https://about.fb.com/news/2024/01/introducing-stricter-message-settings-for-teens-on-instagram-and-facebook/).
  AirDrop likewise limits "Everyone" to 10 minutes. CruiseLAN is aimed at families and kids, so
  contact from strangers should take a deliberate step by the recipient, not one tap on a sudden
  pop-up.
- **The safety gate stays in place.** Nobody can chat with you until you accept. Making the
  request quieter doesn't make it automatic.

## Considered and rejected

- **Keep the alert but show only the first one.** It still interrupts, and it hides the others.
- **A notification banner for each request.** The same flooding problem in another form.
- **Only allow requests from people you invited first.** Two people meeting for the first time
  would never be able to connect.
- **Turn off requests entirely ("invite-only mode").** It might be worth adding later as a
  parental setting, but it's too restrictive as the default.

## Verified

- Unit tests: `declineMutesRequests`, `requestsAreCapped`, and the updated `invitations` test.
  All 251 tests pass.
- On a simulator: a request arrived with no pop-up and the banner read "1 person wants to
  connect". People › Requests showed the row without wrapping, and the requester wasn't also
  listed under Nearby. Accept connected; Decline removed the request.
