import Foundation

/// Debug-only connection trace, written to `Library/Caches/trace.log` in the app container,
/// so two-simulator runs can be diagnosed when the unified log isn't available.
/// Compiled out of release builds.
nonisolated enum DebugTrace {
    #if DEBUG
    private static let queue = DispatchQueue(label: "com.dannyguillory.cruiselan.trace")
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("trace.log")
    /// Launch with `-CruiseLANTrace` to record.
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-CruiseLANTrace")
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard isEnabled else { return }
        let line = "\(Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))) \(message())\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
        #endif
    }
}

extension DebugTrace {
    /// Debug-only: with `-CruiseLANAutoConnect`, invite everyone found and accept every
    /// invitation, so connection tests can run without tapping.
    static var autoConnect: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-CruiseLANAutoConnect")
        #else
        false
        #endif
    }
}
