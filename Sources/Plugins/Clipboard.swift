import AppKit
import Carbon
import CryptoKit

enum Clip: Codable, Equatable {
    case text(String)
    case image(file: String, width: Int, height: Int, bytes: Int)

    var searchText: String {
        switch self {
        case .text(let text): text
        case .image(_, let width, let height, _): "image \(width)×\(height)"
        }
    }
}

final class ClipboardPlugin: Plugin, Page {
    let name = "Clipboard History"
    let icon = tile("doc.on.clipboard.fill", .systemPurple)
    let placeholder = "Search clipboard history"
    let actionName = "Paste"
    let hasPreview = true
    let hotkey: HotKey? = HotKey(key: kVK_ANSI_V, modifiers: optionKey)
    private var history: [Clip] = []
    private var thumbnails: [String: NSImage] = [:]
    private var thumbnailsInProgress: Set<String> = []
    private let disk = DispatchQueue(label: "clipboard-disk", qos: .utility)
    private var lastChange = NSPasteboard.general.changeCount
    private let file: URL
    private let imagesDir: URL
    private let limit = 300
    private let keepPollingWhileHidden = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "stop App Nap from pausing clipboard polling")
    private static let skippedTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
    ]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hop")
        imagesDir = dir.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("clipboard.json")
        disk.async { [self] in
            let saved = try? Data(contentsOf: file)
            let loaded = saved.flatMap { try? JSONDecoder().decode([Clip].self, from: $0) }
                ?? saved.flatMap { try? JSONDecoder().decode([String].self, from: $0) }?.map(Clip.text)
                ?? []
            DispatchQueue.main.async { [self] in
                history = loaded
                let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
                timer.tolerance = 0.2
                for case .image(let file, _, _, _) in history { makeThumbnail(file) }
            }
        }
    }

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
    }

    func search(_ query: String) -> [Item] {
        history.lazy
            .filter { query.isEmpty || $0.searchText.localizedCaseInsensitiveContains(query) }
            .prefix(100)
            .map(item)
    }

    private func item(for clip: Clip) -> Item {
        switch clip {
        case .text(let text):
            let lines = text.split(whereSeparator: \.isNewline).count
            let isLink = text.hasPrefix("http") && !text.contains(where: \.isWhitespace)
            return Item(title: text.prefix(300).split(whereSeparator: \.isWhitespace).joined(separator: " "),
                        subtitle: lines > 1 ? "\(lines) lines" : "\(text.count) characters",
                        badge: isLink ? "Link" : "Text", preview: .text(text),
                        icon: { isLink ? tile("link", .systemBlue) : tile("text.alignleft", .systemGray) }, run: { [self] in paste(clip) })
        case .image(let file, let width, let height, let bytes):
            return Item(title: "Image", subtitle: "\(width)×\(height) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))",
                        badge: "Image", preview: .image(imagesDir.appendingPathComponent(file)),
                        icon: { [self] in rowIcon(file) }, run: { [self] in paste(clip) })
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        if !Self.skippedTypes.isDisjoint(with: pasteboard.types ?? []) { return }
        if let text = pasteboard.string(forType: .string) {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.text(text)) }
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            disk.async { [self] in
                guard let image = saveImage(data) else { return }
                DispatchQueue.main.async { [self] in add(image) }
            }
        }
    }

    private func saveImage(_ data: Data) -> Clip? {
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard let bitmap = NSBitmapImageRep(data: data),
              let png = isPNG ? data : bitmap.representation(using: .png, properties: [:]) else { return nil }
        let name = SHA256.hash(data: png).prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
        let url = imagesDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try? png.write(to: url) }
        return .image(file: name, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bytes: png.count)
    }

    private func add(_ clip: Clip) {
        history.removeAll { $0 == clip }
        history.insert(clip, at: 0)
        var dropped: [String] = []
        while history.count > limit {
            if case .image(let file, _, _, _) = history.removeLast() {
                dropped.append(file)
                thumbnails[file] = nil
            }
        }
        let snapshot = history
        disk.async { [imagesDir, file] in
            dropped.forEach { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent($0)) }
            try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        }
    }

    private func rowIcon(_ file: String) -> NSImage? {
        if let ready = thumbnails[file] { return ready }
        makeThumbnail(file)
        return tile("photo", .systemGray)
    }

    private func makeThumbnail(_ file: String) {
        guard thumbnailsInProgress.insert(file).inserted else { return }
        let url = imagesDir.appendingPathComponent(file)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let image = thumbnail(of: url, maxPixels: 64).map(framed)
            DispatchQueue.main.async { [self] in
                thumbnails[file] = image
                thumbnailsInProgress.remove(file)
                NotificationCenter.default.post(name: .pageChanged, object: self)
            }
        }
    }

    private func paste(_ clip: Clip) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch clip {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let file, _, _, _):
            guard let png = try? Data(contentsOf: imagesDir.appendingPathComponent(file)) else { return }
            pasteboard.setData(png, forType: .png)
            pasteboard.setData(NSImage(data: png)?.tiffRepresentation, forType: .tiff)
        }
        guard AXIsProcessTrusted() else {
            if !UserDefaults.standard.bool(forKey: "askedAccessibility") {
                UserDefaults.standard.set(true, forKey: "askedAccessibility")
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: keyDown)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }
}
