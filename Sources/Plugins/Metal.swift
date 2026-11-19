import AppKit

final class MetalPlugin: Plugin, Page {
    let name = "Metal Manager"
    let icon = tile("cpu", .systemTeal)
    let placeholder = "Search apps and processes"
    let actionName = "Show Actions"
    private let sampleEvery: TimeInterval = 2
    private let sampleWhileHidden: TimeInterval = 10
    private let busyCPU = 1.0
    private let busyListLimit = 6
    private let heatingCPU = 40.0
    private let heavyShareOfRAM = 0.2
    private let memoryNearlyFull = 0.85
    private let worthQuittingWhenNearlyFull: UInt64 = 1_000_000_000
    private let worthQuittingLimit = 5
    private var apps: [RunningApp] = []
    private var memoryUsed: UInt64 = 0
    private var previousTotals: [pid_t: (cpuTime: UInt64, energy: UInt64)] = [:]
    private var previousSampleAt: UInt64 = 0
    private var worthQuittingOrder: [String] = []
    private var cpuOrder: [String] = []
    private var memoryOrder: [String] = []
    private var lastSearch = (query: "", at: Date.distantPast)
    private var isReturningFromActions = false
    private var appIcons: [String: NSImage] = [:]

    init() {
        sample()
        Timer.scheduledTimer(withTimeInterval: sampleEvery, repeats: true) { [weak self] _ in self?.sampleIfDue() }
    }

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
    }

    private var isOnScreen: Bool { Date().timeIntervalSince(lastSearch.at) < sampleEvery * 2 }

    private func sampleIfDue() {
        let sinceLastSample = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - previousSampleAt) / 1e9
        if isOnScreen || sinceLastSample >= sampleWhileHidden { sample() }
    }

    func sample() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = Double(now - previousSampleAt)
        let processes = ProcessTable.snapshot().map { process in
            var process = process
            let previous = previousTotals[process.pid] ?? (process.cpuTime, process.energy)
            process.cpu = process.cpuTime > previous.cpuTime ? Double(process.cpuTime - previous.cpuTime) / elapsed * 100 : 0
            process.watts = process.energy > previous.energy ? Double(process.energy - previous.energy) / elapsed : 0
            return process
        }
        previousTotals = Dictionary(processes.map { ($0.pid, ($0.cpuTime, $0.energy)) }) { first, _ in first }
        previousSampleAt = now
        apps = Dictionary(grouping: processes, by: \.group).values.map(RunningApp.init)
        memoryUsed = ProcessTable.memoryUsed()
        NotificationCenter.default.post(name: .pageChanged, object: self)
    }

    func search(_ query: String) -> [Item] {
        let keepsRows = isReturningFromActions || (query == lastSearch.query && Date().timeIntervalSince(lastSearch.at) < sampleEvery * 2)
        isReturningFromActions = false
        lastSearch = (query, Date())
        let matching = apps.filter { query.isEmpty || fuzzyScore(query, $0.name) != nil }
        if !keepsRows {
            worthQuittingOrder = matching.filter { whyWorthQuitting($0) != nil }
                .sorted { ($0.cpu >= heatingCPU ? $0.cpu : 0, $0.memory) > ($1.cpu >= heatingCPU ? $1.cpu : 0, $1.memory) }
                .prefix(worthQuittingLimit).map(\.key)
            cpuOrder = matching.filter { $0.cpu >= busyCPU }.sorted { $0.cpu > $1.cpu }.prefix(busyListLimit).map(\.key)
            memoryOrder = matching.sorted { $0.memory > $1.memory }.map(\.key)
        }
        let listed = Set(memoryOrder)
        memoryOrder += matching.filter { !listed.contains($0.key) }.map(\.key)
        let byKey = Dictionary(matching.map { ($0.key, $0) }) { first, _ in first }
        let memorySection = "Memory · \(bytes(memoryUsed)) of \(bytes(ProcessInfo.processInfo.physicalMemory)) used"
        let worthQuitting = worthQuittingOrder.compactMap { byKey[$0] }.map { app in
            var item = item(for: app, badge: app.cpu >= heatingCPU ? percent(app.cpu) + " CPU" : bytes(app.memory), section: "Worth quitting")
            item.subtitle = whyWorthQuitting(app) ?? item.subtitle
            return item
        }
        return worthQuitting + cpuOrder.compactMap { byKey[$0] }.map { item(for: $0, badge: percent($0.cpu) + " CPU", section: "CPU") }
            + memoryOrder.compactMap { byKey[$0] }.map { item(for: $0, badge: bytes($0.memory), section: memorySection) }
    }

    func didSelect(_ item: Item, query: String) {
        isReturningFromActions = true
    }

    private func whyWorthQuitting(_ app: RunningApp) -> String? {
        guard app.appPath != Bundle.main.bundlePath else { return nil }
        let ram = ProcessInfo.processInfo.physicalMemory
        let memoryFull = Double(memoryUsed) / Double(ram)
        if app.cpu >= heatingCPU { return "Using \(percent(app.cpu)) CPU, this is what heats the Mac" }
        if Double(app.memory) >= Double(ram) * heavyShareOfRAM { return "Holding \(bytes(app.memory)) of \(bytes(ram)) RAM" }
        if memoryFull >= memoryNearlyFull && app.memory >= worthQuittingWhenNearlyFull {
            return "Memory is \(Int(memoryFull * 100))% full, this frees \(bytes(app.memory))"
        }
        return nil
    }

    private func item(for app: RunningApp, badge: String, section: String) -> Item {
        let count = app.processes.count
        let processText = count == 1 ? "pid \(app.processes[0].pid)" : "\(count) processes"
        let appIcon = icon(for: app)
        return Item(title: app.name, subtitle: "\(processText) · \(impact(of: app))",
                    badge: badge, section: section, opens: ProcessActions(app: app, manager: self), icon: { appIcon })
    }

    private func icon(for app: RunningApp) -> NSImage {
        guard let appPath = app.appPath else { return tile("terminal", .systemGray) }
        if let cached = appIcons[appPath] { return cached }
        let appIcon = NSWorkspace.shared.icon(forFile: appPath)
        appIcons[appPath] = appIcon
        return appIcon
    }

    func quit(_ app: RunningApp, force: Bool) {
        let running = app.appPath.flatMap { path in NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path } }
        if let running, !force {
            running.terminate()
        } else {
            app.processes.forEach { kill($0.pid, force ? SIGKILL : SIGTERM) }
        }
        sampleSoon()
    }

    func forceQuit(_ process: RunningProcess) {
        kill(process.pid, SIGKILL)
        sampleSoon()
    }

    private func sampleSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.sample() }
    }
}

