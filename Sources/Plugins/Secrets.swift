import AppKit
import Security

enum RedditLogin {
    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Hop Reddit",
                                              kSecAttrAccount as String: "reddit_session"]
    private static let testingFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hop/reddit.json")

    static func load() -> String? {
        if let cookie = (try? Data(contentsOf: testingFile)).flatMap({ try? JSONDecoder().decode([String: String].self, from: $0) })?["reddit_session"] {
            if save(cookie) { try? FileManager.default.removeItem(at: testingFile) }
            return cookie
        }
        var found: CFTypeRef?
        let query = item.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ cookie: String) -> Bool {
        let value = [kSecValueData as String: Data(cookie.utf8)]
        let added = SecItemAdd(item.merging(value) { $1 }.merging([kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 } as CFDictionary, nil)
        return added == errSecSuccess || (added == errSecDuplicateItem && SecItemUpdate(item as CFDictionary, value as CFDictionary) == errSecSuccess)
    }
}

func takeFromClipboard(matching pattern: String) -> String? {
    let copied = NSPasteboard.general.string(forType: .string) ?? ""
    guard let found = copied.range(of: pattern, options: .regularExpression) else { return nil }
    NSPasteboard.general.clearContents()
    NotificationCenter.default.post(name: .forgetClip, object: copied)
    return String(copied[found])
}
