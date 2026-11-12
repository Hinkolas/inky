import Foundation

/// Answers questions about times and days as they are typed.
@MainActor
public final class TimeModule: Module {
    public let id = "time"
    public let info = ModuleInfo(
        title: "Time",
        summary: "Type a question about a time or a day to see its answer. Return copies it.",
        icon: .symbol("clock.fill", tint: .blue)
    )
    public var onChange: (@MainActor () -> Void)?

    private let calculator: TimeCalculator

    /// By default the user's time zone is followed as it changes.
    public init(calculator: TimeCalculator = TimeCalculator(timeZone: .autoupdatingCurrent)) {
        self.calculator = calculator
        // Reading the list of places takes a while, which Inky does not wait
        // for as it starts, and the first time asked for does not either.
        Task.detached(priority: .utility) { _ = PlaceIndex.shared }
    }

    public func instantResults(for query: String) -> [ResultItem] {
        guard let answer = calculator.answer(query) else { return [] }
        var actions: [Action] = [.copy(answer.title, title: "Copy Answer")]
        if let timestamp = answer.timestamp {
            actions.append(.copy(timestamp, title: "Copy Timestamp"))
        }
        return [
            ResultItem(
                id: "time:result",
                title: answer.title,
                subtitle: answer.subtitle,
                icon: info.icon,
                kind: "Time",
                actions: actions
            ),
        ]
    }
}
