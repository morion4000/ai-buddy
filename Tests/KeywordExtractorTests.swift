import Foundation

@main
enum KeywordExtractorTests {
    static func main() {
        extractsTopicalAndTechnicalTerms()
        deduplicatesCaseAndInflections()
        filtersGenericTranscriptWords()
        respectsLimitAndRecency()
        print("KeywordExtractor tests passed")
    }

    private static func extractsTopicalAndTechnicalTerms() {
        let result = KeywordExtractor.extract(from: [
            "Kubernetes clusters run the GraphQL API for Acme.",
            "Acme deploys Kubernetes containers.",
        ])
        let folded = Set(result.map { $0.lowercased() })
        require(folded.contains("kubernetes"), "expected Kubernetes keyword")
        require(folded.contains("graphql"), "expected GraphQL keyword")
        require(folded.contains("acme"), "expected Acme keyword")
    }

    private static func deduplicatesCaseAndInflections() {
        let result = KeywordExtractor.extract(from: [
            "GraphQL powers projects. graphql supports another project.",
        ])
        require(result.filter { $0.lowercased() == "graphql" }.count == 1,
                "expected case-insensitive keyword deduplication")
        require(result.filter { $0.lowercased() == "project" }.count == 1,
                "expected lemma-based keyword deduplication")
    }

    private static func filtersGenericTranscriptWords() {
        let result = KeywordExtractor.extract(from: [
            "Things and stuff take time. The transcription contains words and speech.",
        ])
        let folded = Set(result.map { $0.lowercased() })
        for generic in ["thing", "things", "stuff", "time", "transcription", "word", "words", "speech"] {
            require(!folded.contains(generic), "did not expect generic keyword: \(generic)")
        }
    }

    private static func respectsLimitAndRecency() {
        let result = KeywordExtractor.extract(from: ["The orchid blooms.", "A volcano erupts.", "The harbor closes."], limit: 2)
        require(result.count == 2, "expected keyword limit to be respected")
        require(result.map { $0.lowercased() }.contains("orchid"),
                "expected newest transcript to break score ties; got \(result)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            exit(1)
        }
    }
}
