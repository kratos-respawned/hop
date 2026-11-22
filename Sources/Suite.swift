import Foundation
import Security

/// A private line between the suite's apps, so a site login goes only to the real, running app it is meant for.
/// Masks and Hop keep identical copies of this file.
enum Suite {
    static let service = "dev.hop.launcher.suite"

    enum Request: Codable {
        case download(address: URL, login: String)
    }

    /// Built from this app's own team, so an ad hoc build has no rule and the line stays off.
    static func rule(for apps: [String]) -> String? {
        guard let team else { return nil }
        let names = apps.map { #"identifier "\#($0)""# }.joined(separator: " or ")
        return (apps.isEmpty ? "" : "(\(names)) and ") + #"anchor apple generic and certificate leaf[subject.OU] = "\#(team)" and !entitlement["com.apple.security.get-task-allow"]"#
    }

    private static let team: String? = {
        var me: SecCode?, disk: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &disk) == errSecSuccess, let disk,
              SecCodeCopySigningInformation(disk, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// The suite app that sent this message, or nil when it isn't one or isn't hardened, which the signing rule can't express.
    /// Call it only inside the handler of the message it checks: it reads the token of the line's latest message.
    static func sender(of message: xpc_object_t) -> String? {
        var code: SecCode?, disk: SecStaticCode?, rule: SecRequirement?, info: CFDictionary?
        guard let text = Suite.rule(for: []),
              SecCodeCreateWithXPCMessage(message, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &rule) == errSecSuccess,
              SecCodeCheckValidity(code, [], rule) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &disk) == errSecSuccess, let disk,
              SecCodeCopySigningInformation(disk, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let facts = info as? [String: Any],
              let flags = facts[kSecCodeInfoFlags as String] as? UInt32, flags & SecCodeSignatureFlags.runtime.rawValue != 0
        else { return nil }
        return facts[kSecCodeInfoIdentifier as String] as? String
    }

    /// Takes requests from the given apps on a private line, whose address the meeting point hands only to suite apps.
    static func listen(to apps: [String], handle: @escaping (Request) -> Void) {
        guard let rule = rule(for: apps) else { return }
        let listener = xpc_connection_create(nil, .main)
        guard xpc_connection_set_peer_code_signing_requirement(listener, rule) == 0 else { return }
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            xpc_connection_set_target_queue(peer, .main)
            xpc_connection_set_event_handler(peer) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return xpc_connection_cancel(peer) }
                guard let from = sender(of: message), apps.contains(from) else { return }
                if let word = xpc_dictionary_get_string(message, "hello") {
                    let welcome = xpc_dictionary_create(nil, nil, 0)
                    xpc_dictionary_set_string(welcome, "welcome", word)
                    xpc_connection_send_message(peer, welcome)
                } else if let request = decoded(message) {
                    handle(request)
                    xpc_connection_cancel(peer)
                }
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)

        let meeting = xpc_connection_create_mach_service(service, .main, 0)
        func register() {
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(message, "address", xpc_endpoint_create(listener))
            xpc_connection_send_message(meeting, message)
        }
        // Interrupted means the meeting point restarted and forgot this address.
        xpc_connection_set_event_handler(meeting) { event in if event === XPC_ERROR_CONNECTION_INTERRUPTED { register() } }
        xpc_connection_activate(meeting)
        register()
    }

    /// Sends the request only after the app answered the hello with this line's word and passed the checks.
    /// `done` runs once on the main queue, false when nothing was sent.
    static func send(_ request: Request, to app: String, done: @escaping (Bool) -> Void) {
        guard let rule = rule(for: [app]), let body = try? JSONEncoder().encode(request) else { return done(false) }
        let word = UUID().uuidString
        let meeting = xpc_connection_create_mach_service(service, .main, 0)
        var direct: xpc_connection_t?
        var finished = false
        func finish(_ sent: Bool) {
            guard !finished else { return }
            finished = true
            xpc_connection_cancel(meeting)
            if !sent, let direct { xpc_connection_cancel(direct) }
            done(sent)
        }
        xpc_connection_set_event_handler(meeting) { event in
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else { return finish(false) }
            guard direct == nil, let address = xpc_dictionary_get_value(event, "address"), xpc_get_type(address) == XPC_TYPE_ENDPOINT else { return }
            let line = xpc_connection_create_from_endpoint(address)
            direct = line
            xpc_connection_set_target_queue(line, .main)
            guard xpc_connection_set_peer_code_signing_requirement(line, rule) == 0 else { return finish(false) }
            xpc_connection_set_event_handler(line) { reply in
                guard !finished else { return }
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY, sender(of: reply) == app,
                      xpc_dictionary_get_string(reply, "welcome").map({ String(cString: $0) }) == word
                else { return finish(false) }
                let message = xpc_dictionary_create(nil, nil, 0)
                body.withUnsafeBytes { xpc_dictionary_set_data(message, "request", $0.baseAddress!, body.count) }
                xpc_connection_send_message(line, message)
                xpc_connection_send_barrier(line) { xpc_connection_cancel(line) }
                finish(true)
            }
            xpc_connection_activate(line)
            let hello = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(hello, "hello", word)
            xpc_connection_send_message(line, hello)
        }
        xpc_connection_activate(meeting)
        let find = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(find, "find", app)
        xpc_connection_send_message(meeting, find)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(false) }
    }

    private static func decoded(_ message: xpc_object_t) -> Request? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, "request", &length) else { return nil }
        return try? JSONDecoder().decode(Request.self, from: Data(bytes: bytes, count: length))
    }
}
