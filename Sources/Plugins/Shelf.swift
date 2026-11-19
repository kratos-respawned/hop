import AppKit

final class ShelfPlugin: Plugin, Page {
    let name = "AirDrop Shelf"
    let icon = tile("square.and.arrow.up.on.square.fill", .systemBlue)
    let placeholder = "Search files on the shelf"
    let actionName = "Remove"
    private var files: [URL] = []
    private lazy var shelf = NotchIsland(plugin: self)
    private let drag = NSPasteboard(name: .drag)
    private lazy var lastDragChange = drag.changeCount
    private var lastDragCheck: TimeInterval = 0

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
        shelf.prepare()
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in self?.mouse(event) }
    }

    private func mouse(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            if shelf.isWaitingForDrop { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in shelf.dragEnded() } }
            return
        }
        guard !shelf.isWaitingForDrop, event.timestamp - lastDragCheck > 0.15 else { return }
        lastDragCheck = event.timestamp
        guard drag.changeCount != lastDragChange else { return }
        lastDragChange = drag.changeCount
        if drag.types?.contains(.fileURL) == true { shelf.dragStarted() }
    }

    var count: Int { files.count }

    func add(_ dropped: [URL]) {
        files += dropped.filter { !files.contains($0) }
        changed()
    }

    func remove(_ file: URL) {
        files.removeAll { $0 == file }
        changed()
    }

    func clear() {
        files = []
        changed()
    }

    func airDrop() {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: existing)
    }

    private func changed() {
        shelf.update(files)
        NotificationCenter.default.post(name: .pageChanged, object: self)
    }

    func search(_ query: String) -> [Item] {
        let count = files.count == 1 ? "1 file" : "\(files.count) files"
        let actions = files.isEmpty
            ? [Item(title: "The shelf is empty", subtitle: "Drag files, folders or photos to the notch to shelve them", icon: { tile("tray", .systemBlue) })]
            : [Item(title: "AirDrop \(count)", subtitle: "All in one send, the shelf keeps them until you clear it", action: "AirDrop", icon: { tile("antenna.radiowaves.left.and.right", .systemBlue) },
                    run: { [self] in airDrop() }),
               Item(title: "Show shelf at the notch", action: "Show", icon: { tile("rectangle.topthird.inset.filled", .systemBlue) },
                    run: { [self] in shelf.showFiles() }),
               Item(title: "Tuck shelf into the notch", subtitle: "Hides the pill, the files stay", action: "Hide",
                    icon: { tile("eye.slash", .systemGray) }, run: { [self] in shelf.tuck() }),
               Item(title: "Clear shelf", subtitle: "Removes the files from the shelf, not from disk", action: "Clear",
                    icon: { tile("xmark", .systemGray) }, run: { [self] in clear() })]
        let rows = files.map { file in
            Item(title: file.lastPathComponent, subtitle: file.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                 action: "Remove", section: "On the shelf · \(count)", opens: self, icon: { NSWorkspace.shared.icon(forFile: file.path) },
                 run: { [self] in remove(file) })
        }
        return (actions + rows).filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }
    }
}

