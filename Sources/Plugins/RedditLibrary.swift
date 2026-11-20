import Foundation

final class RedditLibrary {
    private(set) var wallpapers: [Wallpaper] = []
    private(set) var isBuilding = false
    private var builtAt = Date.distantPast
    private let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Hop/reddit-library.json")
    private static let groups = [("wallpaper", "wallpaper+wallpapers+widescreenwallpaper+WQHD_Wallpaper"), ("nature landscape", "EarthPorn+SkyPorn"),
                                 ("space art fantasy", "spaceporn+ImaginaryLandscapes"), ("anime", "Animewallpaper")]
    private static let lists = [("year", 3), ("all", 3), ("month", 1)]

    private struct Saved: Codable {
        let builtAt: Date
        let wallpapers: [Wallpaper]
    }

    func load() {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let saved = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(Saved.self, from: $0) }) else { return }
            DispatchQueue.main.async { [self] in
                builtAt = saved.builtAt
                wallpapers = saved.wallpapers + wallpapers
            }
        }
    }

    func matches(_ text: String) -> [Wallpaper] {
        let words = text.lowercased().split(separator: " ").map { $0.count > 3 && $0.hasSuffix("s") ? $0.dropLast() : $0 }
        return wallpapers.filter { wallpaper in
            let tokens = (wallpaper.title + " " + wallpaper.keywords).lowercased().split { !$0.isLetter && !$0.isNumber }
            return words.allSatisfy { word in tokens.contains { $0.hasPrefix(word) } }
        }
    }

    func refresh(cookie: String, onChange: @escaping (_ loggedOut: Bool) -> Void) {
        guard !isBuilding, Date().timeIntervalSince(builtAt) > 24 * 3600 else { return }
        isBuilding = true
        DispatchQueue.global(qos: .utility).async { [self] in
            var loggedOut = false
            scrape: for (keywords, subreddits) in Self.groups {
                for (range, pages) in Self.lists {
                    var after = ""
                    for _ in 0..<pages {
                        let (body, status) = Self.get("/r/\(subreddits)/top.json?t=\(range)&limit=100&raw_json=1&after=\(after)", cookie: cookie)
                        if [401, 403].contains(status) {
                            loggedOut = true
                            break scrape
                        }
                        let json = body as? [String: Any] ?? [:]
                        let found = Self.wallpapers(from: json, keywords: keywords)
                        DispatchQueue.main.async { [self] in
                            wallpapers = unique(wallpapers + found)
                            onChange(false)
                        }
                        after = (json["data"] as? [String: Any])?["after"] as? String ?? ""
                        if after.isEmpty { break }
                        Thread.sleep(forTimeInterval: 1)
                    }
                }
            }
            DispatchQueue.main.async { [self] in
                isBuilding = false
                if !loggedOut { builtAt = Date() }
                save()
                onChange(loggedOut)
            }
        }
    }

    static func request(_ path: String, cookie: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.reddit.com" + path)!)
        request.setValue("reddit_session=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("macos:hop:0.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func wallpapers(from json: [String: Any], keywords: String = "") -> [Wallpaper] {
        let posts = ((json["data"] as? [String: Any])?["children"] as? [[String: Any]] ?? []).compactMap { $0["data"] as? [String: Any] }
        return posts.compactMap { post in
            guard post["post_hint"] as? String == "image", let id = post["id"] as? String,
                  let full = (post["url"] as? String).flatMap(URL.init(string:)),
                  let image = ((post["preview"] as? [String: Any])?["images"] as? [[String: Any]])?.first,
                  let source = image["source"] as? [String: Any], let width = source["width"] as? Int, let height = source["height"] as? Int,
                  width >= 2560, width > height,
                  let thumbnail = ((image["resolutions"] as? [[String: Any]])?.first { $0["width"] as? Int ?? 0 >= 640 }?["url"] as? String).flatMap(URL.init(string:))
            else { return nil }
            let subreddit = post["subreddit"] as? String ?? ""
            return Wallpaper(id: "reddit-\(id)", title: post["title"] as? String ?? id,
                             detail: "r/\(subreddit) · \((post["ups"] as? Int ?? 0).formatted()) upvotes",
                             size: "\(width) × \(height)", thumbnail: thumbnail, full: full, nsfw: post["over_18"] as? Bool ?? false,
                             keywords: [keywords, subreddit, post["link_flair_text"] as? String ?? ""].joined(separator: " "))
        }
    }

    static func get(_ path: String, cookie: String) -> (body: Any?, status: Int) {
        let done = DispatchSemaphore(value: 0)
        var result: (body: Any?, status: Int) = (nil, 0)
        var wait = 0.0
        URLSession.shared.dataTask(with: request(path, cookie: cookie)) { data, response, _ in
            let response = response as? HTTPURLResponse
            result = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }, response?.statusCode ?? 0)
            if Double(response?.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "") ?? 99 < 2 || result.status == 429 {
                wait = (Double(response?.value(forHTTPHeaderField: "x-ratelimit-reset") ?? "") ?? 60) + 1
            }
            done.signal()
        }.resume()
        done.wait()
        guard wait > 0 else { return result }
        Thread.sleep(forTimeInterval: wait)
        return result.status == 429 ? get(path, cookie: cookie) : result
    }

    private func unique(_ wallpapers: [Wallpaper]) -> [Wallpaper] {
        var seen = Set<String>()
        return wallpapers.filter { seen.insert($0.id).inserted }
    }

    private func save() {
        let saved = Saved(builtAt: builtAt, wallpapers: wallpapers)
        DispatchQueue.global(qos: .utility).async { [file] in
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
        }
    }
}
