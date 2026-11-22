import CryptoKit
import Foundation

// The login keychain hands this key to Hop's own signature and asks the user before giving it to any other program.
enum Sealed {
    private static let key: SymmetricKey? = {
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "Hop clipboard", kSecAttrAccount: "key"]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(item.merging([kSecReturnData: true]) { $1 } as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { return nil }
        let fresh = SymmetricKey(size: .bits256)
        let saved = SecItemAdd(item.merging([kSecValueData: fresh.withUnsafeBytes { Data($0) }]) { $1 } as CFDictionary, nil)
        return saved == errSecSuccess ? fresh : nil
    }()

    static var isReady: Bool { key != nil }

    static func read(_ url: URL) -> Data? {
        guard let key, let file = try? Data(contentsOf: url), let box = try? AES.GCM.SealedBox(combined: file) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    static func write(_ data: Data, to url: URL) {
        guard let key, let box = try? AES.GCM.seal(data, using: key).combined else { return }
        try? box.write(to: url, options: .atomic)
    }
}
