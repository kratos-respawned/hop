import Foundation

/// Reddit blocks apps from reading it, so Masks reads it on a schedule in its signed-in agents mask and Hop reads what Masks saved.
enum MasksCron {
    struct Entry {
        let attributes: [String: String]
        let text: String
    }

    struct Run {
        let ranAt: Date
        let passed: Bool
        let entries: [Entry]
        let failure: String?
    }

    static func latest(_ name: String) -> Run? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/masks/crons/\(name)/latest.json")
        guard let json = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let ranAt = (json["ranAt"] as? String).flatMap(ISO8601DateFormatter().date(from:)) else { return nil }
        let lists = (json["results"] as? [Any] ?? []).compactMap { $0 as? [[String: Any]] }
        let entries = lists.joined().map { Entry(attributes: $0["attributes"] as? [String: String] ?? [:], text: $0["text"] as? String ?? "") }
        let failure = (json["log"] as? String)?.components(separatedBy: "\n").first { $0.hasPrefix("     ") }?.trimmingCharacters(in: .whitespaces)
        return Run(ranAt: ranAt, passed: json["passed"] as? Bool ?? false, entries: entries, failure: failure)
    }

    static func problem(_ name: String, _ run: Run?, every hours: Int) -> String? {
        guard let run else { return "Masks hasn't read Reddit yet. Keep Masks open, its \(name) job runs every \(hours) hours" }
        guard run.passed || !run.entries.isEmpty else { return "Masks couldn't read Reddit: \(run.failure ?? "its \(name) job failed")" }
        return nil
    }
}

final class RedditLibrary {
    static let cron = "hop-reddit-wallpapers"
    private(set) var wallpapers: [Wallpaper] = []
    private(set) var thisWeek: [Wallpaper] = []
    private(set) var problem: String?
    private var readRun: Date?
    private var isReading = false
    private static let keywords = ["wallpaper": "wallpaper", "wallpapers": "wallpaper", "widescreenwallpaper": "wallpaper",
                                   "earthporn": "nature landscape", "skyporn": "nature landscape sky",
                                   "spaceporn": "space", "imaginarylandscapes": "art fantasy", "animewallpaper": "anime"]

    func matches(_ text: String) -> [Wallpaper] {
        let words = text.lowercased().split(separator: " ").map { $0.count > 3 && $0.hasSuffix("s") ? $0.dropLast() : $0 }
        return wallpapers.filter { wallpaper in
            let tokens = (wallpaper.title + " " + wallpaper.keywords).lowercased().split { !$0.isLetter && !$0.isNumber }
            return words.allSatisfy { word in tokens.contains { $0.hasPrefix(word) } }
        }
    }

    func refresh(onChange: @escaping () -> Void) {
        guard !isReading else { return }
        isReading = true
        DispatchQueue.global(qos: .utility).async { [self] in
            let run = MasksCron.latest(Self.cron)
            let changed = run?.ranAt != readRun
            let posts = changed ? run.map { Self.posts(in: $0.entries) } : nil
            DispatchQueue.main.async { [self] in
                isReading = false
                problem = MasksCron.problem(Self.cron, run, every: 8)
                guard changed else { return }
                readRun = run?.ranAt
                if let posts {
                    wallpapers = posts.map(\.wallpaper)
                    let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
                    thisWeek = posts.filter { $0.created > weekAgo && $0.wallpaper.keywords.hasPrefix("wallpaper ") }.sorted { $0.score > $1.score }.map(\.wallpaper)
                }
                onChange()
            }
        }
    }

    private static func posts(in entries: [MasksCron.Entry]) -> [(wallpaper: Wallpaper, created: Date, score: Int)] {
        var previews: [String: URL] = [:]
        for entry in entries {
            if let src = entry.attributes["src"], let id = imageID(in: src), previews[id] == nil { previews[id] = URL(string: src) }
        }
        var seen = Set<String>()
        let dates = ISO8601DateFormatter()
        return entries.compactMap { entry in
            let post = entry.attributes
            guard post["post-type"] == "image", let id = post["id"]?.replacingOccurrences(of: "t3_", with: ""), seen.insert(id).inserted,
                  let title = post["post-title"], let full = post["content-href"].flatMap(URL.init(string:)),
                  let thumbnail = imageID(in: full.absoluteString).flatMap({ previews[$0] }),
                  let size = resolution(in: title), size.width >= 2560, size.width > size.height else { return nil }
            let subreddit = post["subreddit-name"] ?? ""
            let score = Int(post["score"] ?? "") ?? 0
            let wallpaper = Wallpaper(id: "reddit-\(id)", title: title, detail: "r/\(subreddit) · \(score.formatted()) upvotes",
                                      size: "\(size.width) × \(size.height)", thumbnail: thumbnail, full: full, nsfw: post["nsfw"] != nil,
                                      keywords: "\(keywords[subreddit.lowercased()] ?? "") \(subreddit)")
            let created = post["created-timestamp"].flatMap { dates.date(from: $0.prefix(19) + "Z") } ?? .distantPast
            return (wallpaper, created, score)
        }
    }

    /// i.redd.it/<id>.png and its signed preview, preview.redd.it/<title>-v0-<id>.png, share the image id.
    private static func imageID(in link: String) -> String? {
        link.range(of: #"(?<=-v0-|/)[a-z0-9]{8,}(?=\.(png|jpe?g|webp))"#, options: .regularExpression).map { String(link[$0]) }
    }

    private static func resolution(in title: String) -> (width: Int, height: Int)? {
        guard let found = title.range(of: #"\d{3,5} ?[x×X] ?\d{3,5}"#, options: .regularExpression) else { return nil }
        let numbers = title[found].split { !$0.isNumber }.compactMap { Int($0) }
        return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
    }
}
