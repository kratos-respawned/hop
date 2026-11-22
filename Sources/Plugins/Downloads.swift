import AppKit
import CryptoKit
import UserNotifications

final class DownloadsPage: Page {
    let name = "Downloads"
    let icon = tile("arrow.down.circle.fill", .systemRed)
    let placeholder = "Search downloads"
    let actionName = "Show in Finder"
    fileprivate weak var plugin: DownloadsPlugin?

    func search(_ query: String) -> [Item] { plugin?.downloadRows(matching: query) ?? [] }
}

final class QualityPage: Page {
    let name: String
    let icon = tile("slider.horizontal.3", .systemRed)
    let placeholder: String
    let actionName = "Download"
    private let rows: () -> [Item]

    init(name: String, placeholder: String = "Pick a quality", rows: @escaping () -> [Item]) {
        self.name = name
        self.placeholder = placeholder
        self.rows = rows
    }

    func search(_ query: String) -> [Item] { rows().filter { query.isEmpty || fuzzyScore(query, $0.title) != nil } }
}

final class DownloadsPlugin: Plugin, SearchProvider, LinkOpener {
    let linkName = "download"
    private let downloadsPage = DownloadsPage()

    private enum Kind: String {
        case video = "Video"
        case sponsorsCut = "Sponsors cut"
        case sponsorChapters = "Sponsors as chapters"
        case audio = "Audio"

        var fileSuffix: String {
            switch self {
            case .sponsorsCut: return " (sponsors cut)"
            case .sponsorChapters: return " (chapters)"
            case .video, .audio: return ""
            }
        }

        var sponsorOptions: [String] {
            switch self {
            case .sponsorsCut: return ["--sponsorblock-remove", "sponsor,selfpromo,interaction"]
            case .sponsorChapters: return ["--sponsorblock-mark", "all"]
            case .video, .audio: return []
            }
        }
    }

    private struct Quality {
        let label: String
        var detail = ""
        let options: [String]
        let fileSuffix: String

        // Up to 1080p YouTube still has h264, which QuickTime and every phone play; above that it is only VP9 or AV1.
        static func video(height: Int) -> Quality {
            Quality(label: "\(height)p", options: ["-S", height <= 1080 ? "res:\(height),vcodec:h264,acodec:m4a" : "res:\(height),ext:mp4:m4a",
                                                  "--merge-output-format", "mp4"], fileSuffix: " \(height)p")
        }

        static let audio = [Quality(label: "m4a", detail: "Original audio, no re-encode", options: ["-f", "ba[ext=m4a]/ba", "-x", "--audio-format", "m4a"], fileSuffix: ""),
                            Quality(label: "mp3", detail: "Re-encoded at about 190 kbps, plays anywhere", options: ["-f", "ba", "-x", "--audio-format", "mp3", "--audio-quality", "2"], fileSuffix: "")]
    }

    private final class Download {
        let url: String
        let kind: Kind
        let quality: String
        var title: String
        var progress = "Starting"
        var file: URL?
        var failure: String?
        var process: Process?

        init(url: String, kind: Kind, quality: String, title: String) {
            self.url = url
            self.kind = kind
            self.quality = quality
            self.title = title
        }
    }

    private struct Details {
        var title = ""
        var channel = ""
        var duration = ""
        var thumbnail: NSImage?
        var sponsorSeconds: Double?
        var qualities: [Quality]?
        var failure: String?
        let asked = Date()
        var isFetching: Bool { qualities == nil && failure == nil }
    }

    private var downloads: [Download] = []
    private var details: [String: Details] = [:]
    private var lastProgressPost = Date.distantPast
    private var fetchClock: Timer?
    /// Site cookies Masks handed over on the suite line, for posts only a signed-in account sees. Kept in memory only, until the download ends.
    private var logins: [String: String] = [:]
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private let tools = ["/opt/homebrew/bin", "/usr/local/bin"]
    private lazy var ytDlp = tools.map { $0 + "/yt-dlp" }.first(where: FileManager.default.isExecutableFile)
    private static let videoSites = ["youtube.com", "youtu.be", "instagram.com", "x.com", "twitter.com", "reddit.com", "vimeo.com",
                                     "facebook.com", "fb.watch", "tiktok.com", "twitch.tv", "soundcloud.com", "dailymotion.com", "linkedin.com"]

