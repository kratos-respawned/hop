import AppKit

struct Wallpaper: Codable {
    let id: String
    let title: String
    let detail: String
    let size: String
    let thumbnail: URL
    let full: URL
    var nsfw = false
    var keywords = ""
}

final class WallpapersPlugin: Plugin, Page {
    let name = "Wallpapers"
    let icon = tile("photo.on.rectangle.angled", .systemPurple)
    let placeholder = "Search Wallhaven"
    let actionName = "Set as Wallpaper"
    var hasPreview: Bool { true }

    private var feeds: [String: [Wallpaper]] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var pictures: [String: NSImage] = [:]
    private var picturesAsked = Set<String>()
    private var savedIcons: [String: NSImage] = [:]
    private var downloading: String?
    private var failures: [String: String] = [:]
    private var wanted = ""
    private var redditCookie: String?
    private var redditExpired = false
    private var redditProblem: String?
    private var feedErrors: [String: String] = [:]
    private let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Hop Wallpapers")
    private let bing = "Bing · picture of the day"
    private let topThisWeek = "Wallhaven · top this week"
    private let anime = "Wallhaven · anime"
    private let reddit = "Reddit · top this week"
    private let redditLibrary = RedditLibrary()

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
        redditLibrary.load()
        DispatchQueue.global(qos: .utility).async { [self] in
            let cookie = RedditLogin.load()
            DispatchQueue.main.async { [self] in redditCookie = cookie }
        }
    }

    func search(_ query: String) -> [Item] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.isEmpty else { return searchRows(text) }
        for feed in [bing, topThisWeek, anime] + (redditReady ? [reddit] : []) where isStale(feed) { fetch(feed) }
        refreshRedditLibrary()
        func rows(_ feed: String) -> [Item] {
            if let error = feedErrors[feed], feeds[feed]?.isEmpty == true { return [Item(title: error, section: feed, icon: { tile("exclamationmark.triangle", .systemOrange) })] }
            return feeds[feed].map { visibleRows($0, in: feed) } ?? [Item(title: "Loading…", section: feed, icon: { tile("hourglass", .systemGray) })]
        }
        return rows(bing) + (redditReady ? rows(reddit) : [connectRedditRow()]) + rows(topThisWeek) + rows(anime) + savedRows()
    }

    private func connectRedditRow() -> Item {
        let steps = """
            Open reddit.com in Chrome while logged in. Open DevTools, go to Network and reload the page. Right-click the first request, the www.reddit.com page itself, and choose Copy as cURL. Then press Enter here.

            Hop keeps only the reddit_session cookie, in your Keychain, then clears the clipboard and removes the copied request from clipboard history.
            """
        return Item(title: redditExpired ? "Reddit login expired, connect again" : "Connect Reddit", subtitle: redditProblem ?? "Copy a reddit.com request, then press Enter",
                    action: "Connect", preview: .rich(NSAttributedString(string: steps, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])),
                    section: "Reddit", opens: self, icon: { tile("person.badge.key", .systemOrange) }, run: { [self] in connectReddit() })
    }

    private func connectReddit() {
        guard let cookie = takeFromClipboard(matching: #"(?<=reddit_session=)[^;'"\s]+"#) else {
            redditProblem = "No reddit_session cookie there. Copy the www.reddit.com page request"
            return changed()
        }
        redditCookie = cookie
        redditExpired = false
        redditProblem = nil
        fetchedAt[reddit] = nil
        changed()
        DispatchQueue.global(qos: .utility).async { RedditLogin.save(cookie) }
    }

    private var redditReady: Bool { redditCookie != nil && !redditExpired }

    private func refreshRedditLibrary() {
        guard redditReady, let redditCookie else { return }
        redditLibrary.refresh(cookie: redditCookie) { [self] loggedOut in
            if loggedOut {
                redditExpired = true
                redditProblem = "Reddit answered HTTP 403"
            }
            changed()
        }
    }

    private func searchRows(_ text: String) -> [Item] {
        let sources = (redditReady ? ["Reddit"] : []) + ["Wallhaven"]
        wanted = text
        let groups = sources.map { source -> [Item] in
            let feed = "\(source) · \(text)"
            if source == "Reddit" {
                refreshRedditLibrary()
                let found = redditLibrary.matches(text)
                loadThumbnails(of: found)
                let rows = visibleRows(found, in: feed)
                let count = redditLibrary.wallpapers.count
                let building = redditLibrary.isBuilding ? " Hop is still collecting more." : ""
                let why = """
                    Reddit doesn't let apps search, so Hop keeps its own library of \(count) top wallpapers from r/wallpapers, r/EarthPorn, r/spaceporn, r/Animewallpaper and others, and searches their titles, subreddits and flairs. Words like nature, space, art and anime match whole subreddits.\(building)
                    """
                return rows.isEmpty ? [Item(title: redditLibrary.isBuilding && count == 0 ? "Collecting Reddit wallpapers…" : "Nothing on Reddit for \(text)",
                                            subtitle: "\(count) wallpapers in the library",
                                            preview: .rich(NSAttributedString(string: why, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])),
                                            section: feed, icon: { tile("photo", .systemGray) })] : rows
            }
            guard let found = feeds[feed] else {
                if fetchedAt[feed] == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in if wanted == text && fetchedAt[feed] == nil { fetch(feed, query: text) } }
                }
                return [Item(title: "Searching \(source) for \(text)…", section: feed, icon: { tile("magnifyingglass", .systemGray) })]
            }
            let rows = visibleRows(found, in: feed)
            return rows.isEmpty ? [Item(title: "Nothing on \(source) for \(text)", subtitle: feedErrors[feed] ?? "", section: feed, icon: { tile("photo", .systemGray) })] : rows
        }
        let found = groups.filter { $0.contains { $0.run != nil } }
        let empty = groups.filter { !$0.contains { $0.run != nil } }
        return (redditReady ? [] : [connectRedditRow()]) + Array(found.joined()) + Array(empty.joined())
    }

    private func isStale(_ feed: String) -> Bool {
        Date().timeIntervalSince(fetchedAt[feed] ?? .distantPast) > 6 * 3600
    }

    private func visibleRows(_ wallpapers: [Wallpaper], in feed: String) -> [Item] {
        wallpapers.filter { !$0.nsfw || Setting.redditNSFW.isOn }.map { item(for: $0, section: feed) }
    }

    private func item(for wallpaper: Wallpaper, section: String) -> Item {
        let picture = pictures[wallpaper.id]
        let state = downloading == wallpaper.id ? "Downloading…" : failures[wallpaper.id] ?? wallpaper.detail
        return Item(title: wallpaper.title, subtitle: state, badge: wallpaper.size, preview: .rich(preview(of: wallpaper, picture: picture)),
                    section: section, opens: self, icon: { picture.map(framed) ?? tile("photo", .systemPurple) },
                    run: { [self] in apply(wallpaper) })
    }

    private func savedRows() -> [Item] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { modified($0) > modified($1) }
        let missing = files.filter { savedIcons[$0.path] == nil }
        if !missing.isEmpty {
            DispatchQueue.global(qos: .utility).async { [self] in
                let icons = missing.compactMap { file in thumbnail(of: file, maxPixels: 80).map { (file.path, framed($0)) } }
                DispatchQueue.main.async { [self] in
                    icons.forEach { savedIcons[$0.0] = $0.1 }
                    changed()
                }
            }
        }
        return files.map { file in
            let icon = savedIcons[file.path]
            return Item(title: file.deletingPathExtension().lastPathComponent, subtitle: "~/Pictures/Hop Wallpapers", preview: .image(file),
                        section: "Saved · \(files.count)", opens: self, icon: { icon ?? tile("photo", .systemGray) },
                        run: { [self] in setWallpaper(file) })
        }
    }

    private func preview(of wallpaper: Wallpaper, picture: NSImage?) -> NSAttributedString {
        let page = NSMutableAttributedString()
        if let picture {
            let attachment = NSTextAttachment()
            attachment.image = picture
            attachment.bounds = NSRect(x: 0, y: 0, width: 370, height: 370 * picture.size.height / max(picture.size.width, 1))
            page.append(NSAttributedString(attachment: attachment))
            page.append(NSAttributedString(string: "\n\n"))
        }
        page.append(NSAttributedString(string: wallpaper.title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        page.append(NSAttributedString(string: "\(wallpaper.size) · \(wallpaper.detail)\n\nEnter downloads the full image and sets it on every screen.",
                                       attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        return page
    }

    private func fetch(_ feed: String, query: String? = nil) {
        fetchedAt[feed] = Date()
        var request: URLRequest
        switch feed {
        case bing: request = URLRequest(url: URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-IN")!)
        case reddit: request = RedditLibrary.request("/r/wallpaper+wallpapers+widescreenwallpaper/top.json?t=week&limit=100&raw_json=1", cookie: redditCookie ?? "")
        default: request = URLRequest(url: wallhavenURL(query: query, anime: feed == anime))
        }
        URLSession.shared.dataTask(with: request) { [self] data, response, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let wallpapers = feed == bing ? bingWallpapers(json) : feed == reddit ? RedditLibrary.wallpapers(from: json) : wallhavenWallpapers(json)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let loggedOut = feed == reddit && [401, 403].contains(status)
            DispatchQueue.main.async { [self] in
                feedErrors[feed] = status == 200 ? nil : "\(feed.components(separatedBy: " · ")[0]) answered \(status == 0 ? "nothing, check the network" : "HTTP \(status)")"
                if loggedOut {
                    redditExpired = true
                    redditProblem = feedErrors[feed]
                }
                if wallpapers.isEmpty && query == nil { fetchedAt[feed] = Date().addingTimeInterval(-6 * 3600 + 60) }
                feeds[feed] = wallpapers
                changed()
                loadThumbnails(of: wallpapers)
            }
        }.resume()
    }

    private func loadThumbnails(of wallpapers: [Wallpaper]) {
        let missing = wallpapers.filter { picturesAsked.insert($0.id).inserted }
        guard !missing.isEmpty else { return }
        let loaded = DispatchGroup()
        for wallpaper in missing {
            loaded.enter()
            URLSession.shared.dataTask(with: wallpaper.thumbnail) { [self] data, _, _ in
                let picture = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { [self] in
                    pictures[wallpaper.id] = picture
                    loaded.leave()
                }
            }.resume()
        }
        loaded.notify(queue: .main) { [self] in changed() }
    }

    private func wallhavenURL(query: String?, anime: Bool) -> URL {
        let screen = NSScreen.screens.reduce(CGSize.zero) { size, screen in
            CGSize(width: max(size.width, screen.frame.width * screen.backingScaleFactor), height: max(size.height, screen.frame.height * screen.backingScaleFactor))
        }
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/search")!
        components.queryItems = [URLQueryItem(name: "atleast", value: "\(Int(screen.width))x\(Int(screen.height))"),
                                 URLQueryItem(name: "ratios", value: "16x10,16x9"), URLQueryItem(name: "purity", value: "100"),
                                 URLQueryItem(name: "categories", value: anime ? "010" : "100")]
            + (query.map { [URLQueryItem(name: "q", value: $0), URLQueryItem(name: "sorting", value: "relevance"), URLQueryItem(name: "categories", value: "110")] }
               ?? [URLQueryItem(name: "sorting", value: "toplist"), URLQueryItem(name: "topRange", value: "1w")])
        components.queryItems = Dictionary(components.queryItems!.map { ($0.name, $0) }) { _, last in last }.values.sorted { $0.name < $1.name }
        return components.url!
    }

    private func wallhavenWallpapers(_ json: [String: Any]) -> [Wallpaper] {
        (json["data"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["id"] as? String, let path = (entry["path"] as? String).flatMap(URL.init(string:)),
                  let thumbnail = ((entry["thumbs"] as? [String: String])?["large"]).flatMap(URL.init(string:)) else { return nil }
            let resolution = (entry["resolution"] as? String ?? "").replacingOccurrences(of: "x", with: " × ")
            let width = Double(entry["dimension_x"] as? Int ?? 0)
            let kind = ["anime": "anime", "people": "people"][entry["category"] as? String ?? ""] ?? "wallpaper"
            let site = (entry["source"] as? String).flatMap { URL(string: $0)?.host }?.replacingOccurrences(of: "www.", with: "") ?? "Wallhaven"
            let bytes = Int64(entry["file_size"] as? Int ?? 0)
            return Wallpaper(id: "wallhaven-\(id)", title: "\(Int((width / 1000).rounded()))K \(kind)",
                             detail: "\(resolution) · \(entry["favorites"] as? Int ?? 0) favourites · \(site)",
                             size: bytes.formatted(.byteCount(style: .file)), thumbnail: thumbnail, full: path)
        }
    }

    private func bingWallpapers(_ json: [String: Any]) -> [Wallpaper] {
        (json["images"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let base = entry["urlbase"] as? String, let id = base.components(separatedBy: "OHR.").last,
                  let full = URL(string: "https://www.bing.com\(base)_UHD.jpg"), let thumbnail = URL(string: "https://www.bing.com\(base)_800x480.jpg") else { return nil }
            let credit = (entry["copyright"] as? String ?? "")
            let title = entry["title"] as? String ?? credit.components(separatedBy: " (").first ?? id
            return Wallpaper(id: "bing-\(id)", title: title.isEmpty ? credit : title, detail: credit, size: "3840 × 2160", thumbnail: thumbnail, full: full)
        }
    }

    private func apply(_ wallpaper: Wallpaper) {
        let file = folder.appendingPathComponent(wallpaper.id + "." + (wallpaper.full.pathExtension.isEmpty ? "jpg" : wallpaper.full.pathExtension))
        guard !FileManager.default.fileExists(atPath: file.path) else { return setWallpaper(file) }
        downloading = wallpaper.id
        failures[wallpaper.id] = nil
        changed()
        URLSession.shared.downloadTask(with: wallpaper.full) { [self] downloaded, response, error in
            var failure = error?.localizedDescription
            if let downloaded, (response as? HTTPURLResponse)?.statusCode == 200 {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: downloaded, to: file)
                } catch { failure = error.localizedDescription }
            } else if failure == nil {
                failure = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            DispatchQueue.main.async { [self] in
                downloading = nil
                if let failure { failures[wallpaper.id] = "Failed: \(failure)" } else { setWallpaper(file) }
                changed()
            }
        }.resume()
    }

    private func setWallpaper(_ file: URL) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
        for screen in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options) }
        changed()
    }

    private func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func changed() {
        NotificationCenter.default.post(name: .pageChanged, object: self)
    }
}
