# CruiseLAN 2.0: App Store submission package

Everything needed to fill in App Store Connect (ASC) for the first App Store release.
`Tools/asc/asc_fill.py` reads the description and review notes straight from this file, so
copy lives in one place. Character limits are noted, and every value is within them.

Reviewed against the App Review Guidelines on 2026-11-06. The table in §8 maps each guideline
risk to what answers it.

## 0. Inputs

| Item | Value | Where it's used |
|---|---|---|
| Support and safety email | `SUPPORT_EMAIL` until the owner picks one | `SafetyConfig.reportEmail`, both pages, in-app Report and Contact |
| Support URL | https://cruiselan-games.dguilloryjr.workers.dev/support | ASC, `SafetyConfig.supportURL` |
| Privacy Policy URL | https://cruiselan-games.dguilloryjr.workers.dev/privacy | ASC, `SafetyConfig.privacyPolicyURL`, Profile › Help |

The pages are `server/game-worker/public/*.html`, served as static assets by the
`cruiselan-games` Worker (`npx wrangler deploy` from `server/game-worker`).

## 1. App Information

| Field | Value |
|---|---|
| Name (30) | `CruiseLAN` |
| Subtitle (30) | `Board & card games, anywhere` |
| Primary category | Games › Board, Card |
| Secondary category | none |
| Content rights | Doesn't contain, show, or access third-party content |

## 2. Pricing and availability
Free. All territories. No in-app purchases.

## 3. Version information (2.0)

**Promotional text (170):**
```
Chess, Checkers, Connect Four, Tic-Tac-Toe, Color Match, Spades, and Tonk. Play online, with people nearby when there's no internet, or against the computer.
```

**Description (4000):**
```
CruiseLAN is a pack of classic board and card games for family and friends, made for travel. Play online when you have internet, with people nearby when you don't, or against the computer on your own. No accounts, no ads.

SEVEN GAMES
• Chess: full rules, including castling, en passant, and promotion
• Checkers: classic American rules with forced jumps and kings
• Connect Four: drop discs and line up four
• Tic-Tac-Toe: quick rounds and rematches
• Color Match: a fast card game for 2 to 4 players
• Spades: the partnership trick-taking classic for 4 players
• Tonk: a quick rummy-style card game for 2 to 4 players

PLAY ONLINE
With internet, including hotel and ship Wi-Fi, games are hosted online. Use Quick Play to join a game that's waiting for players, or host a private game and share its code or invite link. You'll get a notification when it's your turn.

PLAY NEARBY, NO INTERNET NEEDED
No Wi-Fi plan? Phones close to each other connect directly over Wi-Fi and Bluetooth, and one phone hosts the game. Open games nearby show up in the list for everyone around you.

PLAY THE COMPUTER
Practice Tic-Tac-Toe, Connect Four, Checkers, and Chess against the computer, anywhere, with no one else needed.

BUILT FOR FAMILIES
• Just a nickname: no accounts, no ads, no tracking
• A safety filter blocks bad words and personal details in nicknames
• Report any player from the game screen; hosts can remove players from their lobby
• Games can be private: only people with the code can join

Good to know: nearby play reaches phones close to you, not a whole ship, and some Wi-Fi networks stop phones from seeing each other. When that happens, play online instead.
```

**Keywords (100):**
```
chess,checkers,connect four,tic tac toe,spades,tonk,board games,card games,cruise,offline,family
```

**Copyright:** `2026 Danny Guillory`

