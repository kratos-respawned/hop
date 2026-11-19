import AppKit
import CoreServices

final class DictionaryPlugin: Plugin, SearchProvider {
    private struct Entry {
        let headword: String
        let firstSense: String
        let partOfSpeech: String
        let page: NSAttributedString
    }

    private var entries: [String: Entry?] = [:]
    private var wanted = ""
    private let lookups = DispatchQueue(label: "dictionary", qos: .userInitiated)
    private static let partsOfSpeech = "noun|verb|adjective|adverb|preposition|conjunction|pronoun|exclamation|abbreviation|determiner|prefix|suffix"

    func register(in hop: PluginRegistry) {
        hop.add(search: self)
        lookups.async { _ = Self.definition(of: "hop") }
    }

    func search(_ query: String) -> [Item] {
        let lowered = query.lowercased()
        guard let prefix = ["define ", "def "].first(where: lowered.hasPrefix) else { return [] }
        let word = lowered.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return [] }
        guard let cached = entries[word] else {
            lookUp(word)
            return [Item(title: "Looking up \(word)…", icon: { tile("character.book.closed", .systemBrown) })]
        }
        guard let entry = cached else {
            return [Item(title: "No entry for \(word)", subtitle: "Search in Dictionary", action: "Open",
                         icon: { tile("character.book.closed", .systemGray) }, run: { Self.openInDictionary(word) })]
        }
        return [Item(title: entry.headword, subtitle: entry.firstSense, badge: entry.partOfSpeech, action: "Open in Dictionary",
                     preview: .rich(entry.page), icon: { tile("character.book.closed", .systemBrown) },
                     run: { Self.openInDictionary(entry.headword) })]
    }

    private func lookUp(_ word: String) {
        wanted = word
        lookups.async { [self] in
            guard DispatchQueue.main.sync(execute: { wanted == word }) else { return }
            let entry = Self.definition(of: word).map { Self.entry(from: $0, word: word) }
            DispatchQueue.main.async { [self] in
                entries[word] = .some(entry)
                NotificationCenter.default.post(name: .pageChanged, object: nil)
            }
        }
    }

    private static func definition(of word: String) -> String? {
        DCSCopyTextDefinition(nil, word as CFString, CFRange(location: 0, length: word.utf16.count))?.takeRetainedValue() as String?
    }

    private static func openInDictionary(_ word: String) {
        guard let url = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap({ URL(string: "dict://\($0)") }) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func entry(from text: String, word: String) -> Entry {
        let parts = text.components(separatedBy: " | ")
        let lead = parts.first ?? text
        let headword = word.contains(" ") && lead.lowercased().hasPrefix(word) ? word : lead.components(separatedBy: " ").first ?? text
        let pronunciation = parts.count > 2 ? parts[1] : ""
        let body = parts.count > 2 ? parts.dropFirst(2).joined(separator: " | ") : text
        let partOfSpeech = body.range(of: "^(\(partsOfSpeech))\\b", options: .regularExpression).map { String(body[$0]) } ?? ""
        let firstSense = body.replacingOccurrences(of: #"^\S+\s+(\([^)]*\)\s*)*(\d+\s+)?(\[[^\]]*\]\s*)*"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ":.•")).first?.trimmingCharacters(in: .whitespaces) ?? ""
        return Entry(headword: headword, firstSense: firstSense, partOfSpeech: partOfSpeech,
                     page: page(headword: headword, pronunciation: pronunciation, body: body))
    }

    private static func page(headword: String, pronunciation: String, body: String) -> NSAttributedString {
        let laidOut = body
            .replacingOccurrences(of: #"\| ([^|\s]+(?:, [^|\s]+)*) \|"#, with: "/$1/", options: .regularExpression)
            .replacingOccurrences(of: " | ", with: "  ·  ")
            .replacingOccurrences(of: "(, ", with: "(")
            .replacingOccurrences(of: "(/ (?:\(partsOfSpeech))) (?=\\S+ /)", with: "$1\n", options: .regularExpression)
            .replacingOccurrences(of: #" (PHRASES|PHRASAL VERBS|DERIVATIVES|ORIGIN|USAGE) "#, with: "\n\n$1\n", options: .regularExpression)
            .replacingOccurrences(of: "(?<=[.:)] )(\(partsOfSpeech)) ", with: "\n\n$1\n", options: .regularExpression)
            .replacingOccurrences(of: #"^(\#(partsOfSpeech))\b ?"#, with: "$1\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[.:)\]]) (\d{1,2}) (?=[\[(a-z])"#, with: "\n$1  ", options: .regularExpression)
            .replacingOccurrences(of: " • ", with: "\n      • ")
        let spaced = NSMutableParagraphStyle()
        spaced.lineSpacing = 2
        spaced.paragraphSpacing = 4
        let page = NSMutableAttributedString()
        page.append(NSAttributedString(string: headword + "\n", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.labelColor]))
        if !pronunciation.isEmpty {
            page.append(NSAttributedString(string: pronunciation + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        page.append(NSAttributedString(string: laidOut, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: spaced]))
        let text = page.string
        func style(_ pattern: String, _ attributes: [NSAttributedString.Key: Any]) {
            for match in try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines).matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                page.addAttributes(attributes, range: match.range(at: 1))
            }
        }
        style("^(\(partsOfSpeech))$", [.font: NSFont.systemFont(ofSize: 13, weight: .semibold).withItalics, .foregroundColor: NSColor.systemBrown])
        style("^(PHRASES|PHRASAL VERBS|DERIVATIVES|ORIGIN|USAGE)$", [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        style(#"^(\d{1,2})  "#, [.font: NSFont.systemFont(ofSize: 13, weight: .bold)])
        style(#"(\[[^\]\n]*\])"#, [.foregroundColor: NSColor.secondaryLabelColor])
        style(#":( [^\n•]*)"#, [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13).withItalics])
        return page
    }
}

private extension NSFont {
    var withItalics: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask) }
}
