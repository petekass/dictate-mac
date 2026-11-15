import Foundation

/// Finds vocabulary terms in the user's corrections of a pasted dictation.
///
/// Only a word that was replaced by a similarly spelled word (or a one-to-two-word split
/// or merge, e.g. "Cloutcode" -> "Claude Code") counts as a correction. Rewrites, deletions
/// and additions teach nothing, because a wrong term biases every later dictation.
enum CorrectionLearner {
    struct Word: Equatable {
        let text: String
        var key: String { text.lowercased() }
    }

    static let maxTermsPerDictation = 2

    /// `isKnownWord` returns true for words a spell checker accepts. Replacing a known word
    /// with known words is usually a grammar edit ("Haus" -> "Hause") and teaches nothing;
    /// a misheard non-word ("Cloutcode") or an unknown correction ("Ospivo") does.
    static func learnedTerms(pasted: String, edited: String, isKnownWord: (String) -> Bool) -> [String] {
        let original = words(in: pasted)
        let current = words(in: edited)
        guard original.count >= 2, !current.isEmpty else { return [] }

        let matches = lcs(original.map(\.key), current.map(\.key))
        // Mostly rewritten or deleted: nothing to learn.
        guard Double(matches.count) >= Double(original.count) * 0.6, !matches.isEmpty else { return [] }

        var found: [String] = []
        // Capitalisation fixes of unknown words ("ospivo" -> "Ospivo").
        for (originalIndex, currentIndex) in matches {
            let before = original[originalIndex].text
            let after = current[currentIndex].text
            if before != after, after.count >= 3, !isKnownWord(after), !isKnownWord(before), !found.contains(after) {
                found.append(after)
            }
        }
        // Gaps between consecutive anchors, plus the edges next to the first and last anchor.
        var anchors: [(Int, Int)] = [(-1, -1)] + matches + [(original.count, current.count)]
        anchors.sort { $0.0 < $1.0 }
        for index in 0..<(anchors.count - 1) {
            let (originalStart, currentStart) = anchors[index]
            let (originalEnd, currentEnd) = anchors[index + 1]
            let originalGap = Array(original[(originalStart + 1)..<originalEnd])
            var currentGap = Array(current[(currentStart + 1)..<currentEnd])
            guard !originalGap.isEmpty, !currentGap.isEmpty else { continue }
            // At the edges the field may hold unrelated text; only the word next to the anchor counts.
            if index == 0 { currentGap = Array(currentGap.suffix(originalGap.count == 1 ? 2 : 1)) }
            if index == anchors.count - 2 { currentGap = Array(currentGap.prefix(originalGap.count == 1 ? 2 : 1)) }

            if let term = correction(from: originalGap, to: currentGap, edge: index == 0 || index == anchors.count - 2),
               !(term.split(separator: " ").allSatisfy { isKnownWord(String($0)) }
                 && originalGap.allSatisfy { isKnownWord($0.text) }),
               !found.contains(term) {
                found.append(term)
            }
        }
        return Array(found.prefix(maxTermsPerDictation))
    }

    private static func correction(from original: [Word], to current: [Word], edge: Bool) -> String? {
        // At an edge the second word may be unrelated text; prefer the single adjacent word.
        if edge, original.count == 1, current.count == 2,
           let single = correction(from: original, to: [current[0]], edge: false)
            ?? correction(from: original, to: [current[1]], edge: false) {
            return single
        }
        // Single word, or one word split into two / two merged into one.
        guard original.count <= 2, current.count <= 2, original.count + current.count <= 3 else { return nil }
        let before = original.map(\.text).joined(separator: " ")
        let after = current.map(\.text).joined(separator: " ")
        guard before != after else { return nil }
        let a = before.lowercased().replacingOccurrences(of: " ", with: "")
        let b = after.lowercased().replacingOccurrences(of: " ", with: "")
        guard after.count >= 3, after.count <= 40, after.rangeOfCharacter(from: .letters) != nil else { return nil }
        let distance = Double(levenshtein(Array(a), Array(b))) / Double(max(a.count, b.count))
        let sameStart = a.first == b.first
        guard distance <= 0.34 || (sameStart && distance <= 0.6) else { return nil }
        return after
    }

    /// Share of the pasted words still present, in order, in the edited text.
    static func overlap(pasted: String, edited: String) -> Double {
        let original = words(in: pasted)
        guard !original.isEmpty else { return 0 }
        let matches = lcs(original.map(\.key), words(in: edited).map(\.key))
        return Double(matches.count) / Double(original.count)
    }

    /// Words keep inner dots, hyphens and underscores ("Next.js", "CLAUDE.md").
    static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let isInner = ".-_'".contains(character)
                && !current.isEmpty
                && index + 1 < characters.count
                && (characters[index + 1].isLetter || characters[index + 1].isNumber)
            if character.isLetter || character.isNumber || isInner {
                current.append(character)
            } else if !current.isEmpty {
                result.append(Word(text: current))
                current = ""
            }
        }
        if !current.isEmpty { result.append(Word(text: current)) }
        return result
    }

    /// Index pairs of a longest common subsequence.
    private static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }
}
