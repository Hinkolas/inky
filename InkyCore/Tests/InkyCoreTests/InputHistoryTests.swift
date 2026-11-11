import Foundation
import Testing
@testable import InkyCore

@MainActor
@Suite struct InputHistoryTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Inky-InputHistory-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    @Test func theNewestComesFirst() {
        let history = InputHistory(fileURL: nil)
        history.record(query: "maps")
        history.record(query: "5 km in mi")
        #expect(history.entries.map(\.query) == ["5 km in mi", "maps"])
    }

    @Test func typedAgainItMovesToTheFrontInsteadOfBeingListedTwice() {
        let history = InputHistory(fileURL: nil)
        history.record(query: "maps")
        history.record(query: "safari")
        history.record(query: "time in tokyo")
        history.record(query: "maps")
        #expect(history.entries.map(\.query) == ["maps", "time in tokyo", "safari"])
    }

    @Test func spellingAndSpacesAroundItDoNotMakeItSomethingElse() {
        let history = InputHistory(fileURL: nil)
        history.record(query: "maps")
        history.record(query: "  Maps ")
        #expect(history.entries.map(\.query) == ["Maps"])
    }

    @Test func onlyRunningItCounts() {
        let history = InputHistory(fileURL: nil)
        history.record(query: "maps")
        #expect(history.entries[0].count == 0)
        history.record(query: "maps", submitted: true)
        history.record(query: "safari", submitted: true)
        history.record(query: "maps", submitted: true)
        history.record(query: "maps")
        #expect(history.entries.map(\.count) == [2, 1])
    }

    @Test func theArgumentsArePartOfWhatWasTyped() {
        let history = InputHistory(fileURL: nil)
        history.record(query: "google", arguments: ["swift actors"], itemID: "quicklink:google")
        history.record(query: "google", arguments: ["rust traits"], itemID: "quicklink:google")
        history.record(query: "google", arguments: ["Swift Actors "], itemID: "quicklink:google")
        #expect(history.entries.map(\.arguments) == [["Swift Actors"], ["rust traits"]])
        #expect(history.entries[0].itemID == "quicklink:google")
    }

    @Test func argumentsWithNothingInThemAreNone() {
        let history = InputHistory(fileURL: nil)
        history.record(query: "google", arguments: ["", "  "], itemID: "quicklink:google")
        history.record(query: "google")
        #expect(history.entries.count == 1)
        #expect(history.entries[0].arguments.isEmpty)
        // Typed again without a result selected, it is still for the one it was for.
        #expect(history.entries[0].itemID == "quicklink:google")
    }

    @Test func nothingTypedIsNotKept() {
        let history = InputHistory(fileURL: nil)
        history.record(query: "")
        history.record(query: "   ", arguments: ["swift"], submitted: true)
        #expect(history.entries.isEmpty)
    }

    @Test func keepsNoMoreThanTheLimit() {
        let history = InputHistory(fileURL: nil, limit: 3)
        for query in ["one", "two", "three", "four"] {
            history.record(query: query)
        }
        #expect(history.entries.map(\.query) == ["four", "three", "two"])

        history.limit = 1
        #expect(history.entries.map(\.query) == ["four"])
    }

    @Test func aLimitOfNothingRemembersNothing() {
        let history = InputHistory(fileURL: nil)
        history.record(query: "maps")
        history.limit = 0
        #expect(history.entries.isEmpty)
        history.record(query: "safari", submitted: true)
        #expect(history.entries.isEmpty)
    }

    @Test func isReadAgainFromItsFile() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let history = InputHistory(fileURL: file)
        history.record(query: "maps", submitted: true, at: date)
        history.record(query: "google", arguments: ["swift actors"], itemID: "quicklink:google", at: date)

        let read = InputHistory(fileURL: file)
        #expect(read.entries == [
            InputEntry(query: "google", arguments: ["swift actors"], itemID: "quicklink:google", count: 0, lastUsed: date),
            InputEntry(query: "maps", count: 1, lastUsed: date),
        ])

        // A shorter limit applies to what was kept before.
        #expect(InputHistory(fileURL: file, limit: 1).entries.map(\.query) == ["google"])
        #expect(InputHistory(fileURL: file).entries.map(\.query) == ["google"])
    }

    @Test func theFileIsOnlyForItsOwnerToRead() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let history = InputHistory(fileURL: file)
        history.record(query: "maps")
        history.record(query: "safari")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        // Nothing is left of how it was written.
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["history.json"])
    }

    @Test func clearingForgetsEverything() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let history = InputHistory(fileURL: file)
        history.record(query: "maps")
        history.clear()
        #expect(history.entries.isEmpty)
        #expect(InputHistory(fileURL: file).entries.isEmpty)
    }

    @Test func aFileThatCannotBeReadIsAnEmptyHistory() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("not json".utf8).write(to: file)

        let history = InputHistory(fileURL: file)
        #expect(history.entries.isEmpty)
        history.record(query: "maps")
        #expect(InputHistory(fileURL: file).entries.map(\.query) == ["maps"])
    }
}
