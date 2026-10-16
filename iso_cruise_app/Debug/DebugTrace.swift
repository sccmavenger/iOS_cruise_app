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
    /// Debug-only: with `-CruiseLANAutoConnect Ana,Ben`, connects to the named test devices
    /// without tapping (invites them and accepts their requests). Anyone else is treated
    /// normally, so a nearby real phone never gets automatic requests from a test device.
    static func autoConnects(with nickname: String) -> Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CruiseLANAutoConnect"), arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1].split(separator: ",").contains { $0 == nickname }
        #else
        false
        #endif
    }
}
