# CruiseLAN: App Store submission package

Everything needed to fill in App Store Connect (ASC) for the first App Store release.
Values are copy-ready. Character limits are noted, and every value is within them.

## 0. Required inputs (only you can provide these)

| Item | Where it's used | Status |
|---|---|---|
| Support and safety email | `SafetyConfig.reportEmail` in `iso_cruise_app/Safety/SafetyStore.swift`, both HTML pages, the ASC contact | **Needed.** Use an address you're happy to publish (for example, a dedicated `cruiselan.support@…` alias). |
| Support URL | ASC › App Information, `SafetyConfig.supportURL` | **Needed.** Host `docs/site/support.html` |
| Privacy Policy URL | ASC › App Information, `SafetyConfig.privacyPolicyURL` | **Needed.** Host `docs/site/privacy.html` |
| App name on the store | ASC › App Information › Name | Rename the record to **CruiseLAN** if it still says `iso_cruise_app` |

**Hosting the two pages:** the quickest free option is a public GitHub repo with Pages turned on. You can also paste them into any site you own. Replace `SUPPORT_EMAIL` in both files first.

**After filling in the code values:**
1. Bump the build.
2. Archive and upload (the steps are in the README).
3. Pick that build in ASC.

> Why it's required: App Review Guideline 1.2 (user-generated content) requires a content filter (done), report (done), block (done), and **published contact information**. A report opens Mail addressed to that contact.

---

## 1. App Information (ASC › App Information)

| Field | Value |
|---|---|
| Name (30) | `CruiseLAN` |
| Subtitle (30) | `Offline chat & games nearby` |
| Primary category | Social Networking |
| Secondary category | Games › Board |
| Content rights | Doesn't contain, show, or access third-party content |
| Age rating | See section 4 |

## 2. Pricing and availability
- Free. All territories.
- Note: under Texas SB 2420, Apple asks for parental consent for minors' downloads. CruiseLAN has no accounts or purchases, so there's nothing extra to build for 1.0 (see section 9).

## 3. Version information (ASC › iOS App › 1.4)

**Promotional text (170):**
```
No Wi-Fi plan? No problem. Chat and play Chess, Checkers, Color Match, Connect Four, and Tic-Tac-Toe with people nearby, with no internet, accounts, or ads.
```

**Description (4000):**
```
CruiseLAN lets you chat and play games with people near you, with no internet connection, no accounts, and no data plan. It's made for cruises, road trips, campsites, and anywhere the Wi-Fi is expensive or missing.

CHAT WITH PEOPLE NEARBY
Pick a nickname, see who's around, and start chatting. Phones connect directly to each other over Wi-Fi and Bluetooth, with nothing in between.

FIVE GAMES TO PLAY TOGETHER
• Chess: full rules, including castling, en passant, and promotion
• Checkers: classic American rules with forced jumps and kings
• Color Match: a fast card game for 2 to 4 players
• Connect Four: drop discs and line up four
• Tic-Tac-Toe: quick rounds and rematches

KEEP PLAYING WHILE YOU CHAT
Tuck a game away and chat while you wait. A bar above the tabs tells you when it's your turn. Switched to another app? The game pauses, and a friend's phone can nudge yours over Bluetooth when it's your move or they send you a message.

BUILT FOR FAMILIES
• An on-device safety filter blocks bad words, sexual content, and personal information like phone numbers, emails, links, social handles, and cabin numbers, before it's sent and again when it's received.
• Report or block anyone with a long press. Blocked people can't message or invite you.
• Every new connection must be accepted.

PRIVATE BY DESIGN
No accounts, no servers, no ads, no analytics, no tracking. Connections are encrypted, and chats live only in memory and disappear when you quit.

Good to know: CruiseLAN reaches people near you, typically in the same area of a ship or building. It isn't a ship-wide network, and some Wi-Fi networks block devices from seeing each other.
```

**Keywords (100):**
```
offline,chat,cruise,nearby,no wifi,games,chess,checkers,family,local,bluetooth,multiplayer,travel
```

**What's New:** leave empty for the first release.

**Support URL:** your hosted `support.html`. **Marketing URL:** optional.

**Copyright:** `2026 Danny Guillory` (adjust if publishing as a company).

