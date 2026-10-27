import Foundation
import Observation

/// The online service's list of open games waiting for players, refreshed every few seconds
/// while the Games screen is showing.
@Observable
final class OpenGamesList {
    private(set) var games: [OpenGame] = []
    /// The last refresh reached the service.
    private(set) var isAvailable = false

    @ObservationIgnored private let service: CloudGameService
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    static let refreshInterval: Duration = .seconds(6)

    init(service: CloudGameService) {
        self.service = service
    }

    /// Open games for one title, minus any listed in `excluding` (the player's own, or ones
    /// they were removed from). Host names get the same cleaning as names seen nearby.
    func games(for game: GameType, excluding: Set<String> = [], filter: ContentFilter = .shared) -> [OpenGame] {
        games.filter { $0.game == game && !excluding.contains($0.code) && $0.seats < $0.maxSeats }
            .map { entry in
                var safe = entry
                safe.host = filter.safeNickname(Nickname.sanitize(entry.host) ?? "Player")
                return safe
            }
    }

    /// Starts refreshing (counted, so two screens can watch at once).
    func startWatching() {
        watchers += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        if let list = await service.openGames() {
            games = list
            isAvailable = true
        } else {
            isAvailable = false
        }
    }
}
