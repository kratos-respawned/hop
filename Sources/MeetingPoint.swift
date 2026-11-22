import Foundation

/// The launchd job that tells suite apps where to find each other. It never sees a login, so the apps don't need to trust it.
enum MeetingPoint {
    static func run() -> Never {
        guard let rule = Suite.rule(for: []) else { exit(0) }
        var addresses: [String: (line: xpc_connection_t, address: xpc_object_t)] = [:]
        var waiting: [String: [xpc_connection_t]] = [:]
        func answer(_ line: xpc_connection_t, _ address: xpc_object_t) {
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(message, "address", address)
            xpc_connection_send_message(line, message)
        }
        let listener = xpc_connection_create_mach_service(Suite.service, .main, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        guard xpc_connection_set_peer_code_signing_requirement(listener, rule) == 0 else { exit(1) }
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            xpc_connection_set_target_queue(peer, .main)
            xpc_connection_set_event_handler(peer) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
                    addresses = addresses.filter { $0.value.line !== peer }
                    waiting = waiting.mapValues { $0.filter { $0 !== peer } }
                    return xpc_connection_cancel(peer)
                }
                guard let from = Suite.sender(of: message) else { return }
                if let address = xpc_dictionary_get_value(message, "address"), xpc_get_type(address) == XPC_TYPE_ENDPOINT {
                    addresses[from] = (peer, address)
                    for asker in waiting.removeValue(forKey: from) ?? [] { answer(asker, address) }
                } else if let app = xpc_dictionary_get_string(message, "find").map({ String(cString: $0) }) {
                    if let known = addresses[app] { answer(peer, known.address) } else { waiting[app, default: []].append(peer) }
                }
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)
        dispatchMain()
    }
}
