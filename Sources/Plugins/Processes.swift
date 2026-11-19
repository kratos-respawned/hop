import Darwin
import Foundation

struct RunningProcess {
    let pid: pid_t
    let name: String
    let appPath: String?
    let memory: UInt64
    let cpuTime: UInt64
    let energy: UInt64
    var cpu: Double = 0
    var watts: Double = 0

    var group: String { appPath ?? name }
}

struct RunningApp {
    let name: String
    let appPath: String?
    let processes: [RunningProcess]
    let memory: UInt64
    let cpu: Double
    let watts: Double

    var key: String { appPath ?? name }

    init(_ processes: [RunningProcess]) {
        let first = processes[0]
        appPath = first.appPath
        name = first.appPath.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") } ?? first.name
        self.processes = processes.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
        memory = processes.reduce(0) { $0 + $1.memory }
        cpu = processes.reduce(0) { $0 + $1.cpu }
        watts = processes.reduce(0) { $0 + $1.watts }
    }
}

enum ProcessTable {
    private static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()
    private static let host = mach_host_self()
    private static var identities: [pid_t: (name: String, appPath: String?)] = [:]
    private static var pids = [pid_t](repeating: 0, count: 8192)

    static func snapshot() -> [RunningProcess] {
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let processes = pids.prefix(max(count, 0)).compactMap(process)
        let alive = Set(processes.map(\.pid))
        identities = identities.filter { alive.contains($0.key) }
        return processes
    }

    static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let appPages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        return (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(vm_kernel_page_size)
    }

    private static func process(_ pid: pid_t) -> RunningProcess? {
        var usage = rusage_info_v6()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard pid > 0, read == 0 else { return nil }
        let identity = identities[pid] ?? identify(pid)
        identities[pid] = identity
        let cpuTicks = Double(usage.ri_user_time + usage.ri_system_time)
        return RunningProcess(pid: pid, name: identity.name, appPath: identity.appPath, memory: usage.ri_phys_footprint, cpuTime: UInt64(cpuTicks * nanosecondsPerTick), energy: usage.ri_energy_nj)
    }

    static func workingFolder(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let folder = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return folder == "/" ? nil : folder
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func arguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: 8192)
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        let afterPath = buffer[MemoryLayout<Int32>.size..<size].drop { $0 != 0 }.drop { $0 == 0 }
        return afterPath.split(separator: 0, omittingEmptySubsequences: false).prefix(count).map { String(decoding: $0, as: UTF8.self) }
    }

    static func executableName(_ pid: pid_t) -> String {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? (String(cString: pathBuffer) as NSString).lastPathComponent : ""
    }

    static func identify(_ pid: pid_t) -> (name: String, appPath: String?) {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : ""
        let appPath = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
        return (appPath == nil ? commandName(pid, path: path) : kernelName(pid), appPath)
    }

    private static func kernelName(_ pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        return String(cString: name)
    }

    // argv[0], not the executable file name: Claude's binary is named after its version (2.1.328).
    private static func commandName(_ pid: pid_t, path: String) -> String {
        if let first = arguments(pid).first, !first.isEmpty { return (first as NSString).lastPathComponent }
        return path.isEmpty ? kernelName(pid) : (path as NSString).lastPathComponent
    }
}
