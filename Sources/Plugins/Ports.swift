import AppKit

struct Listener {
    let port: Int
    let pid: pid_t
    let starters: [pid_t]
    let command: String
    let folder: String?
    let appPath: String?
    let isDocker: Bool
    let isNode: Bool
    var container: String?
}

enum PortTable {
    private static let stopClimbingAt: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "login", "tmux", "screen", "claude"]

    static func listeners() -> [Listener] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 4096)
        var listeners: [Listener] = []
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            let ports = listeningPorts(of: pid, fds: &fds)
            guard !ports.isEmpty else { continue }
            let identity = ProcessTable.identify(pid)
            let bundleName = identity.appPath.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
            let isDocker = bundleName == "OrbStack" || bundleName == "Docker"
            let appPath = isApp(pid) ? identity.appPath : nil
            let folder = ProcessTable.workingFolder(pid)
            let starters = appPath == nil && !isDocker ? starters(of: pid, in: folder) : []
            let command = (isDocker || appPath != nil ? bundleName : nil) ?? commandLine(of: starters.last ?? pid, fallback: identity.name)
            let isNode = ProcessTable.executableName(pid) == "node"
            listeners += ports.sorted().map {
                Listener(port: $0, pid: pid, starters: starters, command: command, folder: folder, appPath: appPath,
                         isDocker: isDocker, isNode: isNode)
            }
        }
        return listeners
    }

    private static func listeningPorts(of pid: pid_t, fds: inout [proc_fdinfo]) -> Set<Int> {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        var ports: Set<Int> = []
        for fd in fds.prefix(max(Int(bytes), 0) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            ports.insert(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))))
        }
        return ports
    }

    // npm, npx and nodemon wrap the server and nodemon restarts it, so Stop has to reach them too.
    private static func starters(of pid: pid_t, in folder: String?) -> [pid_t] {
        var chain = [pid]
        while let folder, let parent = ProcessTable.parent(of: chain[chain.count - 1]), parent > 1, parent != getpid(),
              ProcessTable.workingFolder(parent) == folder {
            if isApp(parent) || stopClimbingAt.contains(ProcessTable.identify(parent).name) { break }
            chain.append(parent)
        }
        return chain
    }

    private static func isApp(_ pid: pid_t) -> Bool {
        (NSRunningApplication(processIdentifier: pid)?.activationPolicy ?? .prohibited) != .prohibited
    }

    private static func commandLine(of pid: pid_t, fallback: String) -> String {
        let words = ProcessTable.arguments(pid).filter { !$0.isEmpty }.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { return fallback }
        if ["sh", "bash", "zsh"].contains(program), words.count > 2, words[1] == "-c" { return words[2...].joined(separator: " ") }
        return ([program] + words.dropFirst()).joined(separator: " ")
    }

    static func stopContainer(_ name: String) {
        guard let docker = dockerPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["stop", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static var dockerPath: String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", NSHomeDirectory() + "/.orbstack/bin/docker"].first(where: FileManager.default.isExecutableFile)
    }

    static func containersByPort() -> [Int: String] {
        guard let docker = dockerPath else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["ps", "--format", "{{.Names}}\t{{.Ports}}"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var containers: [Int: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            for mapping in parts[1].components(separatedBy: ", ") where mapping.contains("->") {
                let hostSide = mapping.components(separatedBy: "->")[0]
                if let port = Int(hostSide.split(separator: ":").last ?? "") { containers[port] = String(parts[0]) }
            }
        }
        return containers
    }
}

final class PortPlugin: Plugin, Page {
    let name = "Port Manager"
    let icon = tile("network", .systemIndigo)
    let placeholder = "Search ports, folders and commands"
    let actionName = "Show Actions"
    private let nextSection = "Next servers"
    private let nodeSection = "Node servers"
    private let dockerSection = "Docker"
    private let deletedFolders = "Deleted folders"
    private var containers: [Int: String] = [:]
    private var containersCheckedAt = Date.distantPast
    private let otherSection = "Other"
    private let appsSection = "Apps"

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
    }

    func search(_ query: String) -> [Item] {
        checkContainers()
        let order = [nextSection, nodeSection, "", dockerSection, deletedFolders, otherSection, appsSection]
        return PortTable.listeners()
            .map { listener in
                var listener = listener
                listener.container = listener.isDocker ? containers[listener.port] : nil
                return (listener: listener, section: section(for: listener))
            }
            .sorted { (order.firstIndex(of: $0.section) ?? 2, $0.section, $0.listener.port) < (order.firstIndex(of: $1.section) ?? 2, $1.section, $1.listener.port) }
            .map { item(for: $0.listener, section: $0.section) }
            .filter { query.isEmpty || fuzzyScore(query, "\($0.title) \($0.subtitle)") != nil }
    }

    private func checkContainers() {
        guard Date().timeIntervalSince(containersCheckedAt) > 5 else { return }
        containersCheckedAt = Date()
        DispatchQueue.global().async {
            let found = PortTable.containersByPort()
            DispatchQueue.main.async { [self] in
                guard found != containers else { return }
                containers = found
                NotificationCenter.default.post(name: .pageChanged, object: self)
            }
        }
    }

    func refreshSoon() {
        for delay in [0.5, 2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                NotificationCenter.default.post(name: .pageChanged, object: self)
            }
        }
    }

    private func section(for listener: Listener) -> String {
        if listener.isNode { return listener.command.contains("next") ? nextSection : nodeSection }
        if listener.isDocker { return dockerSection }
        if listener.appPath != nil { return appsSection }
        guard let folder = listener.folder else { return otherSection }
        if folder.hasPrefix(WorkFolder.root + "/.hop-trash") || !FileManager.default.fileExists(atPath: folder) { return deletedFolders }
        guard folder.hasPrefix(WorkFolder.root + "/") else { return otherSection }
        return String(folder.dropFirst(WorkFolder.root.count + 1).split(separator: "/")[0])
    }

    private func item(for listener: Listener, section: String) -> Item {
        let isFolderGone = listener.folder.map { $0.hasPrefix(WorkFolder.root + "/.hop-trash") || !FileManager.default.fileExists(atPath: $0) } ?? false
        let place = listener.isDocker ? nil : listener.folder.map { isFolderGone ? "deleted folder" : shortPath($0) }
        let command = listener.isDocker ? listener.container ?? "\(listener.command), not a container" : listener.command
        let appIcon = listener.appPath.map { NSWorkspace.shared.icon(forFile: $0) }
        let color: NSColor = isFolderGone ? .systemRed : section == otherSection || section == appsSection ? .systemGray
            : section == nodeSection ? .systemGreen : .systemIndigo
        let symbol = listener.isDocker ? "shippingbox" : section == nextSection ? "globe" : "server.rack"
        return Item(title: "\(listener.port)", subtitle: ([command] + [place].compactMap { $0 }).joined(separator: " · "),
                    badge: "pid \(listener.pid)", section: section, opens: PortActions(listener: listener, manager: self),
                    icon: { appIcon ?? tile(symbol, color) })
    }
}

