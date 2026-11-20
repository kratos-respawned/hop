import AppKit
import CoreImage
import UniformTypeIdentifiers

final class SharePlugin: Plugin, Page {
    let name = "Share Files"
    let icon = tile("wifi", .systemTeal)
    let placeholder = "Search sharing"
    let actionName = "Start"
    var hasPreview: Bool { true }
    private var server: ShareServer?
    private var address = ""
    private var transfers: [Transfer] = []
    private var notice = ""
    private var qr: (link: String, image: NSImage?) = ("", nil)
    private let inbox = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Hop Inbox")

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
    }

    private var link: String {
        guard let server, server.port != 0 else { return "" }
        return "http://\(address):\(server.port)/\(server.code)/"
    }

    func search(_ query: String) -> [Item] {
        let rows = (server.map(runningRows) ?? startRows) + transferRows
        return rows.filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }
    }

    private var startRows: [Item] {
        let notice = notice.isEmpty ? [] : [Item(title: notice, preview: .rich(text([notice])), section: "Start sharing", icon: { tile("info.circle.fill", .systemOrange) })]
        return notice + [
            Item(title: "Receive files", subtitle: "Phones and laptops send files into Downloads/Hop Inbox", action: "Start",
                 preview: .rich(text(["Receive files", "Devices on your Wi-Fi send files into Downloads/Hop Inbox. They can't see anything on this Mac."])),
                 section: "Start sharing", opens: self, icon: { tile("square.and.arrow.down.fill", .systemTeal) },
                 run: { [self] in start(.receive, in: inbox) }),
            Item(title: "Share a folder", subtitle: "Others can browse and download, not change anything", action: "Choose Folder",
                 preview: .rich(text(["Share a folder", "Devices on your Wi-Fi can browse the folder you pick and download from it. They can't add, change or delete anything."])),
                 section: "Start sharing", icon: { tile("folder.fill", .systemBlue) }, run: { [self] in chooseFolder(.share) }),
            Item(title: "Share and receive in a folder", subtitle: "Others can browse, download and add files", action: "Choose Folder",
                 preview: .rich(text(["Share and receive in a folder", "Devices on your Wi-Fi can browse the folder you pick, download from it and add files to it. They can't change or delete anything."])),
                 section: "Start sharing", icon: { tile("arrow.up.arrow.down", .systemIndigo) }, run: { [self] in chooseFolder(.both) }),
        ]
    }

    private func runningRows(_ server: ShareServer) -> [Item] {
        let folder = server.root.lastPathComponent
        let title = switch server.mode {
        case .receive: "Receiving into Hop Inbox"
        case .share: "Sharing \(folder)"
        case .both: "Sharing and receiving in \(folder)"
        }
        guard !link.isEmpty else { return [Item(title: "Starting…", section: "Sharing now", icon: { tile("wifi", .systemTeal) })] }
        let preview = Preview.rich(linkPreview(server))
        return [
            Item(title: title, subtitle: link, badge: "Live", action: "Copy Link", preview: preview, section: "Sharing now", opens: self,
                 icon: { tile("wifi", .systemTeal) }, run: { [self] in
                     NSPasteboard.general.clearContents()
                     NSPasteboard.general.setString(link, forType: .string)
                 }),
            Item(title: "Stop sharing", subtitle: "The link stops working right away", action: "Stop", preview: preview, section: "Sharing now",
                 opens: self, icon: { tile("stop.fill", .systemRed) }, run: { [self] in stop() }),
        ]
    }

    private var transferRows: [Item] {
        transfers.map { transfer in
            let file = transfer.file, name = file.lastPathComponent
            let title = switch (transfer.state, transfer.incoming) {
            case (.running, true): "Receiving \(name)"
            case (.running, false): "Sending \(name)"
            case (.finished, true): "Received \(name)"
            case (.finished, false): "Sent \(name)"
            case (.failed, _): "Didn't finish \(name)"
            }
            let size = ByteCountFormatter.string(fromByteCount: Int64(transfer.total), countStyle: .file)
            let amount = transfer.state == .running && transfer.total > 0 ? "\(transfer.done * 100 / transfer.total)% of \(size)" : size
            let when = RelativeDateTimeFormatter().localizedString(for: transfer.startedAt, relativeTo: Date())
            let exists = transfer.state == .finished || !transfer.incoming
            let isImage = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
            return Item(title: title, subtitle: "\(amount) · \(transfer.device) · \(when)", action: exists ? "Show in Finder" : "",
                        preview: exists && isImage ? .image(file) : nil, section: "Activity",
                        icon: { exists ? NSWorkspace.shared.icon(forFile: file.path) : tile("exclamationmark.triangle.fill", .systemOrange) },
                        run: exists ? { NSWorkspace.shared.activateFileViewerSelecting([file]) } : nil)
        }
    }

    private func start(_ mode: ShareMode, in folder: URL) {
        guard let address = ShareServer.networkAddress else {
            notice = "Join a Wi-Fi network first, sharing works only on a local network"
            return changed()
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.address = address
        notice = ""
        let server = ShareServer(mode: mode, root: folder)
        server.onReady = { [weak self] in self?.changed() }
        server.onTransfer = { [weak self] in self?.update($0) }
        server.onStop = { [weak self, weak server] reason in
            guard let self, self.server === server else { return }
            self.server = nil
            notice = reason
            changed()
        }
        self.server = server
        server.start()
        changed()
    }

    private func stop() {
        server?.stop()
        server = nil
        changed()
    }

    private func chooseFolder(_ mode: ShareMode) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = mode == .share ? "Share" : "Share and Receive"
        panel.message = mode == .share ? "Devices on your Wi-Fi can browse and download from this folder" : "Devices on your Wi-Fi can browse, download and add files to this folder"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [self] response in
            guard response == .OK, let folder = panel.url else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if home.hasPrefix(folder.path) || folder.path.hasPrefix(home + "/Library") {
                notice = "Pick a smaller folder, sharing your whole home or Library would expose private files"
                changed()
            } else {
                start(mode, in: folder)
            }
            launcher.toggle(self)
        }
    }

    private func update(_ transfer: Transfer) {
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
        } else {
            transfers.insert(transfer, at: 0)
            transfers = Array(transfers.prefix(50))
        }
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .pageChanged, object: self)
    }

    private func linkPreview(_ server: ShareServer) -> NSAttributedString {
        if qr.link != link { qr = (link, Self.qrCode(link)) }
        let what = switch server.mode {
        case .receive: "They can send files into Downloads/Hop Inbox and see nothing on this Mac."
        case .share: "They can browse and download from \(server.root.lastPathComponent), nothing else."
        case .both: "They can browse, download and add files in \(server.root.lastPathComponent), nothing else."
        }
        let preview = NSMutableAttributedString()
        if let image = qr.image {
            preview.append(DigestCard.attached(image))
            preview.append(NSAttributedString(string: "\n"))
        }
        preview.append(text([link, "Scan the code with a phone camera, or open the link in any browser on the same Wi-Fi. " + what]))
        preview.append(NSAttributedString(string: "\n"))
        preview.append(DigestCard.attached(DigestCard.callout(
            "Don't share on public Wi-Fi. Files travel unencrypted, so anyone on a café, hotel or office network can see them. On public Wi-Fi, connect this Mac to your phone's hotspot first.",
            symbol: "exclamationmark.triangle.fill", color: .systemOrange)))
        preview.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        preview.append(text(["Sharing stops by itself after 15 minutes without activity."], titled: false))
        return preview
    }

    private func text(_ paragraphs: [String], titled: Bool = true) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 10
        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let isTitle = titled && index == 0
            let font = isTitle ? NSFont.systemFont(ofSize: 15, weight: .semibold) : NSFont.systemFont(ofSize: 13)
            let color = isTitle ? NSColor.labelColor : NSColor.secondaryLabelColor
            result.append(NSAttributedString(string: paragraph + (index == paragraphs.count - 1 ? "" : "\n"),
                                             attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        return result
    }

    private static func qrCode(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, let code = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(size: NSSize(width: 188, height: 188), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.interpolationQuality = .none
            context.draw(code, in: rect.insetBy(dx: 14, dy: 14))
            return true
        }
    }
}
