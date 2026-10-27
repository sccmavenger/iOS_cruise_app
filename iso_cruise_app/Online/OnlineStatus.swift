import Foundation
import Network
import Observation

/// Whether games can be hosted online right now.
///
/// Online means the game service actually answers, not just that a network is up. A hotel or
/// ship Wi-Fi with client isolation still counts as online if it reaches the internet, because
/// online games don't need the phones to see each other. With no internet (or a captive portal
/// not yet signed in), games are hosted on a phone over Nearby radio or local Wi-Fi as before.
@Observable
final class OnlineStatus {
    enum State: Equatable {
        case checking
        case online
        case offline
    }

    private(set) var state: State = .checking
    /// The player turned online games off in Profile, for example to test phone-hosted games.
    var isEnabled: Bool { settings.onlineGamesEnabled }
    /// Host and join online.
    var canPlayOnline: Bool { isEnabled && state == .online }

    @ObservationIgnored private let service: CloudGameService
    @ObservationIgnored private let settings: ConnectionSettings
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var lastChecked: Date = .distantPast
    @ObservationIgnored private var pathIsUp = false
    /// How long an answer is trusted before hosting asks again.
    static let freshness: TimeInterval = 30

    init(service: CloudGameService, settings: ConnectionSettings) {
        self.service = service
        self.settings = settings
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(isUp: isUp) }
        }
        monitor.start(queue: DispatchQueue(label: "cruiselan.online-status"))
        self.monitor = monitor
    }

    /// Asks the service again. Called on network changes, when the app comes forward, and
    /// before hosting a game.
    func refresh() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            guard let self else { return }
            let healthy = await self.service.checkHealth()
            guard !Task.isCancelled else { return }
            self.state = healthy ? .online : .offline
            self.lastChecked = .now
        }
    }

    /// The answer, waiting for a check already in progress.
    func currentlyOnline() async -> Bool {
        guard isEnabled else { return false }
        // No answer yet, or an old one with a network up (the service may have come back, or
        // gone): ask now rather than host in the wrong place.
        if checkTask == nil || (pathIsUp && Date.now.timeIntervalSince(lastChecked) > Self.freshness) { refresh() }
        await checkTask?.value
        return canPlayOnline
    }

    private func pathChanged(isUp: Bool) {
        pathIsUp = isUp
        if isUp {
            state = .checking
            refresh()
        } else {
            checkTask?.cancel()
            checkTask = nil
            state = .offline
        }
    }
}
