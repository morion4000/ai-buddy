import Foundation

/// `TextInjector.edit` decides how many characters get deleted from the user's
/// document, so it's worth pinning down exactly. Over-deleting eats text the app
/// never wrote; under-deleting leaves the draft's wrong words behind.
@main
enum TextEditTests {
    static func main() {
        appendsWhenDraftOnlyGrows()
        rewritesOnlyTheChangedTail()
        deletesEverythingWhenNothingMatches()
        handlesEmptyEndpoints()
        countsGraphemesNotBytes()
        print("TextInjector.edit tests passed")
    }

    /// The common case while speaking: recognition adds words to what it already
    /// emitted, so nothing should be deleted.
    private static func appendsWhenDraftOnlyGrows() {
        let e = TextInjector.edit(from: "the quick", to: "the quick brown")
        require(e.delete == 0, "expected no deletion when text only grows, got \(e.delete)")
        require(e.insert == " brown", "expected to append the new tail, got '\(e.insert)'")
    }

    /// Gemini's wording differs from the draft near the end — only the tail from
    /// the first difference onward is rewritten, not the whole line.
    ///
    /// Correction happens with backspaces, which only remove from the end, so a
    /// common *suffix* can't be salvaged: fixing "fax" to "fox" has to delete the
    /// "ax" it already passed over and retype "ox". Only the prefix is free.
    private static func rewritesOnlyTheChangedTail() {
        let e = TextInjector.edit(from: "the quick brown fax", to: "the quick brown fox")
        require(e.delete == 2, "expected to delete from the first difference, got \(e.delete)")
        require(e.insert == "ox", "expected to retype the tail, got '\(e.insert)'")

        // "meeting at noon to" (18 chars) is shared, so only "morrow" is deleted.
        let long = TextInjector.edit(from: "meeting at noon tomorrow", to: "meeting at noon today")
        require(long.delete == 6, "expected only the tail deleted, got \(long.delete)")
        require(long.insert == "day", "expected only the tail retyped, got '\(long.insert)'")
    }

    private static func deletesEverythingWhenNothingMatches() {
        let e = TextInjector.edit(from: "hello", to: "world")
        require(e.delete == 5, "expected a full delete, got \(e.delete)")
        require(e.insert == "world", "expected a full retype, got '\(e.insert)'")
    }

    /// Discarding a draft (target empty) must delete exactly what was typed, and
    /// a first draft from nothing must not try to delete.
    private static func handlesEmptyEndpoints() {
        let cleared = TextInjector.edit(from: "draft text", to: "")
        require(cleared.delete == 10, "expected to remove the whole draft, got \(cleared.delete)")
        require(cleared.insert.isEmpty, "expected nothing typed back, got '\(cleared.insert)'")

        let fresh = TextInjector.edit(from: "", to: "hello")
        require(fresh.delete == 0, "expected no deletion from an empty start, got \(fresh.delete)")
        require(fresh.insert == "hello", "expected the full text, got '\(fresh.insert)'")
    }

    /// Backspace removes one grapheme cluster, so the count must be in Characters.
    /// Counting UTF-16 units here would delete twice as much as it should.
    private static func countsGraphemesNotBytes() {
        let e = TextInjector.edit(from: "hi 👍🏽", to: "hi ")
        require(e.delete == 1, "expected one grapheme deleted, got \(e.delete)")
        require(e.insert.isEmpty, "expected nothing retyped, got '\(e.insert)'")

        let accented = TextInjector.edit(from: "café", to: "cafés")
        require(accented.delete == 0, "expected no deletion, got \(accented.delete)")
        require(accented.insert == "s", "expected to append 's', got '\(accented.insert)'")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            exit(1)
        }
    }
}
