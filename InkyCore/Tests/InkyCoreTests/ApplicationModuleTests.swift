import Foundation
import Testing
@testable import InkyCore

@MainActor
@Suite struct ApplicationModuleTests {
    /// A home of its own, with a folder of made-up applications.
    private let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("inky-applications-\(UUID().uuidString)", isDirectory: true)
    private var applications: URL { home.appendingPathComponent("Applications", isDirectory: true) }

    init() throws {
        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("One.app/Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func makeModule() -> ApplicationModule {
        ApplicationModule(
            uninstaller: ApplicationUninstaller(home: home.path, coversSystem: false),
            folders: [applications.path],
            latency: 0.05
        )
    }

    /// Waits for the module to say that something changed, for at most `limit`.
    private func waitForChange(_ changes: () -> Int, from count: Int, limit: Duration = .seconds(5)) async throws {
        let end = ContinuousClock.now + limit
        while changes() == count, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func listsAgainOnlyWhenTheApplicationsChanged() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let module = makeModule()
        var changes = 0
        module.onChange = { changes += 1 }
        #expect(await module.candidates().map(\.title).contains("One"))

        // An application that writes into its own folder is still the same.
        try Data("x".utf8).write(to: applications.appendingPathComponent("One.app/Contents/state"))
        try Data("x".utf8).write(to: applications.appendingPathComponent("notes.txt"))
        try await Task.sleep(for: .seconds(1))
        #expect(changes == 0)

        // One that is new is listed.
        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("Two.app", isDirectory: true), withIntermediateDirectories: true
        )
        try await waitForChange({ changes }, from: 0)
        #expect(changes == 1)
        #expect(await module.candidates().map(\.title).contains("Two"))

        // So is one that went.
        try FileManager.default.removeItem(at: applications.appendingPathComponent("One.app"))
        try await waitForChange({ changes }, from: 1)
        #expect(changes == 2)
        #expect(await !module.candidates().map(\.title).contains("One"))
    }

    @Test func watchesAFolderOfApplicationsThatIsNotThereYet() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.removeItem(at: applications)
        let module = makeModule()
        var changes = 0
        module.onChange = { changes += 1 }
        #expect(await !module.candidates().map(\.title).contains("One"))

        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("One.app", isDirectory: true), withIntermediateDirectories: true
        )
        try await waitForChange({ changes }, from: 0)
        #expect(changes == 1)
        #expect(await module.candidates().map(\.title).contains("One"))

        // And what happens in it from then on.
        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("Two.app", isDirectory: true), withIntermediateDirectories: true
        )
        try await waitForChange({ changes }, from: 1)
        #expect(changes == 2)
    }
}
