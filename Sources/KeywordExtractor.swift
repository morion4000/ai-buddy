import Foundation
import NaturalLanguage

/// Extracts a small, stable set of topical terms from locally saved transcripts.
/// This is intentionally local and deterministic: learning from history adds no
/// network request, latency, or token cost.
enum KeywordExtractor {
    private struct Candidate {
        var display: String
        var mentions = 0
        var documents = 0
        var mostRecentDocument = Int.max
        var isNameOrTechnical = false
    }

    /// Words that may be nouns in casual dictation but carry little topical context.
    /// Lexical tagging does most of the filtering; this list removes common leftovers.
    private static let stopWords: Set<String> = [
        "anything", "app", "audio", "conversation", "conversations", "day", "example",
        "idea", "kind", "lot", "maybe", "nothing", "part", "people", "person", "place",
        "question", "recording", "recordings", "something", "speech", "stuff", "text",
        "thing", "things", "time", "times", "today", "tomorrow", "transcript",
        "transcription", "transcriptions", "way", "week", "word", "words", "yesterday",
    ]

    /// Returns the highest-signal nouns, names, and technical tokens. `texts` must be
    /// newest-first so recency can break otherwise-equal scores.
    static func extract(from texts: [String], limit: Int = 20) -> [String] {
        guard limit > 0 else { return [] }
        var candidates: [String: Candidate] = [:]

        for (documentIndex, text) in texts.enumerated() where !text.isEmpty {
            let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType, .lemma])
            tagger.string = text
            var keysInDocument = Set<String>()

            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex,
                unit: .word,
                scheme: .lexicalClass,
                options: [.omitWhitespace, .omitPunctuation]
            ) { lexicalTag, range in
                let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isUsable(token) else { return true }

                let nameTag = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType).0
                let isName = nameTag == .personalName || nameTag == .placeName || nameTag == .organizationName
                let isTechnical = looksTechnical(token)
                let isNoun = lexicalTag == .noun
                guard isNoun || isName || isTechnical else { return true }

                let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
                let key = normalized((lemma?.isEmpty == false ? lemma! : token))
                guard !key.isEmpty, !stopWords.contains(key) else { return true }

                var candidate = candidates[key] ?? Candidate(display: token)
                candidate.mentions += 1
                candidate.mostRecentDocument = min(candidate.mostRecentDocument, documentIndex)
                candidate.isNameOrTechnical = candidate.isNameOrTechnical || isName || isTechnical
                candidates[key] = candidate
                keysInDocument.insert(key)
                return true
            }

            for key in keysInDocument {
                candidates[key]?.documents += 1
            }
        }

        return candidates.values
            .sorted { lhs, rhs in
                let lhsScore = score(lhs)
                let rhsScore = score(rhs)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if lhs.mostRecentDocument != rhs.mostRecentDocument {
                    return lhs.mostRecentDocument < rhs.mostRecentDocument
                }
                return lhs.display.localizedCaseInsensitiveCompare(rhs.display) == .orderedAscending
            }
            .prefix(limit)
            .map(\.display)
    }

    private static func score(_ candidate: Candidate) -> Int {
        // Repetition across separate transcripts is a stronger signal than repetition
        // inside one transcript. Names and technical spellings get a small boost.
        candidate.documents * 5
            + min(candidate.mentions, 8) * 2
            + (candidate.isNameOrTechnical ? 3 : 0)
    }

    private static func isUsable(_ token: String) -> Bool {
        let letters = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        if letters.count >= 3 { return true }
        // Keep short acronyms such as AI, UI, or API, but not ordinary short words.
        return letters.count >= 2 && letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
    }

    private static func looksTechnical(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        let uppercaseCount = scalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        let containsDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let containsSymbol = token.contains("+") || token.contains("#") || token.contains(".")
        let hasInternalUppercase = scalars.dropFirst().contains { CharacterSet.uppercaseLetters.contains($0) }
        return uppercaseCount >= 2 || containsDigit || containsSymbol || hasInternalUppercase
    }

    private static func normalized(_ token: String) -> String {
        token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
