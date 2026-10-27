# Card games: Spades and Tonk

Status: decided, shipped in 1.9 (13). Date: 2026-10-19.

## Why

From the cruise notes:

> What other games can be added (monopoly, poker, spades, tonk, etc.)

Five games shipped before this, all of them either abstract board games or Color Match. A
family on a cruise plays cards, and the two the owner named that fit the existing architecture
best are Spades and Tonk.

## What shipped, and what didn't

| Game | Status | Reason |
|---|---|---|
| **Spades** | Shipped | Four players in partnerships, which is exactly a family table. Well-specified ruleset with one widely-played standard. |
| **Tonk** | Shipped | Two to four, fast rounds, and the distinctive one on the list — nothing else in the app plays like it. |
| **Poker** | Not started | Needs a seven-card hand evaluator plus betting state (chips, blinds, pots, side pots). The evaluator is well-defined work; the betting model is where it gets large. Nothing blocks it architecturally. |
| **Property trading (the "Monopoly" ask)** | Not started | By far the biggest: a board, deeds, money, houses, trading between players, auctions, jail, and two card decks. That's a release on its own, not a game added to one. It would also need an original name and board — **Monopoly is an active Hasbro trademark**, and the board design and card text are protected too. Color Match already set the precedent for how to do this (see its header note). |

## Architecture: nothing needed changing

Reading the existing code first turned out to matter. `GameType` already carried
`minPlayers`/`maxPlayers`, `GameCoordinator` was already host-authoritative with N seats, and
Color Match already did **per-recipient projection** for hidden hands. So both games are pure
additions:

- A `Rules` enum of static functions over an immutable state (same shape as the other five).
- A host-only `State` holding every hand, and a `Snapshot` that is the only thing sent.
- Cases added to `GameType`, `GameMove`, `GameStateSnapshot`, and `GameEngine`.

No change to the coordinator, the transport, or the envelope format beyond the new enum cases.

### Shared card model

`PlayingCard` is new and shared. Color Match keeps its own `Card` because it isn't a standard
deck (four colours, action faces, 108 cards); anything played with a real deck uses the shared
one, so the deck, shuffling, sorting, and card rendering exist once. `id` is the card's index
in a fresh deck (0..<52), so a move references a card by a small integer and "is this a real
card" is a range check.

### Hidden information

Both games hold every hand in the host's state, so neither is ever sent as-is — the same
discipline Color Match already had, and both have a test asserting a snapshot contains the
viewer's cards and no one else's (`snapshotPrivacy`). Tonk additionally hides *which* card a
player just took from the discard pile from everyone but that player, because knowing it is a
real advantage.

## Rules decisions worth recording

**Spades** uses the common North American ruleset: 13 cards, Ace high, spades always trump,
spades can't be led until broken, 10 points per trick bid with 1 per bag, ±100 for nil, 10
bags costs 100, game to 500. Two points that vary between tables and are fixed here:

- **A nil bidder's tricks don't count toward the partnership's contract.** They become bags.
  This is what makes a failed nil doubly painful and it's tested explicitly
  (`nilTricksDontCountTowardContract`).
- **A match only ends on a clear win.** If both teams cross 500 in the same hand the higher
  score takes it, and an exact tie plays another hand rather than declaring a winner.

`legalPlays(for:in:)` is public so the view can grey out illegal cards. A trick-taking game
that silently refuses a tap is miserable to learn, and the host would refuse it anyway — so
the rules and the UI agree by construction rather than by duplicating the follow-suit logic.

Scoring was extracted into `scoreHand(players:bids:tricksWon:)`, a pure function, after the
first attempt at testing it through a contrived final trick ended up testing the trick logic
instead. The settling of bags and the ten-bag penalty stays in `score(_:)` because it needs
the running totals.

**Tonk** is a folk game and genuinely varies by region — hand size, whether you may hit other
people's spreads, and what a caught drop costs all differ. One ruleset is implemented and
stated plainly in the app rather than left for players to discover:

- Five cards each; face cards 10, Ace 1, pips at face value.
- A dealt 49 or 50 is Tonk: an immediate win worth double.
- Draw from stock or take the discard, optionally spread and hit, then discard.
- A card just taken from the pile can't be discarded back on the same turn.
- Dropping is only allowed *before* drawing — otherwise it would be a free look at a card.
- **A tie catches the dropper.** Ties go against the person who dropped, and a caught drop
  pays double.
- **Ace is high**, so Q-K-A is a run and A-2-3 is not. Consistent with Spades and the rest of
  the app, and tested (`aceIsHigh`).
- A spread must leave at least one card to discard, because a turn ends in a discard. Going
  out therefore happens on the discard, never on the spread.

## Compatibility

`GameType` is a string enum, so a 1.8 phone receiving a `spades` or `tonk` envelope fails to
decode it and drops the packet as malformed — which is graceful, not a crash.
`MultipeerTransport.protocolVersion` was deliberately **left at `"2"`** rather than bumped:
bumping would stop 1.8 phones linking at all, losing chat and the five existing games across
versions, to prevent a failure mode that already degrades safely. The cost is that starting a
Spades match with someone on 1.8 quietly does nothing for them. Everyone testing together
should be on 1.9.

## Open questions

- Spades needs exactly four players, which is the first game in the app with a hard seat
  count rather than a range. The lobby already handles it via `minPlayers == maxPlayers`, but
  it hasn't been exercised with four real devices yet.
- Neither game has been played end to end on hardware — the rules are covered by 43 tests, but
  the *views* have only been built, not used. Expect UI friction on first play.
- Tonk's `suggestedSpreads(in:)` is written and used only for hints; a "spread this for me"
  affordance might be better than making players select cards by hand.