final class ProcessActions: Page {
    let name: String
    let icon = tile("cpu", .systemTeal)
    let placeholder = "Search processes"
    let actionName = "Force Quit"
    private let app: RunningApp
    private unowned let manager: MetalPlugin

    init(app: RunningApp, manager: MetalPlugin) {
        name = app.name
        self.app = app
        self.manager = manager
    }

    func search(_ query: String) -> [Item] {
        let section = "\(app.name) · \(impact(of: app))"
        let quit = Item(title: "Quit \(app.name)", subtitle: app.appPath == nil ? "Sends SIGTERM" : "Asks the app to quit, like ⌘Q",
                        action: "Quit", section: section, opens: manager, icon: { tile("xmark", .systemOrange) },
                        run: { [manager, app] in manager.quit(app, force: false) })
        let forceQuit = Item(title: "Force Quit \(app.name)", subtitle: "Kills all \(app.processes.count) processes now, unsaved work is lost",
                             action: "Force Quit", section: section, opens: manager, icon: { tile("bolt.fill", .systemRed) },
                             run: { [manager, app] in manager.quit(app, force: true) })
        let processes = app.processes.map { process in
            Item(title: process.name, subtitle: (["pid \(process.pid)"] + [ProcessTable.workingFolder(process.pid)].compactMap { $0 }).joined(separator: " · "),
                 badge: "\(bytes(process.memory)) · \(percent(process.cpu)) · \(power(process.watts))", action: "Force Quit", section: "Processes",
                 opens: manager, icon: { tile("gearshape", .systemGray) }, run: { [manager] in manager.forceQuit(process) })
        }
        return ([quit, forceQuit] + processes).filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }
    }
}

private func bytes(_ count: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
}

private func impact(of app: RunningApp) -> String {
    let shareOfMemory = Double(app.memory) / Double(ProcessInfo.processInfo.physicalMemory) * 100
    return "\(bytes(app.memory)) (\(percent(shareOfMemory)) of RAM) · \(percent(app.cpu)) CPU · \(power(app.watts))"
}

private func power(_ watts: Double) -> String {
    watts < 0.01 ? "<0.01 W" : String(format: "%.2f W", watts)
}

private func percent(_ value: Double) -> String {
    value < 10 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
}
