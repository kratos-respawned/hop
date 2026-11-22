import Foundation
import Network

enum ShareMode: String {
    case receive, share, both
    var canList: Bool { self != .receive }
    var canUpload: Bool { self != .share }
}

struct Transfer {
    enum State { case running, finished, failed }
    let id = UUID()
    var file: URL
    let incoming: Bool
    let device: String
    let total: Int
    var done = 0
    var state = State.running
    let startedAt = Date()
    fileprivate var reportedAt = Date.distantPast
}

final class ShareServer {
    let mode: ShareMode
    let root: URL
    let code = String((0..<8).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
    private(set) var port: UInt16 = 0
    private(set) var secure: SecureLink?
    var onReady: () -> Void = {}
    var onTransfer: (Transfer) -> Void = { _ in }
    var onStop: (String) -> Void = { _ in }
    private let queue = DispatchQueue(label: "hop.share")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var deadlines: [ObjectIdentifier: Date] = [:]
    private var pendingUploads: [UUID: Int] = [:]
    private var lastActivity = Date()
    private var idleCheck: DispatchSourceTimer?
    private static let idleLimit: TimeInterval = 15 * 60
    private static let connectionLimit = 32
    private static let preferredPort: NWEndpoint.Port = 4747

    private struct Request {
        var method = ""
        var parts: [String] = []
        var endsWithSlash = false
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
        var device = ""

        init(_ head: String) {
            let lines = head.components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            guard first.count >= 2, let target = URLComponents(string: String(first[1])) else { return }
            method = String(first[0])
            parts = target.path.split(separator: "/").map(String.init)
            endsWithSlash = target.path.hasSuffix("/")
            query = Dictionary((target.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { $1 }
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private struct Upload {
        let handle: FileHandle
        let partial: URL
        let folder: URL
        let name: String
        var transfer: Transfer
    }

    init(mode: ShareMode, root: URL) {
        self.mode = mode
        self.root = root.resolvingSymlinksInPath()
    }

    func start(secure: SecureLink?) {
        self.secure = secure
        queue.async { [self] in
            removeLeftoverUploads()
            listen(on: Self.preferredPort)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 60, repeating: 60)
            timer.setEventHandler { [weak self] in
                guard let self, Date().timeIntervalSince(lastActivity) > Self.idleLimit else { return }
                end("Sharing stopped after 15 minutes without activity")
            }
            timer.resume()
            idleCheck = timer
        }
    }

    func stop() {
        queue.async { [self] in end(nil) }
    }

    private func end(_ reason: String?) {
        listener?.cancel()
        listener = nil
        idleCheck?.cancel()
        idleCheck = nil
        connections.values.forEach { $0.cancel() }
        connections = [:]
        if let reason { DispatchQueue.main.async { [self] in onStop(reason) } }
    }

    private func removeLeftoverUploads() {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for file in files where file.lastPathComponent.wholeMatch(of: #/\..+\.hop-[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}/#) != nil
            && (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func listen(on port: NWEndpoint.Port) {
        let parameters = secure?.parameters ?? .tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: port) else {
            return port == Self.preferredPort ? listen(on: .any) : end("Couldn't open a port for sharing")
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue ?? 0
                DispatchQueue.main.async { self.onReady() }
            case .failed:
                listener.cancel()
                if port == Self.preferredPort { listen(on: .any) } else { end("Couldn't open a port for sharing") }
            default: break
            }
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint, Self.isOnLocalNetwork(host), connections.count < Self.connectionLimit
        else { return connection.cancel() }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        deadlines[key] = Date() + 10
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed: connection?.cancel()
            case .cancelled:
                self?.connections[key] = nil
                self?.deadlines[key] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        dropWhenStalled(connection)
        readHead(of: connection, from: "\(host)", Data())
    }

    private func dropWhenStalled(_ connection: NWConnection) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, connections[ObjectIdentifier(connection)] != nil else { return }
            if let deadline = deadlines[ObjectIdentifier(connection)], deadline < Date() { return connection.cancel() }
            dropWhenStalled(connection)
        }
    }

    private func readHead(of connection: NWConnection, from address: String, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            let received = received + (data ?? Data())
            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                deadlines[ObjectIdentifier(connection)] = nil
                var request = Request(String(decoding: received[..<end.lowerBound], as: UTF8.self))
                request.device = Self.device(request.headers["user-agent"] ?? "") + " · " + address
                respond(to: request, body: received[end.upperBound...], on: connection)
            } else if error == nil, !isComplete, received.count < 32768 {
                readHead(of: connection, from: address, received)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to request: Request, body: Data, on connection: NWConnection) {
        guard request.parts.first == code else { return reply(connection, 404, "Not found") }
        lastActivity = Date()
        switch (request.method, request.parts.dropFirst().first ?? "") {
        case ("GET", ""):
            guard request.endsWithSlash else { return reply(connection, 301, "", headers: ["Location: /\(code)/"]) }
            reply(connection, 200, page, type: "text/html; charset=utf-8")
        case ("GET", "list") where mode.canList: list(request.query["path"] ?? "", on: connection)
        case ("GET", "file") where mode.canList: download(request.query["path"] ?? "", for: request, on: connection)
        case ("POST", "upload") where mode.canUpload: upload(request, body: body, on: connection)
        default: reply(connection, 404, "Not found")
        }
    }

    private lazy var page: Data = {
        let settings = ["mode": mode.rawValue, "name": mode == .receive ? "Hop" : root.lastPathComponent]
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: settings)) ?? Data("{}".utf8), as: UTF8.self)
        return Data(shareWebPage.replacingOccurrences(of: "__HOP__", with: json.replacingOccurrences(of: "<", with: "\\u003c")).utf8)
    }()

    private func list(_ path: String, on connection: NWConnection) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let folder = resolve(path),
              let found = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else { return reply(connection, 404, "Not found") }
        let entries: [[String: Any]] = found.compactMap { url in
            guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"), let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return ["name": url.lastPathComponent, "folder": values.isDirectory ?? false, "size": values.fileSize ?? 0,
                    "modified": values.contentModificationDate?.timeIntervalSince1970 ?? 0]
        }
        reply(connection, 200, json(["entries": entries]), type: "application/json")
    }

    private func download(_ path: String, for request: Request, on connection: NWConnection) {
        guard let file = resolve(path), let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, let handle = try? FileHandle(forReadingFrom: file)
        else { return reply(connection, 404, "Not found") }
        let name = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
        connection.send(content: head(200, type: "application/octet-stream", length: size, ["Content-Disposition: attachment; filename*=UTF-8''\(name)"]),
                        completion: .contentProcessed { _ in })
        var transfer = Transfer(file: file, incoming: false, device: request.device, total: size)
        report(&transfer)
        stream(handle, to: connection, transfer)
    }

    private func stream(_ handle: FileHandle, to connection: NWConnection, _ transfer: Transfer) {
        var transfer = transfer
        guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
            try? handle.close()
            transfer.state = transfer.done == transfer.total ? .finished : .failed
            report(&transfer)
            return connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
        connection.send(content: chunk, completion: .contentProcessed { [self] error in
            lastActivity = Date()
            guard error == nil else {
                try? handle.close()
                transfer.state = .failed
                report(&transfer)
                return connection.cancel()
            }
            transfer.done += chunk.count
            report(&transfer)
            stream(handle, to: connection, transfer)
        })
    }

    private func upload(_ request: Request, body: Data, on connection: NWConnection) {
        guard let length = Int(request.headers["content-length"] ?? ""), length >= 0 else { return reply(connection, 411, "Length required") }
        guard let folder = mode == .receive ? root : resolve(request.query["path"] ?? ""),
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { return reply(connection, 404, "Folder not found") }
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        guard Int64(length) < free - 1_000_000_000 - Int64(pendingUploads.values.reduce(0, +)) else { return reply(connection, 507, "Not enough space on this Mac") }
        let name = Self.cleanName(request.query["name"] ?? "")
        var partial = folder.appendingPathComponent(".\(name).hop-\(UUID().uuidString)")
        var quarantine = URLResourceValues()
        quarantine.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeWebDownload"]
        guard FileManager.default.createFile(atPath: partial.path, contents: nil), let handle = try? FileHandle(forWritingTo: partial)
        else { return reply(connection, 500, "Couldn't save the file") }
        try? partial.setResourceValues(quarantine)
        var transfer = Transfer(file: folder.appendingPathComponent(name), incoming: true, device: request.device, total: length)
        report(&transfer)
        save(body, Upload(handle: handle, partial: partial, folder: folder, name: name, transfer: transfer), from: connection)
    }

    private func save(_ data: Data, _ upload: Upload, from connection: NWConnection) {
        var upload = upload
        let wanted = data.prefix(upload.transfer.total - upload.transfer.done)
        do { try upload.handle.write(contentsOf: wanted) } catch { return fail(upload, connection, 500, "Couldn't save the file") }
        upload.transfer.done += wanted.count
        lastActivity = Date()
        pendingUploads[upload.transfer.id] = upload.transfer.total - upload.transfer.done
        deadlines[ObjectIdentifier(connection)] = Date() + 60
        guard upload.transfer.done < upload.transfer.total else { return finish(upload, connection) }
        report(&upload.transfer)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, _, _ in
            guard let data, !data.isEmpty else { return fail(upload, connection, 400, "The upload was cut off") }
            save(data, upload, from: connection)
        }
    }

    private func finish(_ upload: Upload, _ connection: NWConnection) {
        var upload = upload
        pendingUploads[upload.transfer.id] = nil
        try? upload.handle.close()
        let file = Self.unusedName(upload.name, in: upload.folder)
        do { try FileManager.default.moveItem(at: upload.partial, to: file) } catch { return fail(upload, connection, 500, "Couldn't save the file") }
        upload.transfer.file = file
        upload.transfer.state = .finished
        report(&upload.transfer)
        reply(connection, 200, json(["name": file.lastPathComponent]), type: "application/json")
    }

    private func fail(_ upload: Upload, _ connection: NWConnection, _ status: Int, _ message: String) {
        var upload = upload
        pendingUploads[upload.transfer.id] = nil
        try? upload.handle.close()
        try? FileManager.default.removeItem(at: upload.partial)
        upload.transfer.state = .failed
        report(&upload.transfer)
        reply(connection, status, message)
    }

    private func report(_ transfer: inout Transfer) {
        guard transfer.state != .running || Date().timeIntervalSince(transfer.reportedAt) > 0.25 else { return }
        transfer.reportedAt = Date()
        let copy = transfer
        DispatchQueue.main.async { [self] in onTransfer(copy) }
    }

    private func resolve(_ path: String) -> URL? {
        let names = path.split(separator: "/").map(String.init)
        guard !names.contains(where: { $0.hasPrefix(".") }) else { return nil }
        let url = names.reduce(root) { $0.appendingPathComponent($1) }.resolvingSymlinksInPath()
        return url.path == root.path || url.path.hasPrefix(root.path + "/") ? url : nil
    }

    private func reply(_ connection: NWConnection, _ status: Int, _ body: String, type: String = "text/plain; charset=utf-8", headers: [String] = []) {
        reply(connection, status, Data(body.utf8), type: type, headers: headers)
    }

    private func reply(_ connection: NWConnection, _ status: Int, _ body: Data, type: String, headers: [String] = []) {
        connection.send(content: head(status, type: type, length: body.count, headers) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func head(_ status: Int, type: String, length: Int, _ extra: [String] = []) -> Data {
        let lines = ["HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))", "Content-Type: \(type)", "Content-Length: \(length)",
                     "Connection: close", "Cache-Control: no-store", "Referrer-Policy: no-referrer", "X-Content-Type-Options: nosniff"] + extra
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func device(_ agent: String) -> String {
        [("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android"), ("Windows", "Windows PC"), ("Macintosh", "Mac"), ("Linux", "Linux")]
            .first { agent.contains($0.0) }?.1 ?? "A device"
    }

    private static func cleanName(_ name: String) -> String {
        let last = name.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? ""
        let cleaned = last.replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines).union(.controlCharacters))
        return cleaned.isEmpty ? "Upload" : String(cleaned.prefix(80))
    }

    private static func unusedName(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return url
    }

    private static func isOnLocalNetwork(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return isPrivate(address)
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return isPrivate(mapped) }
            let bytes = [UInt8](address.rawValue)
            return address == .loopback || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || bytes[0] & 0xfe == 0xfc
        default: return false
        }
    }

    private static func isPrivate(_ address: IPv4Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        return bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 172 && bytes[1] & 0xf0 == 16) || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 169 && bytes[1] == 254)
    }

    static var networkAddress: String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), entry.ifa_flags & UInt32(IFF_UP) != 0,
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254") { return ip }
        }
        return nil
    }
}
