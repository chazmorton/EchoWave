import Foundation

/// The user's custom vocabulary: plain lines are terms whose spelling and capitalization
/// should be preserved; `spoken -> written` lines are replacements.
struct VocabularyRules {
    private(set) var terms: [String] = []
    private(set) var replacements: [(spoken: String, written: String)] = []

    init(_ text: String) {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let arrow = line.range(of: "->") ?? line.range(of: "→") {
                let spoken = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let written = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !spoken.isEmpty else { continue }
                replacements.append((spoken, written))
            } else {
                terms.append(line)
            }
        }
    }

    /// Hints passed to the speech model to make these words more likely.
    var contextualStrings: [String] {
        var seen = Set<String>()
        let candidates = terms + replacements.map(\.written).filter { !$0.isEmpty }
        return candidates.filter { seen.insert($0.lowercased()).inserted }
    }
}

enum TranscriptFormatter {
    static func format(_ raw: String, rules: VocabularyRules) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        for (spoken, written) in rules.replacements {
            text = replacingWholeWords(spoken, in: text) { match in
                // "Gonna…" at the start of a sentence should become "Going to…", not "going to…".
                guard let first = match.first, first.isUppercase,
                      let replacementFirst = written.first, replacementFirst.isLowercase
                else { return written }
                return replacementFirst.uppercased() + written.dropFirst()
            }
        }
        for term in rules.terms {
            text = replacingWholeWords(term, in: text) { _ in term }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case-insensitive, whole-word replacement.
    private static func replacingWholeWords(_ word: String, in text: String, with replacement: (Substring) -> String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            result += replacement(text[range])
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
