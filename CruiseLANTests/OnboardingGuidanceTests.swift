import Foundation
import Testing
@testable import iso_cruise_app

@Suite("Onboarding guidance")
struct OnboardingGuidanceTests {
    /// A throwaway suite so tests don't inherit each other's flags or touch the real app's.
    private func makeStore() -> ProfileStore {
        let suite = "onboarding.tests.\(UUID().uuidString)"
        return ProfileStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("A milestone is unseen until marked, then stays seen")
    func milestonesStick() {
        let store = makeStore()
        #expect(store.hasSeen(.connectGuide) == false)

        store.markSeen(.connectGuide)
        #expect(store.hasSeen(.connectGuide))
        // Marking twice is harmless.
        store.markSeen(.connectGuide)
        #expect(store.seenMilestones.count == 1)
        // Other milestones are unaffected.
        #expect(store.hasSeen(.firstConnection) == false)
    }

    @Test("Milestones survive a relaunch")
    func milestonesPersist() {
        let suite = "onboarding.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        ProfileStore(defaults: defaults).markSeen(.firstPeerSeen)

        // A fresh store over the same defaults is what a relaunch looks like.
        #expect(ProfileStore(defaults: defaults).hasSeen(.firstPeerSeen))
    }

    @Test("Resetting guidance brings every tip back")
    func resetGuidance() {
        let store = makeStore()
        for milestone in ProfileStore.Milestone.allCases { store.markSeen(milestone) }
        #expect(store.seenMilestones.count == ProfileStore.Milestone.allCases.count)

        store.resetGuidance()
        #expect(store.seenMilestones.isEmpty)
        #expect(ProfileStore.Milestone.allCases.allSatisfy { !store.hasSeen($0) })
    }

    @Test("Guidance flags are independent of the nickname")
    func nicknameUnaffected() {
        let store = makeStore()
        store.setNickname("Captain Sam")
        store.markSeen(.connectGuide)
        store.resetGuidance()
        // Resetting tips must not sign the user out of their own name.
        #expect(store.nickname == "Captain Sam")
    }

    /// The onboarding screen used to hard-code five game names and went stale the moment
    /// Spades and Tonk shipped. It's now derived, so this guards the derivation.
    @Test("The onboarding game list covers every playable game")
    func gameListIsComplete() {
        let names = GameType.allCases.filter(\.isPlayable).map(\.displayName)
        #expect(names.contains("Spades"))
        #expect(names.contains("Tonk"))
        #expect(names.count == GameType.allCases.count)
    }
}

@Suite("Hotspot detection")
struct HotspotDetectionTests {
    /// Can't fake interfaces in a unit test, so this only asserts the call is safe and
    /// total — the real verification is on-device with a hotspot actually running.
    @Test("Reading the hotspot role is safe and returns a known case")
    func hotspotRoleIsTotal() {
        let role = LANAddress.hotspotRole()
        #expect([.sharing, .joined, .none].contains(role))
    }

    @Test("A blocked network suggests a hotspot as the way around it")
    func blockedNetworkSuggestsHotspot() {
        var conditions = NetworkPathProbe.Conditions()
        conditions.hasWiFi = true
        conditions.isOffline = false
        conditions.bluetooth = .ready

        let diagnosis = ConnectivityDiagnosis(conditions: conditions, reach: .blocked)
        // Either the phone is already on a hotspot (so it says so), or it's offered as the
        // workaround. One of the two must appear, or the blocked case dead-ends.
        let ids = Set(diagnosis.checks.map(\.id))
        #expect(ids.contains("hotspot") || ids.contains("hotspotSuggestion"))
    }

    @Test("A working network doesn't nag about hotspots")
    func workingNetworkStaysQuiet() {
        var conditions = NetworkPathProbe.Conditions()
        conditions.hasWiFi = true
        conditions.isOffline = false
        conditions.bluetooth = .ready

        let diagnosis = ConnectivityDiagnosis(conditions: conditions, reach: .discoveryWorks)
        #expect(!diagnosis.checks.contains { $0.id == "hotspotSuggestion" })
    }
}