**Screenshots (6.9" iPhone, 1320 × 2868),** in `docs/app-store/screenshots/`, uploaded in name order:
1. `01-games.png`: the seven games
2. `02-chess.png`: chess against a nearby player
3. `03-computer.png`: checkers against the computer
4. `04-colorMatch.png`
5. `05-spades.png`
6. `06-connectFour.png`
7. `07-tonk.png`

The app is iPhone-only, so no iPad set is needed. To regenerate: Debug build on the iPhone 18 Pro
Max simulator, launch with `-CruiseLANDemo <scene>` (`games`, `chess`, `computer`, `colorMatch`,
`spades`, `connectFour`, `tonk`, `checkers`), then `xcrun simctl io <udid> screenshot`.

## 4. Age rating answers

Let ASC calculate the rating from these answers.

| Question | Answer | Reason |
|---|---|---|
| Parental controls, age assurance | No | |
| Unrestricted web access | No | No browser or web views; links open Safari or Mail |
| User-generated content | **Yes** | Nicknames are shown to other players, including strangers in open online games |
| Messaging and chat | No | Chat is turned off in 2.0 (`AppFeatures.chatEnabled = false`) |
| Social media | No | |
| Advertising, gambling, loot boxes, contests | No / None | Spades and Tonk are played for points only; nothing of value is wagered |
| All content descriptors | None | Abstract board and card games |
| Made for Kids | No | Open online games include strangers |

## 5. App Privacy (ASC › App Privacy — web only, the API can't set it)

Matches `PrivacyInfo.xcprivacy`:

- **Data collection: Yes.** One type:
  - **Gameplay Content** — purpose **App Functionality**; **not linked** to the user; **not used for tracking**.
- Nothing else. Diagnostics stay on the device (this build has no telemetry endpoint, and the
  sharing switch is hidden). Push tokens are held only with the game they were given to and
  deleted with it, used only to deliver that game's notifications.
- Privacy Policy URL: as in §0.

## 6. App Review information

**Sign-in required:** No. **Contact:** reused from The Hub's review details by `asc_fill.py`.

**Notes (paste):**
```
CruiseLAN is a set of classic board and card games (Chess, Checkers, Connect Four, Tic-Tac-Toe, Color Match, Spades, Tonk). There are no accounts, purchases, or ads; players only choose a nickname.

TESTING WITH ONE DEVICE
1. Open CruiseLAN, enter any nickname, tap Get Started. Allow or decline the Local Network, Bluetooth, and Notifications prompts; the steps below work either way.
2. Tap Tic-Tac-Toe (or Connect Four, Checkers, Chess) › Play the Computer. The game starts at once and the computer answers each move. No internet or second device is needed. Rematch is offered when the game ends.

TESTING ONLINE WITH TWO DEVICES (internet required, any network)
3. Device A: Chess › Host a New Game. The lobby shows an invite code and a Share Invite button (an invite link).
4. Device B: Games › Join a Game with a Code, enter the code. Device A › Start Game. Moves sync between devices; while a player's app is closed, they receive a push notification when it's their turn.
5. Quick Play joins an open game waiting for players, or starts one that others can join.

TESTING NEARBY WITHOUT INTERNET (two devices, optional)
6. Turn off internet on both (Airplane Mode, then turn Wi-Fi and Bluetooth back on). Device A: Connect Four › Host a New Game. Device B sees it under Open games › tap it › I'm Ready. Device A › Start Game.

SAFETY (Guideline 1.2): the only user-generated content is the nickname. Nicknames are filtered on the device for profanity, sexual content, and personal information. Every multiplayer game screen has a Report button (reports open a pre-filled email to our support address and block the player on that device for nearby games); hosts can remove a player from their lobby; private games are joinable only by code. Chat is not offered. Support contact and privacy policy are in Profile (person icon, top right of Games) › Help.

ONLINE SERVICE: online games are hosted by our own service on Cloudflare. It stores only each game's moves, the players' nicknames at that table, and (if notifications are allowed) the APNs token for that game, and deletes games automatically (privacy policy linked in the app and in App Store Connect).

PERMISSIONS: Local Network and Bluetooth find players nearby when there's no internet. Background mode "bluetooth-peripheral": while the app is in the background, a nearby player's phone can deliver "your turn" or a game move over an encrypted Bluetooth service, and iOS wakes CruiseLAN to post a local notification. Location (When In Use) is requested only if the user taps "Show name" (Wi-Fi network) in Profile › Troubleshooting, to read the Wi-Fi network name (NEHotspotNetwork); it is never stored or sent. Camera is used only to scan a friend's connect code.

ENCRYPTION: only Apple's operating-system encryption is used (HTTPS/TLS via URLSession and Network.framework, MultipeerConnectivity, CryptoKit). No proprietary or third-party cryptography (ITSAppUsesNonExemptEncryption = NO).
```

## 7. Export compliance
`ITSAppUsesNonExemptEncryption = NO` is in the binary. Apple's guidance ("Complying with
Encryption Export Regulations"): set NO "if it only uses forms of encryption that are exempt from
export compliance documentation requirements", and "typically, the use of encryption that's built
into the operating system … is exempt". All of CruiseLAN's encryption is Apple's (URLSession and
Network.framework TLS, MultipeerConnectivity, CryptoKit); there's no third-party crypto. Apple
notes that exempt apps may still owe the US BIS an annual self-classification report.

## 8. Guideline risks and what answers them

| Guideline | Risk | Answer |
|---|---|---|
| 2.1 App completeness | Reviewer alone can't play a multiplayer-only app | Play the Computer (4 games), one-device steps first in the notes |
| 2.1 | Back end must be up | `cruiselan-games` Worker; check `/v1/health` before submitting |
| 2.3.1 / 2.3.3 Accurate metadata | Old listing described chat, "no servers" | Rewritten for games-first 2.0; screenshots regenerated from 2.0 |
| 5.1.1(i) Privacy policy | Must be in ASC and in the app | Hosted URL in both; Profile › Help › Privacy Policy |
| 5.1.1 / 5.1.2 Accurate disclosures | App claimed "no servers", diagnostics toggle sent nothing | Copy fixed; toggle hidden without an endpoint; manifest = Gameplay Content |
| 5.1.1 Purpose strings | Mentioned chat | Rewritten for games and the network test |
| 1.2 UGC | Filter, report, block, published contact | Nickname filter, Report on every game, host remove, on-device block, support email |
| 2.5.4 Background modes | bluetooth-peripheral must be used | Turn nudges and move relay for nearby games; explained in notes |
| 4.2 Minimum functionality | Empty lobbies look broken | Play the Computer, Quick Play, seven complete games |
| 2.2 Betas | No beta wording in app | None found (grep) |

## 9. Texas SB 2420 / Declared Age Range
Not adopted for 2.0: no accounts, purchases, or age-gated features. Revisit if any are added.
*This is an engineering judgment, not legal advice.*
