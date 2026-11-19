import Foundation

final class KeepAwake {
    private(set) var isOn = false
    private let marker = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hop/keep-awake")
    private static let pmset = "/usr/bin/pmset"
    private static let commandsAllowedWithoutPassword = ["\(pmset) -a disablesleep 1", "\(pmset) -a disablesleep 0", "\(pmset) sleepnow"]

    init() {
        try? FileManager.default.removeItem(at: marker)
    }

    func start(_ done: @escaping (Bool) -> Void) {
        if isOn || turnOn() { return done(true) }
        allowWithoutPassword { [self] allowed in done(allowed && turnOn()) }
    }

    func stop() {
        isOn = false
        try? FileManager.default.removeItem(at: marker)
    }

    private func turnOn() -> Bool {
        guard shell("sudo -n \(Self.pmset) -a disablesleep 1", waits: true) == 0 else { return false }
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        restoreSleepOnceStopped()
        isOn = true
        return true
    }

    // A separate process, so sleep comes back even if Hop crashes while the lid is closed.
    private func restoreSleepOnceStopped() {
        let waitForStop = "while [ -e '\(marker.path)' ] && kill -0 \(getpid()) 2>/dev/null; do sleep 5; done"
        let restoreSleep = "sudo -n \(Self.pmset) -a disablesleep 0"
        let sleepIfLidClosed = "ioreg -r -k AppleClamshellState -d 4 | grep -q '\"AppleClamshellState\" = Yes' && sudo -n \(Self.pmset) sleepnow"
        shell("\(waitForStop); \(restoreSleep); \(sleepIfLidClosed)", waits: false)
    }

    private func allowWithoutPassword(_ done: @escaping (Bool) -> Void) {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: \(Self.commandsAllowedWithoutPassword.joined(separator: ", "))"
        let install = "rule=$(mktemp) && echo '\(rule)' > $rule && visudo -cf $rule && install -m 0440 -o root -g wheel $rule /etc/sudoers.d/hop; installed=$?; rm -f $rule; exit $installed"
        let escaped = install.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        osascript.terminationHandler = { process in
            DispatchQueue.main.async { done(process.terminationStatus == 0) }
        }
        do { try osascript.run() } catch { done(false) }
    }

    @discardableResult
    private func shell(_ command: String, waits: Bool) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        guard waits else { return 0 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
