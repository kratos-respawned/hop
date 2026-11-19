import Foundation

struct Worktree: Codable {
    let folder: String
    let repo: String
    let branch: String
    let isMainCheckout: Bool

    var name: String { isMainCheckout ? repo : ((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent }
}

struct Artifact: Codable {
    let name: String
    let folders: [String]
    let size: Int64
}

enum MergeStatus: String, Codable {
    case uncommitted = "Local edits"
    case notMerged = "Not merged"
    case inUAT = "In uat"
    case inMain = "In main"
    case uncommittedInUAT = "In uat + local edits"
    case uncommittedInMain = "In main + local edits"
}

struct Activity: Codable {
    let lastUsed: Date
    let unpushedCommits: Int
}

struct FolderSizes: Codable {
    let total: Int64
    let artifacts: [Artifact]
}

enum WorkFolder {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/work").path
    private static let trash = root + "/.hop-trash"
    private static let artifactNames: Set<String> = ["node_modules", ".next", "dist", "build", "out", ".turbo", ".gradle", ".kotlin", ".cxx", "coverage", ".expo", "Pods"]
    private static let noPrompts = ["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes"]

    static func worktrees() -> [Worktree] {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        let repos = folders.filter { FileManager.default.fileExists(atPath: "\(root)/\($0)/.git/HEAD") }
        return repos.sorted().flatMap(worktrees(of:))
    }

    private static func worktrees(of repo: String) -> [Worktree] {
        let listing = git(["worktree", "list", "--porcelain"], in: "\(root)/\(repo)")
        return listing.components(separatedBy: "\n\n").enumerated().compactMap { index, block in
            let lines = block.split(separator: "\n").map(String.init)
            guard let folder = lines.first?.replacingOccurrences(of: "worktree ", with: ""),
                  !lines.contains(where: { $0.hasPrefix("prunable") }) else { return nil }
            let branch = lines.first { $0.hasPrefix("branch ") }?.replacingOccurrences(of: "branch refs/heads/", with: "") ?? "detached"
            return Worktree(folder: folder, repo: repo, branch: branch, isMainCheckout: index == 0)
        }
    }

    static func fetch(_ repo: String) {
        git(["fetch", "--quiet", "origin"], in: "\(root)/\(repo)")
    }

    static func status(of worktree: Worktree) -> MergeStatus {
        let isDirty = !git(["status", "--porcelain"], in: worktree.folder).isEmpty
        let bases: [(String, MergeStatus, MergeStatus)] = [("origin/main", .inMain, .uncommittedInMain), ("origin/uat", .inUAT, .uncommittedInUAT)]
        for (base, clean, dirty) in bases {
            let baseTree = git(["rev-parse", "--verify", "--quiet", "\(base)^{tree}"], in: worktree.folder)
            let mergedTree = git(["merge-tree", "--write-tree", base, "HEAD"], in: worktree.folder).split(separator: "\n").first
            if !baseTree.isEmpty && mergedTree.map(String.init) == baseTree { return isDirty ? dirty : clean }
        }
        return isDirty ? .uncommitted : .notMerged
    }

    static func activity(of worktree: Worktree) -> Activity {
        let folder = worktree.folder
        let headMoved = Double(git(["log", "-g", "-1", "--format=%ct", "HEAD"], in: folder)) ?? Double(git(["log", "-1", "--format=%ct"], in: folder)) ?? 0
        let lastEdit = git(["status", "--porcelain"], in: folder).split(separator: "\n").map { line in
            let path = line.dropFirst(3).components(separatedBy: " -> ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
            return (try? FileManager.default.attributesOfItem(atPath: "\(folder)/\(path)"))?[.modificationDate] as? Date ?? .distantPast
        }.max() ?? .distantPast
        let unpushed = Int(git(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: folder)) ?? 0
        return Activity(lastUsed: max(Date(timeIntervalSince1970: headMoved), lastEdit), unpushedCommits: unpushed)
    }

    static func sizes(of worktree: Worktree) -> FolderSizes {
        let ignored = git(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"], in: worktree.folder)
        let artifactPaths = ignored.split(separator: "\n").filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }
            .filter { artifactNames.contains(($0 as NSString).lastPathComponent) }
        let deepest = artifactPaths.map { $0.split(separator: "/").count }.max() ?? 0
        var sizeByFolder: [String: Int64] = [:]
        for line in run("/usr/bin/du", ["-k", "-d", "\(deepest)", worktree.folder]).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, let kilobytes = Int64(parts[0]) { sizeByFolder[String(parts[1])] = kilobytes * 1024 }
        }
        let artifacts = Dictionary(grouping: artifactPaths) { ($0 as NSString).lastPathComponent }.map { name, paths in
            let folders = paths.map { "\(worktree.folder)/\($0)" }
            return Artifact(name: name, folders: folders, size: folders.reduce(0) { $0 + (sizeByFolder[$1] ?? 0) })
        }
        return FolderSizes(total: sizeByFolder[worktree.folder] ?? 0, artifacts: artifacts.sorted { $0.size > $1.size })
    }

    static func clear(_ artifact: Artifact) -> Bool {
        artifact.folders.map(moveToTrash).allSatisfy { $0 }
    }

    static func delete(_ worktree: Worktree) -> Bool {
        guard moveToTrash(worktree.folder) else { return false }
        git(["worktree", "prune"], in: "\(root)/\(worktree.repo)")
        let project = (worktree.folder as NSString).deletingLastPathComponent
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: project)) ?? []
        if project != root && leftovers.allSatisfy({ $0 == ".DS_Store" }) { _ = moveToTrash(project) }
        return true
    }

    // Renaming is instant, so the list updates at once while rm works through node_modules in the background.
    private static func moveToTrash(_ folder: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        guard (try? FileManager.default.moveItem(atPath: folder, toPath: "\(trash)/\(UUID().uuidString)")) != nil else { return false }
        let remove = Process()
        remove.executableURL = URL(fileURLWithPath: "/bin/rm")
        remove.arguments = ["-rf", trash]
        try? remove.run()
        return true
    }

    @discardableResult
    private static func git(_ arguments: [String], in folder: String) -> String {
        run("/usr/bin/git", ["-C", folder] + arguments)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(noPrompts) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
