import CryptoKit
import Foundation

/// Sanitizes user-chosen display names, both our own and ones received from peers.
nonisolated enum Nickname {
    static let maxCharacters = 24
    /// `MCPeerID` display names must be at most 63 bytes of UTF-8.
    static let maxUTF8Bytes = 63

    /// Returns a cleaned nickname, or `nil` if nothing displayable remains.
    ///
    /// Removes control/format characters (including bidirectional overrides that can be
    /// used to visually spoof names), collapses whitespace, and truncates on grapheme
    /// boundaries to both a character limit and the `MCPeerID` byte limit.
    static func sanitize(_ raw: String) -> String? {
        sanitize(raw, maxCharacters: maxCharacters)
    }

    /// Same cleaning with a different length limit (for example, group names).
    static func sanitize(_ raw: String, maxCharacters: Int) -> String? {
        let filteredScalars = raw.unicodeScalars.map { scalar -> Unicode.Scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return scalar
        }.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                // Keep zero-width joiners so composed emoji survive.
                return scalar.value == 0x200D
            default:
                return true
            }
        }

        var cleaned = String(String.UnicodeScalarView(filteredScalars))
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")

        var result = ""
        for character in cleaned {
            let candidate = result + String(character)
            if candidate.count > maxCharacters || candidate.utf8.count > maxUTF8Bytes { break }
            result = candidate
        }
        cleaned = result.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Short, stable tag derived from a peer id, shown next to names so two people
    /// who pick the same nickname can still be told apart. It's a hash, so nobody can
    /// pick an id that produces someone else's tag.
    static func tag(for peerId: String) -> String {
        SHA256.hash(data: Data(peerId.utf8)).prefix(2).map { String(format: "%02X", $0) }.joined()
    }
}
