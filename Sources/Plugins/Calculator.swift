import AppKit

final class CalculatorPlugin: Plugin, SearchProvider {
    private var history = UserDefaults.standard.data(forKey: "calculations")
        .flatMap { try? JSONDecoder().decode([Calculation].self, from: $0) } ?? []

    private struct Calculation: Codable, Equatable {
        let expression: String
        let result: String
        let copyValue: String
    }

    func register(in hop: PluginRegistry) {
        hop.add(search: self)
    }

    func search(_ query: String) -> [Item] {
        guard let (answer, kind) = calculate(query) else { return [] }
        var answerItem = item(for: answer, badge: kind,
                              icon: kind == "Currency" ? tile("dollarsign", .systemGreen) : tile("equal", .systemOrange))
        answerItem.section = kind
        let previous = history.filter { $0.expression != answer.expression }.prefix(7)
            .map { item(for: $0, badge: "", icon: tile("clock.arrow.circlepath", .systemGray)) }
        return [answerItem] + previous
    }

    private func calculate(_ query: String) -> (Calculation, kind: String)? {
        Rates.shared.refreshIfStale()
        if let money = Currency.convert(query, rates: Rates.shared.table) {
            return (Calculation(expression: "\(Calculator.format(money.amount)) \(money.from) in \(money.to)",
                                result: Currency.format(money.value, code: money.to),
                                copyValue: String(format: "%.2f", money.value)), "Currency")
        }
        guard let value = Calculator.evaluate(query) else { return nil }
        return (Calculation(expression: query, result: Calculator.format(value),
                            copyValue: Calculator.format(value, grouping: false)), "Calculator")
    }

    private func item(for calculation: Calculation, badge: String, icon: NSImage) -> Item {
        Item(title: calculation.result, subtitle: calculation.expression, badge: badge, action: "Copy Answer",
             preview: .answer(question: calculation.expression, answer: calculation.result),
             icon: { icon }) { [self] in
            remember(calculation)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(calculation.copyValue, forType: .string)
        }
    }

    private func remember(_ calculation: Calculation) {
        history.removeAll { $0 == calculation }
        history = Array(([calculation] + history).prefix(50))
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "calculations")
    }
}
