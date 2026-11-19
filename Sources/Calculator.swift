import Foundation

enum Calculator {
    static func evaluate(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(["="]))
        guard let tokens = tokenize(text), tokens.contains(where: { if case .number = $0 { false } else { true } }) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.pos == tokens.count, value.plain.isFinite else { return nil }
        return value.plain
    }

    static func format(_ number: Double, grouping: Bool = true) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 10
        formatter.usesGroupingSeparator = grouping
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    private enum Token: Equatable {
        case number(Double), op(Character), word(String)
    }

    private static let operators: [Character: Character] = ["+": "+", "-": "-", "−": "-", "*": "*", "×": "*", "/": "/",
                                                             "÷": "/", "^": "^", "%": "%", "(": "(", ")": ")"]

    private static func tokenize(_ text: String) -> [Token]? {
        var tokens: [Token] = [], i = text.startIndex
        func scan(while matches: (Character) -> Bool) -> Substring {
            let start = i
            while i < text.endIndex && matches(text[i]) { i = text.index(after: i) }
            return text[start..<i]
        }
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace {
                i = text.index(after: i)
            } else if c.isNumber || c == "." {
                guard let n = Double(scan { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: "")) else { return nil }
                tokens.append(.number(n))
            } else if c.isLetter {
                switch scan(while: \.isLetter).lowercased() {
                case "x": tokens.append(.op("*"))
                case let word where word == "of" || word == "off": tokens.append(.word(word))
                default: return nil
                }
            } else if let op = operators[c] {
                tokens.append(.op(op))
                i = text.index(after: i)
            } else {
                return nil
            }
        }
        return tokens
    }

    private struct Value {
        var number: Double
        var isPercent = false
        var plain: Double { isPercent ? number / 100 : number }
    }

    // Percent rules follow Raycast: "150 + 10%" = 165, "20% of 150" = 30, "20% off 150" = 120.
    private struct Parser {
        let tokens: [Token]
        var pos = 0

        private mutating func take(_ token: Token) -> Bool {
            guard pos < tokens.count && tokens[pos] == token else { return false }
            pos += 1
            return true
        }

        mutating func expression() -> Value? {
            guard var left = term() else { return nil }
            while true {
                let sign: Double
                if take(.op("+")) { sign = 1 } else if take(.op("-")) { sign = -1 } else { return left }
                guard let right = term() else { return nil }
                let amount = right.isPercent ? left.plain * right.plain : right.plain
                left = Value(number: left.plain + sign * amount)
            }
        }

        private mutating func term() -> Value? {
            guard var left = unary() else { return nil }
            while true {
                if take(.op("*")) || take(.word("of")) {
                    guard let right = unary() else { return nil }
                    left = Value(number: left.plain * right.plain)
                } else if take(.op("/")) {
                    guard let right = unary(), right.plain != 0 else { return nil }
                    left = Value(number: left.plain / right.plain)
                } else if take(.word("off")) {
                    guard let right = unary() else { return nil }
                    left = Value(number: right.plain - right.plain * left.plain)
                } else {
                    return left
                }
            }
        }

        private mutating func unary() -> Value? {
            if take(.op("-")) { return unary().map { Value(number: -$0.number, isPercent: $0.isPercent) } }
            if take(.op("+")) { return unary() }
            guard var base = primary() else { return nil }
            if take(.op("%")) { base.isPercent = true }
            if take(.op("^")) {
                guard let exponent = unary() else { return nil }
                return Value(number: pow(base.plain, exponent.plain))
            }
            return base
        }

        private mutating func primary() -> Value? {
            if pos < tokens.count, case .number(let n) = tokens[pos] {
                pos += 1
                return Value(number: n)
            }
            guard take(.op("(")), let inner = expression(), take(.op(")")) else { return nil }
            return inner
        }
    }
}

enum Currency {
    private static let symbols: [String: String] = ["$": "USD", "€": "EUR", "£": "GBP", "₹": "INR", "¥": "JPY"]
    private static let pattern = try! Regex(#"^\s*([$€£₹¥]?)\s*([0-9.,+\-*/x×() %]+?)\s*([a-zA-Z]{3}|[$€£₹¥])?\s+(?:to|in|=)\s+([a-zA-Z]{3}|[$€£₹¥])\s*$"#)

    static func convert(_ text: String, rates: [String: Double]) -> (amount: Double, from: String, value: Double, to: String)? {
        guard let match = try? pattern.wholeMatch(in: text) else { return nil }
        let part = { (index: Int) in String(match.output[index].substring ?? "") }
        guard let amount = Double(part(2).replacingOccurrences(of: ",", with: "")) ?? Calculator.evaluate(part(2)) else { return nil }
        let from = code(part(1).isEmpty ? part(3) : part(1)), to = code(part(4))
        guard let fromRate = rates[from], let toRate = rates[to] else { return nil }
        return (amount, from, amount / fromRate * toRate, to)
    }

    private static func code(_ text: String) -> String { symbols[text] ?? text.uppercased() }

    static func format(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
    }
}

final class Rates {
    static let shared = Rates()
    private(set) var table: [String: Double] = [:]
    private var nextFetch = Date.distantPast
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hop/rates.json")

    private struct Saved: Codable {
        let date: Date
        let rates: [String: Double]
    }

    private init() {
        if let saved = try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: file)) {
            table = saved.rates
            nextFetch = saved.date.addingTimeInterval(6 * 3600)
        }
    }

    func refreshIfStale() {
        guard Date() > nextFetch else { return }
        nextFetch = Date().addingTimeInterval(60)
        URLSession.shared.dataTask(with: URL(string: "https://open.er-api.com/v6/latest/USD")!) { data, _, _ in
            struct Response: Decodable { let rates: [String: Double] }
            guard let data, let rates = try? JSONDecoder().decode(Response.self, from: data).rates else { return }
            DispatchQueue.main.async {
                self.table = rates
                self.nextFetch = Date().addingTimeInterval(6 * 3600)
                try? JSONEncoder().encode(Saved(date: Date(), rates: rates)).write(to: self.file, options: .atomic)
            }
        }.resume()
    }
}
