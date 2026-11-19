import AppKit

final class WorktreePlugin: Plugin, Page {
    let name = "Worktree Manager"
    let icon = tile("arrow.triangle.branch", .systemGreen)
    let placeholder = "Search worktrees"
    let actionName = "Show Actions"
    private let rescanAfter: TimeInterval = 600
    private let deleteMergedAfterDays = 3
    private let deletePushedAfterDays = 14
    private let clearArtifactsAfterDays = 7
    private let artifactsWorthClearing: Int64 = 200_000_000
    private let savedFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hop/worktrees.json")
    private var lastScan = Date.distantPast
    private var isScanning = false
    private let disk = DispatchQueue(label: "worktrees-disk", qos: .utility)
    private var saved = Saved() {
        didSet {
            let snapshot = saved
            disk.async { [savedFile] in try? JSONEncoder().encode(snapshot).write(to: savedFile, options: .atomic) }
        }
    }

    private struct Saved: Codable {
        var worktrees: [Worktree] = []
        var sizes: [String: FolderSizes] = [:]
        var statuses: [String: MergeStatus] = [:]
        var activity: [String: Activity] = [:]
        var pullRequests: [String: PullRequest] = [:]
    }

    private struct Recommendation {
        let advice: String
        let frees: Int64
        let deletes: Bool
    }

