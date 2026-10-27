/// Switches for whole features.
enum AppFeatures {
    /// Chat is off for now: the app is games-first, and anyone can host or join a game without
    /// connecting to people first. The chat code stays in place (mesh, end-to-end encryption,
    /// conversations); flipping this back on restores the Chat tab, the People list, the
    /// connect guide, the match's Chat button and chat notifications.
    nonisolated static let chatEnabled = false
}
