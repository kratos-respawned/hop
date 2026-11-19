import AppKit

struct App: Equatable {
    let name: String
    let path: String
}

final class AppsSource: Source {
    let name = "Applications"
    let icon = tile("square.grid.2x2.fill", .systemBlue)
    let placeholder = "Search apps"
    let actionName = "Open Application"
    private var apps: [App] = []
    private var scannedAt = Date.distantPast
    private var launches = UserDefaults.standard.dictionary(forKey: "launches") as? [String: Int] ?? [:]
    private var calculations = UserDefaults.standard.data(forKey: "calculations")
        .flatMap { try? JSONDecoder().decode([Calculation].self, from: $0) } ?? []

    private struct Calculation: Codable, Equatable {
        let expression: String
        let result: String
        let copyValue: String
    }

    func search(_ query: String) -> [Item] {
        if Date().timeIntervalSince(scannedAt) > 10 {
            apps = Self.scan()
            scannedAt = Date()
        }
        let ranked = apps
            .compactMap { app in fuzzyScore(query, app.name).map { (app, $0 + min(launches[app.path] ?? 0, 30) * 10) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
        let matches = ranked.prefix(50).map { item(for: $0.0) }
        guard let (answer, kind) = calculate(query) else { return matches }
        var answerItem = item(for: answer, badge: kind,
                              icon: kind == "Currency" ? tile("dollarsign", .systemGreen) : tile("equal", .systemOrange))
        answerItem.section = kind
        let previous = calculations.filter { $0.expression != answer.expression }.prefix(7)
            .map { item(for: $0, badge: "", icon: tile("clock.arrow.circlepath", .systemGray)) }
        return [answerItem] + previous + matches
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
             preview: .calculation(expression: calculation.expression, result: calculation.result),
             icon: { icon }) { [self] in
            calculations.removeAll { $0 == calculation }
            calculations = Array(([calculation] + calculations).prefix(50))
            UserDefaults.standard.set(try? JSONEncoder().encode(calculations), forKey: "calculations")
            Self.copy(calculation.copyValue)
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func item(for app: App) -> Item {
        let folder = (app.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return Item(title: app.name, subtitle: folder, badge: "Application",
                    icon: { NSWorkspace.shared.icon(forFile: app.path) }) { [self] in
            launches[app.path, default: 0] += 1
            UserDefaults.standard.set(launches, forKey: "launches")
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: .init())
        }
    }

    private static let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
                                NSHomeDirectory() + "/Applications"]

    static func scan() -> [App] {
        var seen = Set<String>(), apps = [App(name: "Finder", path: "/System/Library/CoreServices/Finder.app")]
        // Not FileManager.enumerator: it drops symlinked apps like /Applications/Safari.app.
        func visit(_ dir: String, depth: Int) {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where !entry.hasPrefix(".") {
                let path = dir + "/" + entry
                if entry.hasSuffix(".app") {
                    if seen.insert(String(entry.dropLast(4))).inserted { apps.append(App(name: String(entry.dropLast(4)), path: path)) }
                } else if depth < 1 {
                    visit(path, depth: depth + 1)
                }
            }
        }
        roots.forEach { visit($0, depth: 0) }
        return apps
    }
}
