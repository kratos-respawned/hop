import AppKit

struct ClaudeSession: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let status: String?

    var title: String { name ?? (cwd as NSString).lastPathComponent }
    var isWorking: Bool { status == "busy" }
}

enum ClaudeSessions {
    private static let claudeFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private static let subagentWorkingWindow: TimeInterval = 120

    static func running() -> [ClaudeSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: claudeFolder.appendingPathComponent("sessions"),
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(read)
    }

    static func session(pid: Int32) -> ClaudeSession? {
        read(claudeFolder.appendingPathComponent("sessions/\(pid).json"))
    }

    static func workingSubagents(of session: ClaudeSession) -> Int {
        let projectFolder = String(session.cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let subagents = claudeFolder.appendingPathComponent("projects/\(projectFolder)/\(session.sessionId)/subagents")
        let transcripts = (try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let activeSince = Date().addingTimeInterval(-subagentWorkingWindow)
        return transcripts.filter { $0.pathExtension == "jsonl" && modifiedAt($0) > activeSince }.count
    }

    private static func read(_ file: URL) -> ClaudeSession? {
        guard let session = try? JSONDecoder().decode(ClaudeSession.self, from: Data(contentsOf: file)),
              kill(session.pid, 0) == 0 else { return nil }
        return session
    }

    private static func modifiedAt(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

final class ClaudePlugin: Plugin, Page {
    let name = "Claude Manager"
    let icon = tile("sparkles", .systemOrange)
    let placeholder = "Search Claude sessions"
    let actionName = "Caffeinate"
    private let keepAwake = KeepAwake()
    private var caffeinated: [Int32: String] = [:] {
        didSet { try? caffeinated.values.joined(separator: "\n").write(to: caffeinatedList, atomically: true, encoding: .utf8) }
    }
    private let caffeinatedList = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hop/caffeinated-sessions")

    init() {
        try? FileManager.default.removeItem(at: caffeinatedList)
    }
    private var finishedWorkCheck: Timer?

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
    }

    func search(_ query: String) -> [Item] {
        ClaudeSessions.running()
            .filter { query.isEmpty || fuzzyScore(query, $0.title + " " + $0.cwd) != nil }
            .sorted { ($0.isWorking ? 0 : 1, $0.title) < ($1.isWorking ? 0 : 1, $1.title) }
            .map(item)
    }

    private func item(for session: ClaudeSession) -> Item {
        let isCaffeinated = caffeinated[session.pid] != nil
        let subagents = ClaudeSessions.workingSubagents(of: session)
        let folder = session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let subagentsText = subagents == 0 ? nil : "\(subagents) subagent\(subagents == 1 ? "" : "s") working"
        let statusIcon = isCaffeinated ? tile("cup.and.saucer.fill", .systemBrown)
            : session.isWorking ? tile("bolt.fill", .systemOrange) : tile("moon.zzz.fill", .systemGray)
        var item = Item(title: session.title, subtitle: [folder, subagentsText].compactMap { $0 }.joined(separator: " · "),
                        badge: isCaffeinated ? "Caffeinated" : session.isWorking ? "Working" : "Idle",
                        action: "Nothing to caffeinate", section: "Claude Sessions", icon: { statusIcon })
        if isCaffeinated {
            item.action = "Decaf"
            item.run = { [self] in decaf(session.pid) }
        } else if session.isWorking {
            item.action = "Caffeinate"
            item.run = { [self] in caffeinate(session) }
        }
        return item
    }

    private func caffeinate(_ session: ClaudeSession) {
        keepAwake.start { [self] started in
            guard started else { return }
            caffeinated[session.pid] = session.sessionId
            if finishedWorkCheck == nil {
                finishedWorkCheck = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.decafFinishedSessions() }
            }
        }
    }

    private func decafFinishedSessions() {
        for pid in caffeinated.keys where ClaudeSessions.session(pid: pid)?.isWorking != true {
            decaf(pid)
        }
    }

    private func decaf(_ pid: Int32) {
        caffeinated[pid] = nil
        guard caffeinated.isEmpty else { return }
        keepAwake.stop()
        finishedWorkCheck?.invalidate()
        finishedWorkCheck = nil
    }
}
