import AppKit
import UserNotifications

final class SetupPlugin: Plugin, Page {
    let name = "Set Up Hop"
    let icon = tile("sparkles", .systemPink)
    let placeholder = "Set up Hop"
    let actionName = "Continue"
    var hasPreview: Bool { true }
    private enum Step { case permissions, missing, accounts }
    private var step = Step.permissions
    private var notificationsAllowed = false
    private var claudeReady = false
    private var notice = ""
    private var watcher: Timer?

    static var isDone: Bool { UserDefaults.standard.bool(forKey: "setupDone") }

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
    }

    func willShow() {
        UNUserNotificationCenter.current().getNotificationSettings { [self] settings in
            DispatchQueue.main.async { [self] in
                notificationsAllowed = [.authorized, .provisional].contains(settings.authorizationStatus)
                changed()
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let claude = ClaudeSignIn.antPath.flatMap(ClaudeSignIn.token) != nil
            DispatchQueue.main.async { [self] in
                claudeReady = claude
                changed()
            }
        }
    }

    func search(_ query: String) -> [Item] {
        let rows = switch step {
        case .permissions: permissionRows
        case .missing: missingRows
        case .accounts: accountRows
        }
        return rows.filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }
    }

    private var accessibilityAllowed: Bool { AXIsProcessTrusted() }

    private var permissionRows: [Item] {
        let permissions = [
            permission("Accessibility", allowed: accessibilityAllowed, symbol: "hand.raised.fill", color: .systemBlue,
                       detail: "Lets Hop paste into the app you're using with ⌘↵ from clipboard history, and read and replace selected text for Write with AI. Hop can't see anything else through it.",
                       allow: { [self] in allowAccessibility() }),
            permission("Notifications", allowed: notificationsAllowed, symbol: "bell.badge.fill", color: .systemRed,
                       detail: "Tells you when a download finishes, the morning digest is ready or a process runs hot.",
                       allow: { [self] in allowNotifications() }),
        ].sorted { !$0.allowed && $1.allowed }.map(\.item)
        let allAllowed = accessibilityAllowed && notificationsAllowed
        let next = Item(title: "Continue", subtitle: allAllowed ? "Everything is allowed" : "Press Enter on a permission above to allow it",
                        preview: .rich(text("Welcome to Hop", ["Hop needs two permissions for some of its features. Press Enter on each one to allow it, macOS asks you to confirm.", "Everything else works without them."])),
                        section: "Welcome to Hop", opens: self, icon: { tile("arrow.right.circle.fill", .systemGreen) },
                        run: { [self] in step = allAllowed ? .accounts : .missing })
        return allAllowed ? [next] + permissions : permissions + [next]
    }

    private func permission(_ title: String, allowed: Bool, symbol: String, color: NSColor, detail: String, allow: @escaping () -> Void) -> (allowed: Bool, item: Item) {
        (allowed, Item(title: title, subtitle: allowed ? "Allowed" : "Press Enter to allow", badge: allowed ? "Allowed" : "Not allowed", action: allowed ? "" : "Allow",
                       preview: .rich(text(title, [detail])), section: "Permissions",
                       icon: { allowed ? tile("checkmark.circle.fill", .systemGreen) : tile(symbol, color) }, run: allowed ? nil : allow))
    }

    private var missingRows: [Item] {
        var lost: [String] = []
        if !accessibilityAllowed { lost.append("Without Accessibility, ⌘↵ in clipboard history only copies instead of pasting, and Write with AI can't read or replace selected text.") }
        if !notificationsAllowed { lost.append("Without notifications, Hop can't tell you when downloads finish, the digest is ready or a process runs hot.") }
        let warning = NSMutableAttributedString()
        warning.append(DigestCard.attached(DigestCard.callout("Some features won't work", symbol: "exclamationmark.triangle.fill", color: .systemOrange)))
        warning.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        warning.append(text(nil, lost + ["You can allow them later from Set Up Hop or System Settings, Privacy & Security."]))
        return [
            Item(title: "Go back and allow them", subtitle: "Recommended", preview: .rich(warning), section: "Some features won't work", opens: self,
                 icon: { tile("arrow.uturn.backward.circle.fill", .systemBlue) }, run: { [self] in step = .permissions }),
            Item(title: "Continue without them", subtitle: lost.count == 2 ? "Pasting, AI writing and notifications won't work" : lost.first ?? "",
                 preview: .rich(warning), section: "Some features won't work", opens: self,
                 icon: { tile("arrow.right.circle", .systemGray) }, run: { [self] in step = .accounts }),
        ]
    }

    private var accountRows: [Item] {
        let claudeCommand = ClaudeSignIn.antPath == nil ? "brew install anthropics/tap/ant && ant auth login" : "ant auth login"
        return [
            Item(title: "Claude", subtitle: claudeReady ? "Signed in" : notice.isEmpty ? "Press Enter to copy the sign-in command" : notice,
                 badge: claudeReady ? "Signed in" : "Not set up", action: claudeReady ? "" : "Copy Command",
                 preview: .rich(text("Claude", ["Writes the morning digest, and Write with AI when Claude is the AI engine.", "Press Enter to copy the command, run it in Terminal and sign in, then open Set Up Hop again.", claudeCommand])),
                 section: "Connect accounts, all optional", opens: self, icon: { tile("brain.head.profile", .systemOrange) },
                 run: claudeReady ? nil : { [self] in
                     NSPasteboard.general.clearContents()
                     NSPasteboard.general.setString(claudeCommand, forType: .string)
                     notice = "Copied. Paste it in Terminal and sign in"
                 }),
            AIEngine.settingRow(opens: self),
            Item(title: claudeReady ? "Finish setup" : "Skip for now", subtitle: "You can come back any time by searching Set Up Hop",
                 section: "Done", icon: { tile("checkmark.circle.fill", .systemGreen) },
                 run: { [self] in
                     UserDefaults.standard.set(true, forKey: "setupDone")
                     step = .permissions
                     notice = ""
                 }),
        ]
    }

    private func allowAccessibility() {
        UserDefaults.standard.set(true, forKey: "askedAccessibility")
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        watchUntilAllowed()
    }

    private func allowNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [self] granted, _ in
            DispatchQueue.main.async { [self] in
                notificationsAllowed = granted
                if granted { return launcher.isShowing ? changed() : launcher.toggle(self) }
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        }
    }

    // macOS doesn't announce an Accessibility grant, so check while the user is in System Settings.
    private func watchUntilAllowed() {
        watcher?.invalidate()
        var checks = 0
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] timer in
            checks += 1
            guard AXIsProcessTrusted() || checks > 120 else { return }
            timer.invalidate()
            if AXIsProcessTrusted() { launcher.isShowing ? changed() : launcher.toggle(self) }
        }
    }

    private func text(_ title: String?, _ paragraphs: [String]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 10
        let result = NSMutableAttributedString()
        let lines = (title.map { [($0, true)] } ?? []) + paragraphs.map { ($0, false) }
        for (index, (line, isTitle)) in lines.enumerated() {
            result.append(NSAttributedString(string: line + (index == lines.count - 1 ? "" : "\n"), attributes: [
                .font: isTitle ? NSFont.systemFont(ofSize: 15, weight: .semibold) : NSFont.systemFont(ofSize: 13),
                .foregroundColor: isTitle ? NSColor.labelColor : NSColor.secondaryLabelColor, .paragraphStyle: style]))
        }
        return result
    }

    private func changed() {
        NotificationCenter.default.post(name: .pageChanged, object: self)
    }
}
