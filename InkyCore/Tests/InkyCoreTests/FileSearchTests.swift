import Foundation
import Testing
@testable import InkyCore

@MainActor
@Suite struct FileSearchTests {
    @Test func asksForEveryWordOfTheName() {
        let query = FileQuery(text: "  folder   watch ")
        #expect(query.expression == #"kMDItemDisplayName == "folder*"cdw && kMDItemDisplayName == "watch*"cdw"#)
        #expect(!query.isRecents)
    }

    @Test func escapesWhatSpotlightWouldRead() {
        let query = FileQuery(text: #"a"b c*d e\f"#)
        #expect(query.expression == [
            #"kMDItemDisplayName == "a\"b*"cdw"#,
            #"kMDItemDisplayName == "c\*d*"cdw"#,
            #"kMDItemDisplayName == "e\\f*"cdw"#,
        ].joined(separator: " && "))
    }

    @Test func asksForWhatWasOpenedLatelyWithNothingTyped() {
        let query = FileQuery(text: "   ")
        #expect(query.isRecents)
        #expect(query.expression == "kMDItemLastUsedDate >= $time.now(-2592000)")
    }

    @Test func narrowsDownToAType() {
        #expect(FileQuery(text: "logo", filter: .images).expression
            == #"kMDItemDisplayName == "logo*"cdw && kMDItemContentTypeTree == "public.image""#)
        #expect(FileQuery(text: "", filter: .folders).expression
            == #"kMDItemLastUsedDate >= $time.now(-2592000) && kMDItemContentType == "public.folder""#)
        // Text that is source code is code, not a document.
        #expect(FileQuery(text: "a", filter: .documents).expression.contains(
            #"(kMDItemContentTypeTree == "public.text" && kMDItemContentTypeTree != "public.source-code")"#
        ))
    }

    @Test func everyExpressionIsOneSpotlightReads() {
        for filter in FileFilter.allCases {
            for text in ["", "report", #"it's "quoted" 100% (final) [2].txt"#] {
                let expression = FileQuery(text: text, filter: filter).expression
                #expect(NSPredicate(fromMetadataQueryString: expression) != nil, "\(expression)")
            }
        }
    }

    @Test func ranksABetterNameAboveAMoreRecentOne() {
        // Spotlight lists the most recently used first.
        let names = ["My reports archive.zip", "Notes.txt", "Report.pdf"]
        #expect(FileSearch.ranking(of: names, for: "report").first == 2)
    }

    @Test func keepsTheOrderOfEquallyGoodNames() {
        #expect(FileSearch.ranking(of: ["logo.png", "logo.png", "logo.png"], for: "logo") == [0, 1, 2])
    }

    @Test func ranksWordsTypedInAnotherOrder() {
        let names = ["Watchlist.txt", "FolderWatcher.swift"]
        #expect(FileSearch.ranking(of: names, for: "watcher folder").first == 1)
    }

    @Test func leavesOutWhatNobodyOpensByHand() {
        let home = "/Users/someone"
        #expect(FileSearch.lists("/Users/someone/Documents/Report.pdf", home: home))
        #expect(!FileSearch.lists("/Users/someone/Library/Preferences/a.plist", home: home))
        #expect(!FileSearch.lists("/Users/someone/Applications/Thing.app", home: home))
        #expect(!FileSearch.lists("/Users/someone/code/.git/config", home: home))
        #expect(!FileSearch.lists("/Users/someone/code/node_modules/a/index.js", home: home))
    }

    @Test func describesWhereAFileIs() {
        let hit = FileHit(path: NSHomeDirectory() + "/Documents/Report.pdf", name: "Report.pdf", contentType: "com.adobe.pdf")
        #expect(hit.folder == "~/Documents")
        #expect(!hit.isFolder)
        #expect(FileHit(path: "/tmp/a", name: "a", contentType: "public.folder").isFolder)
    }
}

@Suite struct FileExcerptTests {
    @Test func showsTheBeginningOfText() {
        let text = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = FileExcerpt.text(from: Data(text.utf8), maxLines: 3)
        #expect(excerpt == "line 1\nline 2\nline 3")
    }

    @Test func readsWindowsLineEndings() {
        #expect(FileExcerpt.text(from: Data("a\r\nb\r\n".utf8)) == "a\nb\n")
    }

    @Test func toleratesACharacterCutInTwo() {
        var data = Data("grün und blau – ".utf8)
        data.append(contentsOf: [0xE2, 0x80])
        #expect(FileExcerpt.text(from: data) == "grün und blau – ")
    }

    @Test func refusesWhatIsNotText() {
        #expect(FileExcerpt.text(from: Data()) == nil)
        #expect(FileExcerpt.text(from: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])) == nil)
        #expect(FileExcerpt.text(from: Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0x41])) == nil)
    }

    @Test func cutsALongLineShort() {
        let excerpt = FileExcerpt.text(from: Data(String(repeating: "a", count: 9000).utf8), maxCharacters: 100)
        #expect(excerpt?.count == 100)
    }
}
