import Foundation
import Observation

/// The user's nickname, plus which one-time pieces of guidance they've already seen.
///
/// (Telemetry's opt-in flag and the two rotating pseudonyms also live in `UserDefaults`,
/// but they're owned by `TelemetryStore` and `LANNodeId` rather than here.)
@Observable
final class ProfileStore {
    private static let nicknameKey = "profile.nickname"
    private static let milestonePrefix = "profile.seen."
    private let defaults: UserDefaults

    private(set) var nickname: String?

    /// A moment the app explains itself once and then never again.
    ///
    /// Guidance is tied to *what the user has actually reached* rather than to a scripted
    /// sequence, because the thing people need explaining in CruiseLAN is never "where is
    /// the button" — it's "why is this list empty", which only makes sense to answer at the
    /// moment the list is empty. See docs/decisions/onboarding-tour.md.
    enum Milestone: String, CaseIterable, Sendable {
        /// The "get your group connected" screen shown once after onboarding.
        case connectGuide
        /// Nobody appeared on first run and the user is probably confused.
        case emptyPeopleExplained
        /// The very first time another phone showed up.
        case firstPeerSeen
        /// The first accepted connection, when chat and games become possible.
        case firstConnection
        /// The first time a game lobby was opened.
        case gameLobbyOpened
        /// The first turn in a card game, where tap-to-select needs a word of explanation.
        case cardTurnExplained
        /// The first time a friend went away mid-match.
        case awayExplained
    }

    /// Observed, so marking a milestone re-renders anything showing a hint.
    private(set) var seenMilestones: Set<Milestone> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nickname = defaults.string(forKey: Self.nicknameKey).flatMap(Nickname.sanitize)
        seenMilestones = Set(Milestone.allCases.filter {
            defaults.bool(forKey: Self.milestonePrefix + $0.rawValue)
        })
    }

    /// Saves a sanitized nickname. Returns `false` if nothing usable remains after sanitizing.
    @discardableResult
    func setNickname(_ raw: String) -> Bool {
        guard let clean = Nickname.sanitize(raw) else { return false }
        nickname = clean
        defaults.set(clean, forKey: Self.nicknameKey)
        return true
    }

    func hasSeen(_ milestone: Milestone) -> Bool {
        seenMilestones.contains(milestone)
    }

    func markSeen(_ milestone: Milestone) {
        guard !seenMilestones.contains(milestone) else { return }
        seenMilestones.insert(milestone)
        defaults.set(true, forKey: Self.milestonePrefix + milestone.rawValue)
    }

    /// Shows every piece of first-run guidance again. Offered in Profile, because guidance
    /// you can only see once is guidance you can't get back when you finally need it.
    func resetGuidance() {
        for milestone in Milestone.allCases {
            defaults.removeObject(forKey: Self.milestonePrefix + milestone.rawValue)
        }
        seenMilestones = []
    }
}
