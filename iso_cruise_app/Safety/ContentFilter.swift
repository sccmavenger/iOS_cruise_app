import Foundation

/// On-device text filter for chat messages and nicknames.
///
/// CruiseLAN is aimed at kids, and Apple provides no text-moderation API, so this
/// combines:
/// 1. Normalization that defeats common evasions: look-alike Unicode letters, accents,
///    full-width forms, invisible characters, leetspeak (`f4ck`, `$h1t`), stretched
///    letters (`fuuuuck`) and spaced-out letters (`s e x`, `f.u.c.k`).
/// 2. A bundled pattern list (`SafetyTerms.txt`, built by `Tools/build_safety_terms.py`
///    from the MIT `obscenity` dataset and CC-BY-4.0 LDNOOBW list) with word-boundary
///    rules and an allowlist to avoid blocking innocent words ("class", "Scunthorpe").
/// 3. Personal-information detection (phone numbers, emails, links, social handles,
///    cabin numbers) so kids can't be coaxed into sharing contact details.
///
/// The filter runs on the sender (message never leaves the phone) and again on every
/// receiver, so a modified app can't bypass it.
nonisolated struct ContentFilter: Sendable {
    enum Reason: Equatable, Sendable {
        case inappropriate
        case personalInfo

        var message: String {
            switch self {
            case .inappropriate:
                "Let's keep it friendly. That has words that aren't allowed in CruiseLAN."
            case .personalInfo:
                "For safety, you can't share phone numbers, emails, links, social media, or cabin numbers."
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        case allowed
        case blocked(Reason)

        var isAllowed: Bool { self == .allowed }
    }

    static let shared = ContentFilter(termsFile: Bundle.main.url(forResource: "SafetyTerms", withExtension: "txt"))

    private let patterns: [NSRegularExpression]
    private let allowlist: [String]

    var patternCount: Int { patterns.count }

    init(termsFile: URL?) {
        let text = termsFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        self.init(termsText: text)
    }

    init(termsText: String) {
        var patterns: [NSRegularExpression] = []
        var allowlist: [String] = []
        for line in termsText.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("P "), let regex = Self.compile(String(line.dropFirst(2))) {
                patterns.append(regex)
            } else if line.hasPrefix("A ") {
                allowlist.append(String(line.dropFirst(2)))
            }
        }
        self.patterns = patterns
        self.allowlist = allowlist
    }

    // MARK: - Public API

    func check(_ text: String) -> Verdict {
        if Self.containsPersonalInfo(text) { return .blocked(.personalInfo) }
        // Check the text as written and with run-together words split apart
        // ("SexyKid", "sexy123"), each also with spaced-out letters rejoined.
        for source in [text, Self.splitRunTogetherWords(text)] {
            let transformed = Self.transform(source)
            for variant in [transformed, Self.joinSpacedLetters(transformed)] where containsBlockedTerm(variant) {
                return .blocked(.inappropriate)
            }
        }
        return .allowed
    }

    /// Nicknames get the same checks; callers reject (rather than mask) on failure.
    func checkNickname(_ name: String) -> Verdict {
        check(name)
    }

    /// A display-safe version of a remote nickname.
    func safeNickname(_ name: String) -> String {
        check(name).isAllowed ? name : "Player"
    }

    // MARK: - Matching

    private func containsBlockedTerm(_ text: String) -> Bool {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var allowedRanges: [NSRange]?

        for regex in patterns {
            for match in regex.matches(in: text, range: fullRange) {
                // Lazily compute allowlisted spans only when something matches.
                let spans = allowedRanges ?? allowlistRanges(in: nsText)
                allowedRanges = spans
                let covered = spans.contains { NSIntersectionRange($0, match.range) == match.range }
                if !covered { return true }
            }
        }
        return false
    }

    private func allowlistRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        for term in allowlist {
            var search = NSRange(location: 0, length: text.length)
            while true {
                let found = text.range(of: term, options: [], range: search)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                let next = found.location + 1
                guard next < text.length else { break }
                search = NSRange(location: next, length: text.length - next)
            }
        }
        return ranges
    }

    /// Converts the term-file pattern syntax into a regular expression.
    /// `|` at either end = word boundary, `[x]` = optional, `?` = any one character, `\` escapes.
    static func compile(_ pattern: String) -> NSRegularExpression? {
        var regex = ""
        var characters = Array(pattern)
        var leadingBoundary = false
        var trailingBoundary = false
        if characters.first == "|" {
            leadingBoundary = true
            characters.removeFirst()
        }
        if characters.last == "|", characters.dropLast().last != "\\" {
            trailingBoundary = true
            characters.removeLast()
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                index += 1
                if index < characters.count { regex += NSRegularExpression.escapedPattern(for: String(characters[index])) }
            case "[":
                var optional = ""
                index += 1
                while index < characters.count, characters[index] != "]" {
                    optional.append(characters[index])
                    index += 1
                }
                // `[?]` is an optional wildcard; anything else is an optional literal.
                let body = optional == "?" ? "." : NSRegularExpression.escapedPattern(for: optional)
                regex += "(?:\(body))?"
            case "?":
                regex += "."
            default:
                regex += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }

        let boundary = "[\\p{L}\\p{N}]"
        if leadingBoundary { regex = "(?<!\(boundary))" + regex }
        if trailingBoundary { regex += "(?!\(boundary))" }
        return try? NSRegularExpression(pattern: regex)
    }

    // MARK: - Normalization

    /// Common look-alike letters from other scripts mapped to Latin.
    private static let confusables: [Character: Character] = [
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j",
        "ѕ": "s", "ԁ": "d", "к": "k", "м": "m", "т": "t", "в": "b", "н": "h", "ɡ": "g", "ν": "v",
        "ο": "o", "α": "a", "ρ": "p", "τ": "t", "κ": "k", "ι": "i", "ε": "e", "υ": "u", "χ": "x",
        "β": "b", "η": "n", "μ": "u", "ł": "l", "ø": "o", "ß": "s", "ı": "i",
    ]

    private static let leet: [Character: Character] = [
        "@": "a", "4": "a", "(": "c", "3": "e", "1": "i", "!": "i", "|": "i", "6": "g",
        "0": "o", "$": "s", "5": "s", "7": "t", "+": "t", "8": "b",
    ]

    /// Letters that may legitimately appear doubled in the term list.
    private static let keepDouble: Set<Character> = ["b", "e", "o", "l", "s", "g"]

    /// Mirrors `collapse()` in Tools/build_safety_terms.py.
    static func transform(_ text: String) -> String {
        let folded = lightNormalize(text)
        var mapped = ""
        for character in folded {
            let latin = confusables[character] ?? character
            mapped.append(leet[latin] ?? latin)
        }
        return collapseRepeats(mapped)
    }

    /// Unicode compatibility mapping, case/accent/width folding, and removal of invisible characters.
    static func lightNormalize(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let visible = compatible.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .format, .control, .nonspacingMark, .enclosingMark:
                // Keep whitespace controls (tab, newline) so words stay separated.
                return scalar.properties.isWhitespace
            default:
                return true
            }
        }
        return String(String.UnicodeScalarView(visible)).lowercased()
    }

    static func collapseRepeats(_ text: String) -> String {
        var result: [Character] = []
        for character in text {
            if let last = result.last, last == character {
                let limit = keepDouble.contains(character) ? 2 : 1
                let run = result.reversed().prefix { $0 == character }.count
                if run >= limit { continue }
            }
            result.append(character)
        }
        return String(result)
    }

    /// Inserts a space at lower→upper case changes and letter↔digit changes.
    static func splitRunTogetherWords(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if let previous,
               (previous.isLowercase && character.isUppercase)
                || (previous.isLetter && character.isNumber)
                || (previous.isNumber && character.isLetter) {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    /// Joins runs of three or more single letters split by spaces or punctuation
    /// ("s e x", "f.u.c.k") so they're checked as one word.
    static func joinSpacedLetters(_ text: String) -> String {
        let tokens = text.split(omittingEmptySubsequences: false) { !$0.isLetter && !$0.isNumber }
        var output: [String] = []
        var run: [Substring] = []

        func flush() {
            if run.count >= 3 {
                output.append(run.joined())
            } else {
                output.append(contentsOf: run.map(String.init))
            }
            run = []
        }

        for token in tokens where !token.isEmpty {
            if token.count == 1 {
                run.append(token)
            } else {
                flush()
                output.append(String(token))
            }
        }
        flush()
        return collapseRepeats(output.joined(separator: " "))
    }

    // MARK: - Personal information

    private static let personalInfoPatterns: [NSRegularExpression] = [
        // Email addresses.
        #"[a-z0-9._%+\-]+\s*(@|\(at\)|\[at\])\s*[a-z0-9.\-]+\s*(\.|\(dot\)|\[dot\])\s*[a-z]{2,}"#,
        // Links.
        #"(https?://|www\.)"#,
        #"\b[a-z0-9\-]{2,}\.(com|net|org|io|co|me|gg|app|ly|tv|xyz|info|biz|us|uk|ca|link)\b"#,
        #"\b[a-z0-9\-]{2,}\s*(\(dot\)|\[dot\]|\sdot\s)\s*(com|net|org)\b"#,
        // Phone numbers: seven or more digits, allowing common separators.
        #"(?:\d[\s\-.()]*){7,}"#,
        // Social media handles and "add me" requests.
        #"\b(snapchat|snap\s*me|snap\s*is|my\s*snap|instagram|insta|my\s*ig|discord|whatsapp|whats\s*app|telegram|kik|tiktok|facebook|fb\s*messenger|wechat|my\s*number|phone\s*number|text\s*me\s*at|add\s*me\s*on)\b"#,
        #"(^|\s)@[a-z0-9_.]{3,}"#,
        // Cabin or room numbers on a ship or in a hotel.
        #"\b(cabin|room|stateroom|suite)\s*(number|no\.?|#)?\s*\d{3,5}\b"#,
        // ...including digits spaced out ("cabin 8 2 1 4").
        #"\b(cabin|room|stateroom|suite)\s*(number|no\.?|#)?\s*(\d[\s\-.,/_*]*){3,5}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Dates like 10/15/2026 are fine to share; they're removed before the digit-run check.
    private static let datePattern = #"\b\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}\b"#

    static func containsPersonalInfo(_ text: String) -> Bool {
        let normalized = lightNormalize(text)
        let range = NSRange(normalized.startIndex..., in: normalized)
        if personalInfoPatterns.contains(where: { $0.firstMatch(in: normalized, range: range) != nil }) { return true }
        // A phone number split up by any separators ("555/123/4567", "555_123*4567") still
        // has seven or more digits once the separators are gone.
        let withoutDates = normalized.replacingOccurrences(of: datePattern, with: " ", options: .regularExpression)
        let joined = withoutDates.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
        return joined.range(of: #"\d{7,}"#, options: .regularExpression) != nil
    }
}
