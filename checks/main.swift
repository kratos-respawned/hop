let names = ["Visual Studio Code", "Safari", "System Settings", "Slack", "Google Chrome",
             "Calculator", "Calendar", "WebStorm", "Activity Monitor", "Screenshot"]

func best(_ query: String) -> String? {
    names.compactMap { name in fuzzyScore(query, name).map { (name, $0) } }.max { $0.1 < $1.1 }?.0
}

let expected = ["saf": "Safari", "vsc": "Visual Studio Code", "code": "Visual Studio Code",
                "chr": "Google Chrome", "ws": "WebStorm", "am": "Activity Monitor",
                "cal": "Calendar", "calc": "Calculator", "sset": "System Settings", "monitor": "Activity Monitor"]
for (query, name) in expected {
    precondition(best(query) == name, "\(query) -> \(best(query) ?? "nil"), expected \(name)")
}
precondition(fuzzyScore("xyz", "Safari") == nil)
print("fuzzy ok")

func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }
let math: [String: Double] = ["2+2": 4, "2 + 3 * 4": 14, "(2+3)*4": 20, "-2^2": -4, "2^3^2": 512, "10/4": 2.5,
                              "150 + 10%": 165, "150 - 10%": 135, "20% of 150": 30, "20% off 150": 120,
                              "50 * 10%": 5, "1,000 x 3": 3000, "10%": 0.1, "-(3 - 5)": 2, "90+2=": 92, "=5*2": 10]
for (query, answer) in math {
    precondition(near(Calculator.evaluate(query), answer), "\(query) -> \(String(describing: Calculator.evaluate(query)))")
}
for query in ["safari", "1password", "42", "5/0", "2 +", "x", "=", "42="] {
    precondition(Calculator.evaluate(query) == nil, "\(query) should not be math")
}

let rates = ["USD": 1.0, "INR": 80, "EUR": 0.5]
let money: [String: Double] = ["100 usd to inr": 8000, "$50 in eur": 25, "10 EUR to usd": 20, "2*50 usd to ₹": 8000, "1,000 inr in usd": 12.5]
for (query, answer) in money {
    precondition(near(Currency.convert(query, rates: rates)?.value, answer), "\(query) -> \(String(describing: Currency.convert(query, rates: rates)))")
}
precondition(Currency.convert("100 usd to xyz", rates: rates) == nil)
precondition(Currency.convert("open in xcode", rates: rates) == nil)
print("calculator ok")
