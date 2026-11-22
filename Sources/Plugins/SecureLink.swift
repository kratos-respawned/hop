import Foundation
import Network

struct SecureLink {
    let host: String
    let identity: sec_identity_t

    private struct Settings: Decodable { let name: String }
    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hop/share")

    var parameters: NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        return NWParameters(tls: tls)
    }

    static func prepare(for address: String, then done: @escaping (SecureLink?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let link = make(for: address)
            DispatchQueue.main.async { done(link) }
        }
    }

    private static let network = NWPathMonitor()
    private static var settings: Settings? {
        (try? Data(contentsOf: folder.appendingPathComponent("secure.json"))).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
    }
    private static func isPublished(_ address: String) -> Bool { UserDefaults.standard.string(forKey: "sharedAddress") == address }

    // The name servers take about two minutes to pick up a new address, so it is sent when the network changes, not when sharing starts.
    static func followNetwork() {
        network.pathUpdateHandler = { _ in
            guard let address = ShareServer.networkAddress, !isPublished(address), let settings else { return }
            _ = publish(address, settings)
        }
        network.start(queue: .global(qos: .utility))
    }

    private static func make(for address: String) -> SecureLink? {
        guard let settings, let certificate = try? Data(contentsOf: folder.appendingPathComponent("certificate.p12")),
              let identity = identity(from: certificate, validFor: "share." + settings.name) else { return nil }
        let alreadyPublished = isPublished(address)
        guard alreadyPublished || publish(address, settings) else { return nil }
        // A fresh name each try, because a router that answered with the old address keeps that answer for a minute.
        for attempt in 0..<(alreadyPublished ? 1 : 4) {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            let host = String((0..<12).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! }) + "." + settings.name
            if resolves(host, to: address) { return SecureLink(host: host, identity: identity) }
        }
        return nil
    }

    private static func identity(from certificate: Data, validFor host: String) -> sec_identity_t? {
        var imported: CFArray?
        let options = [kSecImportExportPassphrase: "changeit", kSecImportToMemoryOnly: true] as CFDictionary
        guard SecPKCS12Import(certificate as CFData, options, &imported) == errSecSuccess,
              let item = (imported as? [[String: Any]])?.first,
              let chain = item[kSecImportItemCertChain as String] as? [SecCertificate],
              let identity = item[kSecImportItemIdentity as String] else { return nil }
        var trust: SecTrust?
        SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
        guard let trust, SecTrustEvaluateWithError(trust, nil) else { return nil }
        return sec_identity_create_with_certificates(identity as! SecIdentity, Array(chain.dropFirst()) as CFArray)
    }

    private static func publish(_ address: String, _ settings: Settings) -> Bool {
        guard let token, let url = URL(string: "https://desec.io/api/v1/domains/\(settings.name)/rrsets/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "PATCH"
        request.setValue("Token " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [["subname": "*", "type": "A", "ttl": 3600, "records": [address]]])
        let finished = DispatchSemaphore(value: 0)
        var saved = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            saved = (response as? HTTPURLResponse)?.statusCode == 200
            finished.signal()
        }.resume()
        finished.wait()
        if saved { UserDefaults.standard.set(address, forKey: "sharedAddress") }
        return saved
    }

    private static var token: String? {
        let security = Process(), output = Pipe()
        security.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        security.arguments = ["find-generic-password", "-s", "hop-dns", "-w"]
        security.standardOutput = output
        security.standardError = FileHandle.nullDevice
        guard (try? security.run()) != nil else { return nil }
        let token = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func resolves(_ host: String, to address: String) -> Bool {
        let answered = DispatchSemaphore(value: 0)
        var matches = false
        DispatchQueue.global().async {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, nil, &hints, &list) == 0, let first = list {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
                matches = String(cString: name) == address
                freeaddrinfo(list)
            }
            answered.signal()
        }
        return answered.wait(timeout: .now() + 2) == .success && matches
    }
}
