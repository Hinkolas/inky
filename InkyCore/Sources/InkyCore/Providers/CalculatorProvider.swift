import Foundation

/// Answers arithmetic as it is typed.
@MainActor
public final class CalculatorProvider: Provider {
    public let id = "calculator"
    public let info = ProviderInfo(
        title: "Calculator",
        summary: "Type a calculation to see its result. Return copies it.",
        icon: .symbol("plus.forwardslash.minus", tint: .orange)
    )
    public var onChange: (@MainActor () -> Void)?

    private let calculator: Calculator

    public init(calculator: Calculator = Calculator()) {
        self.calculator = calculator
    }

    public func instantResults(for query: String) -> [ResultItem] {
        guard let value = calculator.evaluate(query) else { return [] }
        let result = calculator.format(value)
        return [
            ResultItem(
                id: "calculator:result",
                title: result,
                subtitle: query.trimmingCharacters(in: .whitespaces),
                icon: info.icon,
                kind: "Calculator",
                actions: [
                    .copy(calculator.format(value, grouping: false), title: "Copy Result"),
                    .copy("\(query.trimmingCharacters(in: .whitespaces)) = \(result)", title: "Copy Calculation"),
                ]
            ),
        ]
    }
}
