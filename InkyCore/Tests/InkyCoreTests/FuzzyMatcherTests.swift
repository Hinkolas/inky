import Testing
@testable import InkyCore

@Suite struct FuzzyMatcherTests {
    private func score(_ pattern: String, _ target: String) -> Double {
        FuzzyMatcher.score(pattern, in: target) ?? -1
    }

    @Test func rejectsWhatIsNotASubsequence() {
        #expect(FuzzyMatcher.score("xyz", in: "Safari") == nil)
        #expect(FuzzyMatcher.score("safarii", in: "Safari") == nil)
        #expect(FuzzyMatcher.score("", in: "Safari") == nil)
    }

    @Test func exactMatchIsPerfect() {
        #expect(score("safari", "Safari") == 1)
    }

    @Test func ignoresCaseAndDiacritics() {
        #expect(score("uber", "Über") == 1)
        #expect(score("CAFE", "café") == 1)
    }

    @Test func prefixBeatsMatchInsideAWord() {
        #expect(score("saf", "Safari") > score("saf", "Disk Safety"))
        #expect(score("term", "Terminal") > score("term", "iTerm"))
    }

    @Test func wordStartsBeatScatteredLetters() {
        #expect(score("vsc", "Visual Studio Code") > score("vsc", "Vivaldi Sync"))
        #expect(score("ka", "Keychain Access") > score("ka", "Kiwix Reader"))
    }

    @Test func shorterTargetWinsOnEqualPrefix() {
        #expect(score("note", "Notes") > score("note", "Notes Exporter Pro"))
    }

    @Test func camelCaseCountsAsAWordStart() {
        #expect(score("gh", "GitHub") > score("gh", "Laughter"))
    }
}
