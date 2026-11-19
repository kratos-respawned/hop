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
        if isOn { return done(true) }
        turnOn { [self] started in
            if started { return done(true) }
            allowWithoutPassword { [self] allowed in allowed ? turnOn(done) : done(false) }
        }
    }

    func stop() {
        isOn = false
        try? FileManager.default.removeItem(at: marker)
    }

    private func turnOn(_ done: @escaping (Bool) -> Void) {
        shell("sudo -n \(Self.pmset) -a disablesleep 1") { [self] status in
            guard status == 0 else { return done(false) }
            FileManager.default.createFile(atPath: marker.path, contents: nil)
            restoreSleepOnceStopped()
            isOn = true
            done(true)
        }
    }

    // A separate process, so sleep comes back even if Hop crashes while the lid is closed.
    private func restoreSleepOnceStopped() {
        let waitForStop = "while [ -e '\(marker.path)' ] && kill -0 \(getpid()) 2>/dev/null; do sleep 5; done"
        let restoreSleep = "sudo -n \(Self.pmset) -a disablesleep 0"
        let sleepIfLidClosed = "ioreg -r -k AppleClamshellState -d 4 | grep -q '\"AppleClamshellState\" = Yes' && sudo -n \(Self.pmset) sleepnow"
        shell("\(waitForStop); \(restoreSleep); \(sleepIfLidClosed)")
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

    private func shell(_ command: String, finished: ((Int32) -> Void)? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { ended in DispatchQueue.main.async { finished?(ended.terminationStatus) } }
        if (try? process.run()) == nil { finished?(-1) }
    }
}
