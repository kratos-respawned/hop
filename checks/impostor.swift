import Foundation

/// Tries to get past the suite line's checks. Build with `swiftc checks/impostor.swift -o build/impostor`, then sign it the ways the plan lists.
/// `impostor send <url>` asks for Hop and sends a request without waiting for a welcome.
/// `impostor meet` plays the meeting point and Hop, when launchd runs it under the suite's service name.
let service = "dev.hop.launcher.suite"
let arguments = CommandLine.arguments.dropFirst()
/// Connections made inside a switch case would be released when the case ends.
var kept: [xpc_connection_t] = []

func dictionary(_ values: [String: String]) -> xpc_object_t {
    let message = xpc_dictionary_create(nil, nil, 0)
    for (key, value) in values { xpc_dictionary_set_string(message, key, value) }
    return message
}

switch arguments.first {
case "send":
    let address = arguments.dropFirst().first ?? "https://example.com/"
    let request = Data(##"{"download":{"address":"\##(address)","login":"# Netscape HTTP Cookie File\n"}}"##.utf8)
    let meeting = xpc_connection_create_mach_service(service, .main, 0)
    var lines: [xpc_connection_t] = []
    xpc_connection_set_event_handler(meeting) { event in
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY, let found = xpc_dictionary_get_value(event, "address") else {
            return print("meeting point:", event)
        }
        print("got Hop's address")
        let line = xpc_connection_create_from_endpoint(found)
        lines.append(line)
        xpc_connection_set_target_queue(line, .main)
        xpc_connection_set_event_handler(line) { print("from Hop:", $0) }
        xpc_connection_activate(line)
        xpc_connection_send_message(line, dictionary(["hello": "impostor"]))
        let message = xpc_dictionary_create(nil, nil, 0)
        request.withUnsafeBytes { xpc_dictionary_set_data(message, "request", $0.baseAddress!, request.count) }
        xpc_connection_send_message(line, message)
        print("sent hello and request")
    }
    xpc_connection_activate(meeting)
    kept.append(meeting)
    xpc_connection_send_message(meeting, dictionary(["find": "dev.hop.launcher"]))
case "meet":
    let fake = xpc_connection_create(nil, .main)
    xpc_connection_set_event_handler(fake) { peer in
        guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
        xpc_connection_set_event_handler(peer) { message in
            if let word = xpc_dictionary_get_string(message, "hello") {
                print("hello", String(cString: word))
                xpc_connection_send_message(peer, dictionary(["welcome": String(cString: word)]))
            } else if xpc_dictionary_get_value(message, "request") != nil {
                print("REQUEST RECEIVED, the check failed")
            } else {
                print("other:", message)
            }
            fflush(stdout)
        }
        xpc_connection_activate(peer)
    }
    xpc_connection_activate(fake)
    let listener = xpc_connection_create_mach_service(service, .main, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
    xpc_connection_set_event_handler(listener) { peer in
        guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
        xpc_connection_set_event_handler(peer) { message in
            guard xpc_get_type(message) == XPC_TYPE_DICTIONARY, xpc_dictionary_get_string(message, "find") != nil else { return }
            let answer = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(answer, "address", xpc_endpoint_create(fake))
            xpc_connection_send_message(peer, answer)
            print("answered a find"); fflush(stdout)
        }
        xpc_connection_activate(peer)
    }
    xpc_connection_activate(listener)
    kept += [fake, listener]
default:
    print("usage: impostor send <url> | impostor meet")
    exit(1)
}
DispatchQueue.main.asyncAfter(deadline: .now() + (arguments.first == "send" ? 5 : 600)) { exit(0) }
dispatchMain()