**Screenshots (6.9" iPhone, 1320 × 2868):** upload in this order from `docs/app-store/screenshots/`:
1. `01-chat.png`: chat with people nearby
2. `02-games.png`: all five games, with open games nearby
3. `03-chatWhilePlaying.png`: chat while it's your turn
4. `04-chess.png`
5. `05-colorMatch.png`
6. `06-checkers.png`
7. `07-connectFour.png`

ASC scales these for smaller iPhones. The app is iPhone-only, so no iPad set is needed. To regenerate them:
1. Run a Debug build on an iPhone Pro Max simulator with the launch argument `-CruiseLANDemo <scene>`.
2. Use one of these scenes: `chat`, `games`, `chatWhilePlaying`, `chess`, `colorMatch`, `checkers`, `connectFour`.

## 4. Age rating questionnaire

Answer as follows. The calculated rating should be **4+**.

| Question | Answer | Reason |
|---|---|---|
| Parental controls | No | |
| Age assurance | No | |
| Unrestricted web access | No | The app has no browser or web views. The only external links are Mail and the Acknowledgements license link. |
| User-generated content | **Yes** | Chat messages and nicknames |
| Messaging and chat | **Yes** | |
| Social media | **No** | There's no feed, discovery, resharing, or amplification. Messages go only to people you've accepted who are physically nearby. |
| Advertising | No | |
| All content descriptors (violence, profanity, sexual content, horror, gambling, drugs, mature themes, medical, contests) | None | Games are abstract, and profanity and sexual content are filtered |
| Made for Kids | **No** | Don't choose the Kids category: Kids-category apps face strict limits on chat with strangers. The app is family-friendly, but its audience is all ages. |

## 5. App Privacy (ASC › App Privacy)

- **Data collection:** select **"No, we do not collect data from this app."**
- **Why that's accurate under Apple's definitions:**
  - "Collect" means data sent off the device where the developer or its partners can access it. CruiseLAN has no server. Nicknames and messages go directly to nearby phones the user chose to connect with, never to the developer.
  - Safety reports are emails the user decides to write and send from Mail. Apple's "optionally disclosed" criteria cover these: not used for tracking or ads, infrequent, optional, and clearly user-provided.
- **Privacy manifest:** `PrivacyInfo.xcprivacy` declares no tracking and no collected data. It lists one required-reason API: UserDefaults, reason CA92.1, for the nickname, blocked list, and trusted devices.

## 6. App Review information

**Sign-in required:** No.

**Contact:** your name, phone, and the support email.

**Notes (paste):**
```
CruiseLAN is an offline, peer-to-peer chat and games app for people physically near each other (built for cruise ships, where internet is expensive). It uses MultipeerConnectivity; there is no server and no account.

TESTING REQUIRES TWO iPHONES (or an iPhone and an iPad running the iPhone app) with Wi-Fi and Bluetooth turned on. They don't need to join a network.

1. On both devices: open CruiseLAN, enter any nickname, tap Get Started, and allow Local Network, Bluetooth, and Notifications.
2. Device A: Chat › People (top right) › tap Device B under "Nearby" › Invite. Device B: tap Accept.
3. Chat: type a message on either device. Try "send nudes" or a phone number to see the safety filter block it.
4. Report/Block: on the other device, touch and hold a received message › Report. Reporting blocks the sender and opens a pre-filled email to our safety contact.
5. Games: Games › Chess › Host a New Game on Device A. Device B sees "1 open game nearby" › Join › I'm Ready. Device A › Start Game.
6. Chat while playing: tap the chat bubble (top right of the game). A "Your turn!" bar above the tabs returns to the game.

Background mode "bluetooth-peripheral": while CruiseLAN is in the background, iOS ends peer-to-peer Wi-Fi sessions. CruiseLAN advertises a small Bluetooth service so a nearby friend's phone can send a tiny "nudge" (sender id + "message" or "your turn"; never message text). iOS wakes the app to post a local notification. To see it: on Device B, press Home during a game when it's B's turn after A moves, or send a chat from A while B is in another app. B shows "Your turn in Chess" / "<name> sent you a message".

User-generated content safeguards (Guideline 1.2): on-device filter on send and on receipt; three filtered messages auto-block the sender; report and block on every message and person; every connection must be accepted; nicknames are filtered; contact email is in Profile › Help and on our support page.

Encryption: the app only uses Apple's built-in encryption for MultipeerConnectivity, so it's exempt (ITSAppUsesNonExemptEncryption = NO).
```

## 7. Export compliance
Already declared in the binary (`ITSAppUsesNonExemptEncryption = NO`). ASC won't ask.

## 8. Pre-submission checklist

- [x] iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), minimum iOS 26.1
- [x] 1024 px app icon, opaque
- [x] Privacy manifest with required-reason APIs
- [x] Usage strings: Local Network, Bluetooth
- [x] Background mode justified in review notes
- [x] Content filter, report, block (Guideline 1.2)
- [x] Screenshots at 1320 × 2868
- [x] No debug code in Release: `DemoMode` is `#if DEBUG` only
- [x] 216 automated tests pass
- [ ] Support email set in code and pages, then rebuild
- [ ] Support and privacy pages hosted; URLs in ASC and in `SafetyConfig`
- [ ] Tested on two real iPhones from TestFlight: chat, a game, background nudge
- [ ] ASC: metadata, age rating, privacy answers, screenshots, pick build, **Add for Review**

## 9. Texas SB 2420 / Declared Age Range: decision for 1.0

Apple says developers "may need to" adopt the Declared Age Range and Significant Change APIs, depending on their obligations under the law.

**Decision:** don't adopt them for 1.0. CruiseLAN has:
- no accounts
- no purchases
- no age-gated content or features
- no data collection

Apple's store-level age verification and parental consent cover the download itself.

**Revisit if:** the app adds purchases, accounts, age-specific features, or materially changes what it does (a "significant change").

*This is an engineering judgment, not legal advice.*