    init() {
        Tools.warmUp()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let data = try? Data(contentsOf: savedFile), let previous = try? JSONDecoder().decode(Saved.self, from: data) else { return }
            DispatchQueue.main.async { [self] in if saved.worktrees.isEmpty { saved = previous } }
        }
    }

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
    }

    func search(_ query: String) -> [Item] {
        scanIfStale()
        let repoSizes = Dictionary(grouping: saved.worktrees, by: \.repo).mapValues { $0.reduce(0) { $0 + (saved.sizes[$1.folder]?.total ?? 0) } }
        let recommended = query.isEmpty ? recommendedItems() : []
        return recommended + saved.worktrees
            .filter { query.isEmpty || fuzzyScore(query, "\($0.name) \($0.branch) \($0.repo)") != nil }
            .map { item(for: $0, section: "\($0.repo) · \(bytes(repoSizes[$0.repo] ?? 0))") }
    }

    private func item(for worktree: Worktree, section: String) -> Item {
        let sizes = saved.sizes[worktree.folder]
        let status = saved.statuses[worktree.folder]
        let artifactsSize = sizes?.artifacts.reduce(0) { $0 + $1.size } ?? 0
        let sizeText = sizes.map { "\(bytes($0.total))\(artifactsSize > 0 ? ", \(bytes(artifactsSize)) artifacts" : "")" } ?? "Counting size"
        let statusIcon = worktree.isMainCheckout ? tile("house.fill", .systemBlue) : icon(for: status)
        let usedText = saved.activity[worktree.folder].map { " · \(lastUsedText(idleDays($0)))" } ?? ""
        let pullRequestText = saved.pullRequests[worktree.folder].map { " · \($0.text)" } ?? ""
        return Item(title: worktree.name, subtitle: "\(worktree.branch)\(pullRequestText) · \(sizeText)\(usedText)",
                    badge: worktree.isMainCheckout ? "Main checkout" : status?.rawValue ?? "Checking",
                    section: section, opens: WorktreeActions(worktree: worktree, sizes: sizes, status: status, manager: self),
                    icon: { statusIcon })
    }

    private func recommendedItems() -> [Item] {
        let recommended = saved.worktrees.compactMap { worktree in recommendation(for: worktree).map { (worktree, $0) } }
            .sorted { ($0.1.deletes ? 0 : 1, $1.1.frees) < ($1.1.deletes ? 0 : 1, $0.1.frees) }
        let section = "Recommended · frees \(bytes(recommended.reduce(0) { $0 + $1.1.frees }))"
        let items = recommended.map { worktree, recommendation in
            var item = item(for: worktree, section: section)
            item.subtitle = "\(worktree.repo) · \(recommendation.advice)"
            item.badge = "Frees \(bytes(recommendation.frees))"
            return item
        }
        let deletable = recommended.filter { $0.1.deletes }
        guard deletable.count > 1 else { return items }
        return [deleteAllItem(deletable.map { ($0.0, $0.1.frees) }, section: section)] + items
    }

    private func deleteAllItem(_ deletable: [(worktree: Worktree, size: Int64)], section: String) -> Item {
        let frees = bytes(deletable.reduce(0) { $0 + $1.size })
        let worktrees = deletable.map(\.worktree)
        let deleteAll = Item(title: "Delete \(worktrees.count) worktrees", subtitle: "Branches stay", badge: "Frees \(frees)",
                             action: "Delete All", section: "Everything in these is merged or on a remote", opens: self,
                             icon: { tile("trash.fill", .systemRed) }, run: { [self] in worktrees.forEach(delete) })
        let listed = deletable.map { worktree, size in
            Item(title: worktree.name, subtitle: "\(worktree.repo) · \(worktree.branch)", badge: bytes(size),
                 action: "Nothing to run", section: "Will be deleted", icon: { tile("trash", .systemGray) })
        }
        return Item(title: "Delete all pushed worktrees", subtitle: "\(worktrees.count) worktrees, merged or fully pushed",
                    badge: "Frees \(frees)", action: "Review", section: section,
                    opens: ReviewPage(name: "Delete pushed worktrees", items: [deleteAll] + listed),
                    icon: { tile("trash.fill", .systemRed) })
    }

    private func recommendation(for worktree: Worktree) -> Recommendation? {
        guard !worktree.isMainCheckout, let sizes = saved.sizes[worktree.folder],
              let activity = saved.activity[worktree.folder], let status = saved.statuses[worktree.folder] else { return nil }
        let idle = idleDays(activity)
        let artifactsSize = sizes.artifacts.reduce(0) { $0 + $1.size }
        if (status == .inMain || status == .inUAT) && idle >= deleteMergedAfterDays {
            return Recommendation(advice: "Delete, \(status.rawValue.lowercased()) and unused for \(idle) days", frees: sizes.total, deletes: true)
        }
        let hasLocalEdits = [.uncommitted, .uncommittedInMain, .uncommittedInUAT].contains(status)
        if let pullRequest = saved.pullRequests[worktree.folder], pullRequest.isMerged, !hasLocalEdits, idle >= deleteMergedAfterDays {
            return Recommendation(advice: "Delete, PR #\(pullRequest.number) merged and unused for \(idle) days", frees: sizes.total, deletes: true)
        }
        if status == .notMerged && activity.unpushedCommits == 0 && idle >= deletePushedAfterDays {
            return Recommendation(advice: "Delete, everything pushed and unused for \(idle) days", frees: sizes.total, deletes: true)
        }
        if idle >= clearArtifactsAfterDays && artifactsSize >= artifactsWorthClearing {
            return Recommendation(advice: "Clear artifacts, unused for \(idle) days", frees: artifactsSize, deletes: false)
        }
        return nil
    }

    private func idleDays(_ activity: Activity) -> Int {
        Int(Date().timeIntervalSince(activity.lastUsed) / 86_400)
    }

    private func lastUsedText(_ days: Int) -> String {
        switch days {
        case 0: "used today"
        case 1: "used yesterday"
        default: "used \(days) days ago"
        }
    }

    private func icon(for status: MergeStatus?) -> NSImage {
        switch status {
        case .inMain, .inUAT: tile("checkmark", .systemGreen)
        case .notMerged: tile("arrow.triangle.pull", .systemOrange)
        case .uncommitted, .uncommittedInMain, .uncommittedInUAT: tile("pencil", .systemRed)
        case nil: tile("hourglass", .systemGray)
        }
    }

    func clear(_ artifact: Artifact, in worktree: Worktree) {
        guard WorkFolder.clear(artifact), let sizes = saved.sizes[worktree.folder] else { return }
        let cleared = Set(artifact.folders)
        saved.sizes[worktree.folder] = FolderSizes(total: sizes.total - artifact.size,
                                                   artifacts: sizes.artifacts.filter { !cleared.isSuperset(of: $0.folders) })
    }

    func delete(_ worktree: Worktree) {
        PortTable.stopServers(in: worktree.folder)
        guard WorkFolder.delete(worktree) else { return }
        saved.worktrees.removeAll { $0.folder == worktree.folder }
        saved.sizes[worktree.folder] = nil
        saved.statuses[worktree.folder] = nil
        saved.activity[worktree.folder] = nil
        saved.pullRequests[worktree.folder] = nil
    }

    private func scanIfStale() {
        guard !isScanning, Date().timeIntervalSince(lastScan) > rescanAfter else { return }
        isScanning = true
        DispatchQueue.global(qos: .utility).async { [self] in
            let found = WorkFolder.worktrees()
            onMain { [self] in saved.worktrees = found }
            let work = OperationQueue()
            work.maxConcurrentOperationCount = 8
            for repo in Set(found.map(\.repo)) {
                work.addOperation { [self] in
                    WorkFolder.fetch(repo)
                    work.addOperation { [self] in
                        let pullRequests = WorkFolder.pullRequests(of: repo)
                        onMain { [self] in
                            for worktree in found where worktree.repo == repo && !worktree.isMainCheckout {
                                saved.pullRequests[worktree.folder] = pullRequests[worktree.branch]
                            }
                        }
                    }
                    for worktree in found where worktree.repo == repo && !worktree.isMainCheckout {
                        work.addOperation { [self] in
                            let status = WorkFolder.status(of: worktree)
                            let activity = WorkFolder.activity(of: worktree)
                            onMain { [self] in
                                saved.statuses[worktree.folder] = status
                                saved.activity[worktree.folder] = activity
                            }
                        }
                    }
                }
            }
            for worktree in found {
                work.addOperation { [self] in
                    let sizes = WorkFolder.sizes(of: worktree)
                    onMain { [self] in saved.sizes[worktree.folder] = sizes }
                }
            }
            work.waitUntilAllOperationsAreFinished()
            onMain { [self] in
                let current = Set(found.map(\.folder))
                saved.sizes = saved.sizes.filter { current.contains($0.key) }
                saved.statuses = saved.statuses.filter { current.contains($0.key) }
                saved.activity = saved.activity.filter { current.contains($0.key) }
                saved.pullRequests = saved.pullRequests.filter { current.contains($0.key) }
                lastScan = Date()
                isScanning = false
            }
        }
    }

    private func onMain(_ update: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in
            update()
            NotificationCenter.default.post(name: .pageChanged, object: self)
        }
    }
}

