import Foundation

/// One-tap invite links. Sharing a game sends `https://<service>/join/ABCD1234`:
/// - with CruiseLAN installed, iOS opens the app (Universal Link) and it joins the game;
/// - without it, the link opens a page with "Get CruiseLAN" and an "Open in CruiseLAN" button,
///   which uses `cruiselan://join/ABCD1234`.
enum InviteLink {
    static let scheme = "cruiselan"

    static func url(for code: String) -> URL {
        CloudConfig.productionURL.appending(path: "join/\(code)")
    }

    /// The game code in an invite link (either form), or nil if it isn't one.
    static func code(from url: URL) -> String? {
        let parts: [String]
        if url.scheme == scheme {
            // cruiselan://join/CODE → host "join", path "/CODE"
            parts = [url.host() ?? ""] + url.pathComponents.filter { $0 != "/" }
        } else if url.scheme == "https", url.host() == CloudConfig.productionURL.host() {
            parts = url.pathComponents.filter { $0 != "/" }
        } else {
            return nil
        }
        guard parts.count == 2, parts[0] == "join" else { return nil }
        return normalized(parts[1])
    }

    /// A code typed or pasted by hand: "abcd-1234", "ABCD 1234", or a whole invite link.
    static func code(fromText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, let code = code(from: url) { return code }
        return normalized(trimmed)
    }

    /// Uppercase, no separators, and the usual look-alikes fixed (O→0, I/L→1), as the server does.
    static func normalized(_ raw: String) -> String? {
        let code = String(raw.uppercased().filter { $0.isLetter || $0.isNumber })
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return code.count == 8 && code.allSatisfy(allowed.contains) ? code : nil
    }
}