final class PortActions: Page {
    let name: String
    let icon = tile("network", .systemIndigo)
    let placeholder = "Search actions"
    let actionName = "Run"
    private let listener: Listener
    private unowned let manager: PortPlugin

    init(listener: Listener, manager: PortPlugin) {
        name = "Port \(listener.port)"
        self.listener = listener
        self.manager = manager
    }

    func search(_ query: String) -> [Item] {
        let listener = listener
        let section = "\(listener.port) · \(listener.container ?? listener.command)"
        let url = URL(string: "http://localhost:\(listener.port)")!
        let others = listener.starters.count - 1
        let stopsWhat = others > 0 ? "pid \(listener.pid) and the \(others) process\(others == 1 ? "" : "es") that started it" : "pid \(listener.pid)"
        let open = Item(title: "Open localhost:\(listener.port)", subtitle: "In your browser", action: "Open", section: section,
                        icon: { tile("safari", .systemBlue) }, run: { NSWorkspace.shared.open(url) })
        if listener.isDocker {
            guard let container = listener.container else { return [open] }
            let stop = Item(title: "Stop container \(container)", subtitle: "docker stop, the container keeps its data", action: "Stop",
                            section: section, opens: manager, icon: { tile("stop.fill", .systemOrange) },
                            run: { [manager] in PortTable.stopContainer(container); manager.refreshSoon() })
            return [open, stop].filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }
        }
        var items = [
            open,
            Item(title: "Stop \(listener.command)", subtitle: "Like Ctrl+C, stops \(stopsWhat)", action: "Stop", section: section,
                 opens: manager, icon: { tile("stop.fill", .systemOrange) }, run: { [manager] in self.stop(SIGTERM, then: manager) }),
            Item(title: "Force stop", subtitle: "SIGKILL, for a server that ignores Stop", action: "Force Stop", section: section,
                 opens: manager, icon: { tile("bolt.fill", .systemRed) }, run: { [manager] in self.stop(SIGKILL, then: manager) }),
        ]
        if let folder = listener.folder, FileManager.default.fileExists(atPath: folder) {
            items.append(Item(title: "Show folder in Finder", subtitle: shortPath(folder), action: "Show", section: section,
                              icon: { tile("folder", .systemBlue) }, run: { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) }))
        }
        return items.filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }
    }

    private func stop(_ signal: Int32, then manager: PortPlugin) {
        (listener.starters.isEmpty ? [listener.pid] : listener.starters).forEach { kill($0, signal) }
        manager.refreshSoon()
    }
}

private func shortPath(_ folder: String) -> String {
    folder.hasPrefix(WorkFolder.root + "/") ? String(folder.dropFirst(WorkFolder.root.count + 1))
        : folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}
