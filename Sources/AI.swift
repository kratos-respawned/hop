import AppKit
import Carbon
import FoundationModels

struct AIError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum AIEngine: String {
    case apple, claude

    static var appleAvailable: Bool {
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        return false
    }

    static var current: AIEngine {
        AIEngine(rawValue: UserDefaults.standard.string(forKey: "aiEngine") ?? "") ?? (appleAvailable ? .apple : .claude)
    }

    var name: String { self == .apple ? "Apple Intelligence" : "Claude" }

    func write(instructions: String, text: String, quick: Bool = false) async throws -> String {
        switch self {
        case .claude: return try await ClaudeSignIn.write(instructions: instructions, text: text, model: quick ? "claude-haiku-5-5" : "claude-sonnet-5-5")
        case .apple:
            guard #available(macOS 26, *) else { throw AIError("Apple Intelligence needs macOS 26, pick Claude in Settings") }
            return try await Self.writeOnDevice(instructions: instructions, text: text)
        }
    }

    @available(macOS 26, *)
    private static func writeOnDevice(instructions: String, text: String) async throws -> String {
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            switch reason {
            case .appleIntelligenceNotEnabled: throw AIError("Turn on Apple Intelligence in System Settings, or pick Claude in Settings")
            case .deviceNotEligible: throw AIError("This Mac can't run Apple Intelligence, pick Claude in Settings")
            case .modelNotReady: throw AIError("Apple Intelligence is still downloading its model, try again later")
            @unknown default: throw AIError("Apple Intelligence isn't available, pick Claude in Settings")
            }
        }
        return try await LanguageModelSession(instructions: instructions).respond(to: text).content
    }

    static func settingRow(opens page: Page) -> Item {
        let engine = current
        let detail = """
            Write with AI uses \(engine.name). Press Enter to switch.

            Apple Intelligence runs on this Mac, free and private, and needs Apple Intelligence turned on in System Settings.\(appleAvailable ? "" : " It isn't available right now.")

            Claude writes better and needs the ant sign-in from Set Up Hop. Selected text goes to Anthropic.
            """
        return Item(title: "AI engine", subtitle: "Write with AI uses \(engine.name)", badge: engine.name, action: "Switch",
                    preview: .rich(NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])),
                    section: "AI", opens: page, icon: { tile("cpu", .systemPurple) },
                    run: { UserDefaults.standard.set(engine == .apple ? AIEngine.claude.rawValue : AIEngine.apple.rawValue, forKey: "aiEngine") })
    }
}

enum ClaudeSignIn {
    static var antPath: String? { ["/opt/homebrew/bin/ant", "/usr/local/bin/ant", NSHomeDirectory() + "/go/bin/ant"].first(where: FileManager.default.isExecutableFile) }

    static func token(_ ant: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ant)
        process.arguments = ["auth", "print-credentials", "--access-token"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let token = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return process.terminationStatus == 0 && !token.isEmpty ? token : nil
    }

    static func write(instructions: String, text: String, model: String) async throws -> String {
        guard let ant = antPath else { throw AIError("Claude isn't set up. Open Set Up Hop to sign in") }
        guard let token = await Task.detached(operation: { token(ant) }).value else { throw AIError("Claude sign-in ran out. Run ant auth login in Terminal") }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 8000, "system": instructions,
            "messages": [["role": "user", "content": text]],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            if status == 401 { throw AIError("Claude sign-in ran out. Run ant auth login in Terminal") }
            throw AIError("Claude answered HTTP \(status): \((json["error"] as? [String: Any])?["message"] as? String ?? "no details")")
        }
        let answer = ((json["content"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !answer.isEmpty else { throw AIError("Claude returned no text") }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func sendPaste() {
    guard AXIsProcessTrusted() else {
        if !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pressCommand(CGKeyCode(kVK_ANSI_V)) }
}

let hopKeyMark: Int64 = 0x484F50

func pressCommand(_ key: CGKeyCode) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
        event?.flags = .maskCommand
        event?.setIntegerValueField(.eventSourceUserData, value: hopKeyMark)
        event?.post(tap: .cghidEventTap)
    }
}
