import Foundation
import Observation

/// Answers calculations and conversions as they are typed.
@MainActor
public final class CalculatorProvider: Provider {
    public let id = "calculator"
    public let info = ProviderInfo(
        title: "Calculator",
        summary: "Type a calculation or a conversion to see its result. Return copies it.",
        icon: .symbol("plus.forwardslash.minus", tint: .orange)
    )
    public var onChange: (@MainActor () -> Void)?

    /// How many pixels a rem and an em are, for "2rem in px".
    public var pixelsPerRem: Double = 16 {
        didSet {
            if pixelsPerRem != oldValue { buildUnits() }
        }
    }

    private var calculator: Calculator
    /// The units that never change. Those of a web page and the currencies
    /// are added to them.
    private let units: UnitTable
    private let exchangeRates: ExchangeRateStore?
    private var ratesInUse: ExchangeRates?

    /// Without `exchangeRates`, currencies are not understood.
    public init(calculator: Calculator = Calculator(), exchangeRates: ExchangeRateStore? = nil) {
        self.calculator = calculator
        units = calculator.units
        self.exchangeRates = exchangeRates
        buildUnits()
        watchRates()
    }

    public func instantResults(for query: String) -> [ResultItem] {
        useCurrentRates()
        guard let calculation = calculator.calculate(query) else { return [] }
        let query = query.trimmingCharacters(in: .whitespaces)
        var subtitle = query
        if calculation.usesExchangeRates, let day = ratesInUse?.day {
            subtitle += " · rates of " + day.formatted(Self.dayStyle.locale(calculator.locale))
        }
        return [
            ResultItem(
                id: "calculator:result",
                title: calculation.text,
                subtitle: subtitle,
                icon: info.icon,
                kind: "Calculator",
                actions: [
                    .copy(calculation.plain, title: "Copy Result"),
                    .copy("\(query) = \(calculation.text)", title: "Copy Calculation"),
                ]
            ),
        ]
    }

    /// Typing is what asks for newer rates, so a calculator that is turned
    /// off makes no requests. The currencies are rebuilt only when the rates
    /// have changed.
    private func useCurrentRates() {
        guard let exchangeRates else { return }
        exchangeRates.update()
        let rates = exchangeRates.rates
        guard rates != ratesInUse else { return }
        ratesInUse = rates
        buildUnits()
    }

    private func buildUnits() {
        let units = units.adding(pixelsPerRem: pixelsPerRem)
        calculator.units = ratesInUse.map { units.adding($0, locale: calculator.locale) } ?? units
    }

    /// Says so when the rates change. A result that is on screen may be of
    /// the old ones, or be missing because there were none yet.
    private func watchRates() {
        guard let exchangeRates else { return }
        withObservationTracking {
            _ = exchangeRates.rates
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.onChange?()
                self?.watchRates()
            }
        }
    }

    /// The day of the rates is one in Greenwich, wherever it is read.
    private static let dayStyle: Date.FormatStyle = {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        style.timeZone = .gmt
        return style
    }()
}
