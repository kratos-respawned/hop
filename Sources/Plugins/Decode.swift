import AppKit

final class DecodePlugin: Plugin, SearchProvider {
    private static let india = TimeZone(identifier: "Asia/Kolkata")!
    private static let indianTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = india
        formatter.dateFormat = "EEE, d MMM yyyy, h:mm:ss a 'IST'"
        return formatter
    }()
    private static let shortIndianTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = india
        formatter.dateFormat = "d MMM yyyy, h:mm a"
        return formatter
    }()
    private static let isoDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoDateWithoutFraction = ISO8601DateFormatter()
    private static let relative = RelativeDateTimeFormatter()
    private static let timeClaims: Set<String> = ["exp", "iat", "nbf", "auth_time"]

    func register(in hop: PluginRegistry) {
        hop.add(search: self)
        DispatchQueue.global(qos: .utility).async { [self] in _ = search("2026-01-01T00:00:00Z") }
    }

    func search(_ query: String) -> [Item] {
        let text = query.replacingOccurrences(of: #"^\s*(authorization:\s*)?(bearer\s+)?["'`]?|["'`,]?\s*$"#, with: "",
                                              options: [.regularExpression, .caseInsensitive])
        guard text.count >= 3, !text.contains(" ") else { return [] }
        if text.lowercased() == "now" { return [dateItem(Date(), kind: "Now", copiesEpoch: true)] }
        if let date = epochDate(text) { return [dateItem(date, kind: text.count >= 13 ? "Epoch ms" : "Epoch")] }
        if let date = Self.isoDate.date(from: text) ?? Self.isoDateWithoutFraction.date(from: text) { return [dateItem(date, kind: "ISO date")] }
        return jwtItem(text).map { [$0] } ?? base64Item(text).map { [$0] } ?? []
    }

    private func epochDate(_ text: String) -> Date? {
        guard text.allSatisfy(\.isNumber), let number = Double(text) else { return nil }
        let seconds: Double
        switch text.count {
        case 10: seconds = number
        case 13: seconds = number / 1_000
        case 16: seconds = number / 1_000_000
        default: return nil
        }
        let date = Date(timeIntervalSince1970: seconds)
        return (2001...2100).contains(Calendar.current.component(.year, from: date)) ? date : nil
    }

    private func dateItem(_ date: Date, kind: String, copiesEpoch: Bool = false) -> Item {
        let india = Self.indianTime.string(from: date)
        let seconds = Int(date.timeIntervalSince1970)
        let ago = Self.relative.localizedString(for: date, relativeTo: Date())
        let rows = [("IST", india), ("UTC", Self.isoDateWithoutFraction.string(from: date)), ("Epoch", "\(seconds)"),
                    ("Epoch ms", "\(seconds * 1000)"), ("Relative", ago)]
        let preview = rows.map { $0.0.padding(toLength: 11, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
        return copyItem(copiesEpoch ? "\(seconds)" : india, subtitle: copiesEpoch ? india : ago, badge: kind,
                        symbol: "calendar.badge.clock", preview: preview)
    }

    private func jwtItem(_ text: String) -> Item? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, text.hasPrefix("eyJ"),
              let header = json(String(parts[0])), let payload = json(String(parts[1])) else { return nil }
        let algorithm = header["alg"] as? String ?? "unsigned"
        let payloadJSON = pretty(payload)
        let withTimes = payloadJSON.split(separator: "\n").map { line in
            guard let key = Self.timeClaims.first(where: { line.hasPrefix("  \"\($0)\" :") }),
                  let seconds = (payload[key] as? NSNumber)?.doubleValue else { return String(line) }
            return "\(line)  // \(Self.shortIndianTime.string(from: Date(timeIntervalSince1970: seconds)))"
        }.joined(separator: "\n")
        guard let expiry = (payload["exp"] as? NSNumber).map({ Date(timeIntervalSince1970: $0.doubleValue) }) else {
            return copyItem("JWT payload", subtitle: "\(payload.count) claims, never expires", badge: algorithm,
                            symbol: "checkmark.seal", preview: withTimes, copies: payloadJSON)
        }
        let ago = Self.relative.localizedString(for: expiry, relativeTo: Date())
        let expired = expiry < Date()
        return copyItem(expired ? "JWT expired \(ago)" : "JWT expires \(ago)", subtitle: Self.indianTime.string(from: expiry), badge: algorithm,
                        symbol: expired ? "xmark.seal" : "checkmark.seal", preview: withTimes, copies: payloadJSON)
    }

    private func base64Item(_ text: String) -> Item? {
        guard text.count >= 12, let data = base64Data(text) else { return nil }
        let decoded = String(decoding: data, as: UTF8.self)
        let readable = decoded.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil || " \n\t.,:;-_/{}[]\"'=+@#!?()&%*<>|~$^`\\".unicodeScalars.contains($0) }
        guard !decoded.isEmpty, !decoded.contains("\u{FFFD}"), Double(readable.count) / Double(decoded.unicodeScalars.count) > 0.9 else { return nil }
        let object = try? JSONSerialization.jsonObject(with: data)
        return copyItem(object == nil ? "Base64 text" : "Base64 JSON", subtitle: "\(data.count) bytes decoded", badge: "Base64",
                        symbol: object == nil ? "text.quote" : "curlybraces", preview: object.map(pretty) ?? decoded, copies: decoded)
    }

    private func json(_ part: String) -> [String: Any]? {
        base64Data(part).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func base64Data(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard standard.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }) else { return nil }
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    private func pretty(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\(object)"
    }

    private func copyItem(_ title: String, subtitle: String, badge: String, symbol: String, preview: String, copies: String? = nil) -> Item {
        Item(title: title, subtitle: subtitle, badge: badge, action: "Copy", preview: .code(preview), icon: { tile(symbol, .systemMint) }) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copies ?? title, forType: .string)
        }
    }
}

func highlightedCode(_ text: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    let result = NSMutableAttributedString(string: text, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
    let whole = NSRange(location: 0, length: (text as NSString).length)
    for (pattern, color) in jsonColors {
        for match in pattern.matches(in: text, range: whole) { result.addAttribute(.foregroundColor, value: color, range: match.range(at: 1)) }
    }
    return result
}

private let jsonColors: [(NSRegularExpression, NSColor)] = [
    (try! NSRegularExpression(pattern: #"(?:: |\[)\s*(-?\d[\d.eE+-]*|true|false|null)\b"#), .systemOrange),
    (try! NSRegularExpression(pattern: #"^\s+(-?\d[\d.eE+-]*|true|false|null),?$"#, options: .anchorsMatchLines), .systemOrange),
    (try! NSRegularExpression(pattern: #"("(?:[^"\\\n]|\\.)*")"#), .systemGreen),
    (try! NSRegularExpression(pattern: #"("(?:[^"\\\n]|\\.)*")\s*:"#), .systemBlue),
    (try! NSRegularExpression(pattern: #"(  // .*)$"#, options: .anchorsMatchLines), .secondaryLabelColor),
    (try! NSRegularExpression(pattern: #"^(\S+(?: \S+)?)(?=\s{2,})"#, options: .anchorsMatchLines), .secondaryLabelColor),
]