final class WorktreeActions: Page {
    let name: String
    let icon = tile("arrow.triangle.branch", .systemGreen)
    let placeholder = "Search actions"
    let actionName = "Run"
    private let worktree: Worktree
    private let sizes: FolderSizes?
    private let status: MergeStatus?
    private unowned let manager: WorktreePlugin

    init(worktree: Worktree, sizes: FolderSizes?, status: MergeStatus?, manager: WorktreePlugin) {
        name = worktree.name
        self.worktree = worktree
        self.sizes = sizes
        self.status = status
        self.manager = manager
    }

    func search(_ query: String) -> [Item] {
        let servers = PortTable.servers(in: worktree.folder)
        PortTable.refresh { [self] in NotificationCenter.default.post(name: .pageChanged, object: self) }
        let actions = startItems() + serverItems(servers) + artifactItems() + (worktree.isMainCheckout ? [] : [deleteItem(stopping: servers)])
        return actions.filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }
    }

    private func startItems() -> [Item] {
        let folder = URL(fileURLWithPath: worktree.folder)
        let section = "\(worktree.name) · \(worktree.branch)"
        let isWebProject = FileManager.default.fileExists(atPath: worktree.folder + "/package.json")
        let editor = isWebProject ? Tools.webEditor : Tools.androidEditor
        let terminal = Tools.terminal
        var items: [Item] = []
        if let editor {
            let editorName = editor.deletingPathExtension().lastPathComponent
            items.append(Item(title: "Open in \(editorName)", action: "Open", section: section, icon: { NSWorkspace.shared.icon(forFile: editor.path) },
                              run: { NSWorkspace.shared.open([folder], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) }))
        }
        guard let terminal else { return items }
        items.append(Item(title: "Open terminal here", action: "Open", section: section, icon: { NSWorkspace.shared.icon(forFile: terminal.path) },
                          run: { NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) }))
        if hasDevScript {
            items.append(Item(title: "Run npm run dev", subtitle: "In a new terminal window, Ctrl+C leaves you in this folder", action: "Run",
                              section: section, icon: { tile("play.fill", .systemGreen) },
                              run: { [worktree] in runInTerminal("npm run dev", in: worktree, with: terminal) }))
        }
        return items
    }

    // shortcut: a text search, not a JSON parse; a "dev" key outside scripts also matches, parse properly if that misfires.
    private var hasDevScript: Bool {
        (FileManager.default.contents(atPath: worktree.folder + "/package.json")).map { String(decoding: $0, as: UTF8.self).contains("\"dev\":") } ?? false
    }

    private func serverItems(_ servers: [Listener]) -> [Item] {
        servers.map { server in
            Item(title: "Stop \(server.command)", subtitle: "Port \(server.port) · pid \(server.pid)", action: "Stop",
                 section: "\(worktree.name) · Running servers", opens: manager, icon: { tile("stop.fill", .systemOrange) },
                 run: { PortTable.stop(server, signal: SIGTERM) })
        }
    }

    private func artifactItems() -> [Item] {
        let groups = sizes?.artifacts ?? []
        let all = Artifact(name: "All artifacts", folders: groups.flatMap(\.folders), size: groups.reduce(0) { $0 + $1.size })
        return (groups.count > 1 ? [all] + groups : groups).map { artifact in
            let count = artifact.folders.count
            let section = "\(worktree.name) · Clear build artifacts"
            let path = relativePath(artifact.folders[0])
            let whereText = count > 1 ? "\(count) folders" : path == artifact.name ? "" : path
            return Item(title: artifact.name, subtitle: whereText, badge: bytes(artifact.size), action: "Clear",
                        section: section, opens: manager, icon: { tile("trash", .systemGray) },
                        run: { [manager, worktree] in manager.clear(artifact, in: worktree) })
        }
    }

    private func deleteItem(stopping servers: [Listener]) -> Item {
        let warning = switch status {
        case .inMain: "Everything here is in origin/main. The branch stays."
        case .inUAT: "Everything here is in origin/uat. The branch stays."
        case .notMerged: "Not in uat or main yet. Commits stay on the branch."
        case .uncommitted: "Uncommitted changes here will be lost."
        case .uncommittedInMain: "Commits are in origin/main, but local edits that were never committed will be lost."
        case .uncommittedInUAT: "Commits are in origin/uat, but local edits that were never committed will be lost."
        case nil: "Merge status is still being checked."
        }
        let stopsText = servers.isEmpty ? "" : " Stops \(servers.count) running server\(servers.count == 1 ? "" : "s") first."
        return Item(title: "Delete worktree", subtitle: warning + stopsText, badge: sizes.map { bytes($0.total) } ?? "",
                    action: "Delete", section: "\(worktree.name) · Delete", opens: manager,
                    icon: { tile("trash.fill", .systemRed) }, run: { [manager, worktree] in manager.delete(worktree) })
    }

    private func relativePath(_ folder: String) -> String {
        folder.replacingOccurrences(of: worktree.folder + "/", with: "")
    }
}

final class ReviewPage: Page {
    let name: String
    let icon = tile("trash.fill", .systemRed)
    let placeholder = "Search"
    let actionName = "Run"
    private let items: [Item]

    init(name: String, items: [Item]) {
        self.name = name
        self.items = items
    }

    func search(_ query: String) -> [Item] {
        items.filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }
    }
}

enum Tools {
    static let webEditor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.jetbrains.WebStorm")
    static let androidEditor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.android.studio")
    static let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")

    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = (webEditor, androidEditor, terminal) }
    }
}

// The script file lets the terminal run the command and then keep a shell open in the worktree.
private func runInTerminal(_ command: String, in worktree: Worktree, with terminal: URL) {
    let scripts = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hop/run")
    try? FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let script = scripts.appendingPathComponent(worktree.folder.replacingOccurrences(of: "/", with: "_"))
    let folder = "'" + worktree.folder.replacingOccurrences(of: "'", with: "'\\''") + "'"
    try? "#!/bin/zsh -il\ncd \(folder) && \(command)\nexec zsh -il\n".write(to: script, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
}

private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}