    func register(in hop: PluginRegistry) {
        downloadsPage.plugin = self
        hop.add(search: self)
        hop.add(page: downloadsPage)
        hop.add(link: self)
    }

    /// hop://download?url=<link> opens the download choices for any link, as browsers hand over only pages that play media.
    func page(for link: URLComponents) -> Page? {
        guard let text = link.queryItems?.first(where: { $0.name == "url" })?.value else { return nil }
        return page(downloading: text, login: nil)
    }

    func page(downloading text: String, login: String?) -> Page? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme) else { return nil }
        if details[text]?.failure != nil { details[text] = nil }
        if let login { logins[text] = login }
        return QualityPage(name: "Download", placeholder: "Video or audio") { [self] in choices(text, url) }
    }

    func search(_ query: String) -> [Item] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ytDlp != nil, !text.contains(" "), let url = URL(string: text), ["http", "https"].contains(url.scheme),
              let host = url.host?.lowercased(), Self.videoSites.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return [] }
        return choices(text, url)
    }

    private func choices(_ text: String, _ url: URL) -> [Item] {
        guard ytDlp != nil else { return [] }
        if details[text] == nil { fetchDetails(text, youTubeID: youTubeID(url)) }
        let info = details[text] ?? Details()
        let kinds: [Kind] = youTubeID(url) == nil ? [.video, .audio] : [.video, .sponsorsCut, .sponsorChapters, .audio]
        let explanations: [Kind: String] = [.video: "The whole video. Pick the quality next.",
                                            .sponsorsCut: "SponsorBlock cuts out sponsor reads, self-promo and subscribe reminders. Pick the quality next.",
                                            .sponsorChapters: "Keeps the whole video and marks sponsor segments as chapters you can skip. Pick the quality next.",
                                            .audio: "Only the sound. Pick m4a or mp3 next."]
        return kinds.map { kind in
            let title = kind == .video ? "Video" : kind == .audio ? "Audio" : "Video, \(kind.rawValue.lowercased())"
            return Item(title: title, action: "Choose Quality", preview: .rich(page(for: info, youTube: youTubeID(url) != nil, explaining: explanations[kind] ?? "")),
                        section: "Download to ~/Downloads", opens: QualityPage(name: title) { [self] in qualityRows(text, kind: kind) },
                        icon: { tile(kind == .audio ? "music.note" : "arrow.down", .systemRed) })
        }
    }

    private func qualityRows(_ link: String, kind: Kind) -> [Item] {
        let choices: [Quality]
        if kind == .audio {
            choices = Quality.audio
        } else if let qualities = details[link]?.qualities, !qualities.isEmpty {
            let recommended = qualities.first { Int($0.label.dropLast()) ?? 0 <= 1080 } ?? qualities[0]
            choices = [recommended] + qualities.filter { $0.label != recommended.label }
        } else {
            choices = [Quality.video(height: 1080)]
        }
        var rows = choices.enumerated().map { index, quality in
            Item(title: quality.label, subtitle: quality.detail, badge: kind == .audio || index > 0 ? "" : "Recommended", action: "Download",
                 opens: downloadsPage, icon: { tile(kind == .audio ? "music.note" : "film", .systemRed) },
                 run: { [self] in start(link, kind: kind, quality: quality) })
        }
        if kind != .audio && details[link]?.isFetching != false {
            rows.append(Item(title: "Fetching the other qualities…", icon: { tile("hourglass", .systemGray) }))
        }
        return rows
    }

    private func qualities(from formats: [[String: Any]]) -> [Quality] {
        let size = { (format: [String: Any]) in (format["filesize"] as? Double) ?? (format["filesize_approx"] as? Double) ?? 0 }
        let audio = formats.filter { $0["vcodec"] as? String == "none" && $0["ext"] as? String == "m4a" }.map(size).max() ?? 0
        let video = formats.filter { ($0["vcodec"] as? String ?? "none") != "none" && ($0["height"] as? Int ?? 0) >= 144 }
        return Set(video.compactMap { $0["height"] as? Int }).sorted(by: >).map { height in
            let atHeight = video.filter { $0["height"] as? Int == height }
            let preferred = atHeight.filter { (($0["vcodec"] as? String) ?? "").hasPrefix(height <= 1080 ? "avc1" : "av01") }
            let pick = (preferred.isEmpty ? atHeight : preferred).max { size($0) < size($1) }
            let codec = ((pick?["vcodec"] as? String) ?? "").components(separatedBy: ".").first ?? ""
            let codecName = ["avc1": "h264", "av01": "AV1", "vp9": "VP9", "vp09": "VP9"][codec] ?? codec
            let bytes = (pick.map(size) ?? 0) + (pick?["acodec"] as? String == "none" ? audio : 0)
            var quality = Quality.video(height: height)
            quality.detail = ([bytes > 0 ? "≈ " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) : nil, codecName.isEmpty ? nil : codecName]).compactMap { $0 }.joined(separator: " · ")
            return quality
        }
    }

    fileprivate func downloadRows(matching query: String) -> [Item] {
        guard !downloads.isEmpty else {
            return [Item(title: "No downloads yet", subtitle: "Paste a YouTube, Instagram or X link into the search", icon: { tile("arrow.down.circle", .systemGray) })]
        }
        return downloads.reversed().filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }.map { download in
            let running = download.process?.isRunning == true
            let state = download.failure.map { "Failed: \($0)" } ?? (download.file == nil ? download.progress : "Done")
            return Item(title: download.title, subtitle: "\(download.kind.rawValue) \(download.quality) · \(state)", badge: running ? download.progress.components(separatedBy: " ").first ?? "" : "",
                        action: running ? "Stop" : download.file == nil ? "" : "Show in Finder", opens: running ? downloadsPage : nil,
                        icon: { tile(download.failure != nil ? "exclamationmark.triangle" : download.file == nil ? "arrow.down.circle" : "checkmark.circle.fill",
                                     download.failure != nil ? .systemOrange : download.file == nil ? .systemBlue : .systemGreen) },
                        run: { [self] in
                            if running { download.process?.terminate(); download.failure = "Stopped"; changed() }
                            else if let file = download.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        })
        }
    }

    private func youTubeID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("youtu.be") { return url.pathComponents.dropFirst().first }
        guard host.hasSuffix("youtube.com") else { return nil }
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return id }
        let parts = url.pathComponents
        if let index = parts.firstIndex(where: { ["shorts", "live", "embed"].contains($0) }), parts.indices.contains(index + 1) { return parts[index + 1] }
        return nil
    }

    private func fetchDetails(_ link: String, youTubeID: String?) {
        details[link] = Details()
        fetchInfo(link)
        countSecondsWhileFetching()
        guard let youTubeID else { return }
        sponsorSeconds(for: youTubeID) { [self] seconds in details[link]?.sponsorSeconds = seconds; changed() }
    }

    /// YouTube now and then refuses or stalls a lookup, so one that fails or takes over 45s runs once more before giving up.
    private func fetchInfo(_ link: String, isRetry: Bool = false) {
        guard let ytDlp else { return }
        let lookup = run(ytDlp, ["-J", "--no-playlist", "--skip-download", "--no-warnings", link], login: logins[link]) { [self] output, errors in
            guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
                if !isRetry { return fetchInfo(link, isRetry: true) }
                details[link]?.failure = errors.split(separator: "\n").last { $0.hasPrefix("ERROR") }.map { String($0.dropFirst(7)) } ?? "The site didn't answer in time"
                return changed()
            }
            var info = details[link] ?? Details()
            info.title = json["title"] as? String ?? ""
            info.channel = json["channel"] as? String ?? json["uploader"] as? String ?? ""
            info.qualities = qualities(from: json["formats"] as? [[String: Any]] ?? [])
            info.duration = (json["duration"] as? Double).map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? ""
            details[link] = info
            changed()
            if let thumbnail = (json["thumbnail"] as? String).flatMap(URL.init(string:)) {
                URLSession.shared.dataTask(with: thumbnail) { data, _, _ in
                    guard let image = data.flatMap(NSImage.init(data:)) else { return }
                    DispatchQueue.main.async { [self] in details[link]?.thumbnail = image; changed() }
                }.resume()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { if lookup.isRunning { lookup.terminate() } }
    }

    private func countSecondsWhileFetching() {
        guard fetchClock == nil else { return }
        fetchClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] clock in
            guard let self else { return clock.invalidate() }
            if !details.values.contains(where: \.isFetching) {
                clock.invalidate()
                fetchClock = nil
            }
            changed()
        }
    }

    // SponsorBlock's private lookup: only the first 4 hex characters of the video ID's SHA-256 leave the Mac.
    private func sponsorSeconds(for id: String, then done: @escaping (Double) -> Void) {
        let prefix = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4)
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(prefix)")!
        components.queryItems = [URLQueryItem(name: "categories", value: #"["sponsor","selfpromo","interaction"]"#)]
        URLSession.shared.dataTask(with: components.url!) { data, _, _ in
            let videos = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            let segments = videos.first { $0["videoID"] as? String == id }?["segments"] as? [[String: Any]] ?? []
            let seconds = segments.compactMap { $0["segment"] as? [Double] }.reduce(0) { $0 + ($1.count == 2 ? $1[1] - $1[0] : 0) }
            DispatchQueue.main.async { done(seconds) }
        }.resume()
    }

    private func page(for info: Details, youTube: Bool, explaining choice: String) -> NSAttributedString {
        let page = NSMutableAttributedString()
        if let thumbnail = info.thumbnail {
            let attachment = NSTextAttachment()
            attachment.image = thumbnail
            let width: CGFloat = 370
            attachment.bounds = NSRect(x: 0, y: 0, width: width, height: width * thumbnail.size.height / max(thumbnail.size.width, 1))
            page.append(NSAttributedString(attachment: attachment))
            page.append(NSAttributedString(string: "\n\n"))
        }
        let waited = Int(-info.asked.timeIntervalSinceNow)
        let title = !info.title.isEmpty ? info.title : info.failure != nil ? "Couldn't fetch the video details" : "Fetching video details… \(waited)s"
        page.append(NSAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        let meta = info.failure.map { "\($0). Downloading may still work, at the best quality up to 1080p." }
            ?? [info.channel, info.duration].filter { !$0.isEmpty }.joined(separator: " · ")
        if !meta.isEmpty { page.append(NSAttributedString(string: meta + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])) }
        if youTube {
            let sponsors = info.sponsorSeconds.map { $0 < 1 ? "SponsorBlock: no sponsor segments reported" : "SponsorBlock: \(minutes($0)) of sponsors and self-promo" }
                ?? "SponsorBlock: checking…"
            page.append(NSAttributedString(string: "\n" + sponsors, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                                                  .foregroundColor: (info.sponsorSeconds ?? 0) >= 1 ? NSColor.systemOrange : NSColor.secondaryLabelColor]))
        }
        page.append(NSAttributedString(string: "\n\n" + choice, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        return page
    }

    private func minutes(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }

    private func start(_ link: String, kind: Kind, quality: Quality, isRetry: Bool = false) {
        guard let ytDlp else { return }
        let download = Download(url: link, kind: kind, quality: quality.label, title: details[link]?.title.isEmpty == false ? details[link]!.title : link)
        downloads.append(download)
        let arguments = quality.options + kind.sponsorOptions + ["--no-playlist", "--newline", "--progress", "--no-warnings",
                                        "--progress-template", "download:HOP %(progress._percent_str)s · %(progress._speed_str)s · %(progress._eta_str)s left",
                                        "--print", "before_dl:HOPTITLE %(title)s", "--print", "after_move:HOPFILE %(filepath)s",
                                        "-P", folder.path, "-o", "%(title).150B [%(id)s]\(quality.fileSuffix)\(kind.fileSuffix).%(ext)s", link]
        download.process = run(ytDlp, arguments, login: logins[link], eachLine: { [self] line in
            if line.hasPrefix("HOPTITLE ") { download.title = String(line.dropFirst(9)) }
            else if line.hasPrefix("HOPFILE ") { download.file = URL(fileURLWithPath: String(line.dropFirst(8))) }
            else if line.hasPrefix("HOP ") { download.progress = line.dropFirst(4).replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("[SponsorBlock]") || line.hasPrefix("[Merger]") || line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[ModifyChapters]") {
                download.progress = "Finishing"
            } else { return }
            if Date().timeIntervalSince(lastProgressPost) > 0.4 { lastProgressPost = Date(); changed() }
        }) { [self] _, errors in
            // YouTube now and then rejects a stream link it just handed out; a fresh run gets a new one.
            if !isRetry, download.file == nil, download.failure == nil, errors.contains("HTTP Error 403") {
                downloads.removeAll { $0 === download }
                return start(link, kind: kind, quality: quality, isRetry: true)
            }
            if download.file == nil && download.failure == nil {
                download.failure = errors.split(separator: "\n").last { $0.hasPrefix("ERROR") }.map { String($0.dropFirst(7)) } ?? "yt-dlp stopped"
            }
            logins[link] = nil
            notify(download)
            changed()
        }
        changed()
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], login: String? = nil, eachLine: ((String) -> Void)? = nil, then done: @escaping (String, String) -> Void) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var pair: [Int32] = [-1, -1]
        if login != nil, socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 {
            // The cookies reach yt-dlp through a socket, never a file other programs could read, and it writes them back there on exit.
            // Config files and plugins are skipped, since anything could put one there that saves or sends the cookies.
            process.standardInput = FileHandle(fileDescriptor: pair[1], closeOnDealloc: false)
            process.arguments = ["--ignore-config", "--no-plugin-dirs", "--cookies", "/dev/stdin"] + arguments
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (tools + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        var collected = "", pending = ""
        let lock = NSLock()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            lock.lock()
            collected += eachLine == nil ? chunk : ""
            pending += chunk
            var lines = pending.components(separatedBy: "\n")
            pending = lines.removeLast()
            lock.unlock()
            guard let eachLine, !lines.isEmpty else { return }
            DispatchQueue.main.async { lines.forEach(eachLine) }
        }
        process.terminationHandler = { _ in
            output.fileHandleForReading.readabilityHandler = nil
            let rest = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let failure = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            lock.lock()
            let text = collected + rest
            let lastLines = (pending + rest).components(separatedBy: "\n").filter { !$0.isEmpty }
            lock.unlock()
            DispatchQueue.main.async {
                if let eachLine { lastLines.forEach(eachLine) }
                done(text, failure)
            }
        }
        do { try process.run() } catch { done("", "ERROR: \(error.localizedDescription)") }
        if let login, pair[0] >= 0 {
            close(pair[1])
            var on: Int32 = 1
            setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .utility).async {
                let ours = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
                try? ours.write(contentsOf: Data(login.utf8))
                shutdown(pair[0], SHUT_WR)
                _ = try? ours.readToEnd()
            }
        }
        return process
    }

    private func notify(_ download: Download) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = download.failure == nil ? "Downloaded" : "Download failed"
        content.body = download.failure.map { "\(download.title): \($0)" } ?? download.title
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .pageChanged, object: nil)
    }
}
