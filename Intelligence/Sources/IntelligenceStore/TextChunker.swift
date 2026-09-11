import Foundation

/// Splits a note into retrievable pieces.
///
/// Chunk size is a retrieval decision, not a storage one. Too large and a hit
/// drags three unrelated paragraphs into a prompt that is read mid-sentence; too
/// small and a fact loses the sentence that qualified it. ~400 characters is about
/// a paragraph, which is also the unit people naturally write a fact in.
///
/// Paragraph boundaries are preferred over sentence boundaries over hard cuts, in
/// that order — a note is usually already structured by the person who wrote it,
/// and respecting that beats any splitting heuristic.
enum TextChunker {
    struct Located: Sendable, Equatable {
        var text: String
        var page: Int?
        var section: String?
    }
    static let target = 400
    /// Carried from the previous chunk so a fact split across a boundary is still
    /// findable from either side.
    static let overlap = 80

    static func chunks(of text: String, target: Int = target, overlap: Int = overlap) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > target else { return [trimmed] }

        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs(of: trimmed) {
            // A paragraph that is itself oversized gets split on sentences; the
            // rest are packed whole.
            if paragraph.count > target {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: split(paragraph, target: target, overlap: overlap))
                continue
            }
            if current.isEmpty {
                current = paragraph
            } else if current.count + paragraph.count + 2 <= target {
                current += "\n\n" + paragraph
            } else {
                chunks.append(current)
                current = paragraph
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Page markers are inserted by `KnowledgeDocumentReader` before text crosses
    /// process boundary. Split pages first so overlap never leaks across them.
    static func locatedChunks(of text: String, target: Int = target, overlap: Int = overlap) -> [Located] {
        let pattern = #"\[\[CALLA_PAGE:(\d+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return chunks(of: text, target: target, overlap: overlap).map { Located(text: $0, page: nil, section: nil) }
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else {
            return chunks(of: text, target: target, overlap: overlap).map { Located(text: $0, page: nil, section: nil) }
        }

        var result: [Located] = []
        var cursor = text.startIndex
        var page: Int?
        for match in matches {
            guard let markerRange = Range(match.range, in: text) else { continue }
            let segment = String(text[cursor ..< markerRange.lowerBound])
            result += chunks(of: segment, target: target, overlap: overlap)
                .map { Located(text: $0, page: page, section: nil) }
            if let numberRange = Range(match.range(at: 1), in: text) {
                page = Int(text[numberRange])
            }
            cursor = markerRange.upperBound
        }
        result += chunks(of: String(text[cursor...]), target: target, overlap: overlap)
            .map { Located(text: $0, page: page, section: nil) }
        return result
    }

    private static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func split(_ text: String, target: Int, overlap: Int) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: .bySentences) { substring, _, _, _ in
            if let substring = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !substring.isEmpty {
                sentences.append(substring)
            }
        }
        // enumerateSubstrings finds nothing in text with no sentence terminators
        // at all — a pasted list of identifiers, say. Fall back to hard slices so
        // that content is still indexed rather than dropped.
        if sentences.isEmpty { return hardSlices(text, target: target, overlap: overlap) }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            if sentence.count > target {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: hardSlices(sentence, target: target, overlap: overlap))
                continue
            }
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count + 1 <= target {
                current += " " + sentence
            } else {
                chunks.append(current)
                current = tail(of: current, length: overlap) + " " + sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func hardSlices(_ text: String, target: Int, overlap: Int) -> [String] {
        var slices: [String] = []
        var index = text.startIndex
        // The stride must exceed zero or this loops forever; a caller passing an
        // overlap at or above the target is a programming error, not user input.
        let stride = max(1, target - overlap)
        while index < text.endIndex {
            let end = text.index(index, offsetBy: target, limitedBy: text.endIndex) ?? text.endIndex
            slices.append(String(text[index ..< end]))
            guard end < text.endIndex else { break }
            index = text.index(index, offsetBy: stride, limitedBy: text.endIndex) ?? text.endIndex
        }
        return slices
    }

    private static func tail(of text: String, length: Int) -> String {
        guard text.count > length else { return text }
        let start = text.index(text.endIndex, offsetBy: -length)
        let slice = text[start...]
        // Start the carried context at a word boundary; half a word helps nobody.
        if let space = slice.firstIndex(where: { $0.isWhitespace }) {
            return String(slice[slice.index(after: space)...])
        }
        return String(slice)
    }
}
