import AppKit

/// Your processes, grouped by app, with memory measured the way Activity Monitor does
/// (physical footprint). Other users' and system processes can't be read without admin
/// rights, so they're counted but not listed.
final class ProcessTable {
    struct Member { let pid: pid_t; let start: UInt64 }

    struct Group {
        let key: String
        var name: String
        var kind: String            // "app" (grouped by .app bundle) or "process"
        var appPath: String?
        var detail: String?
        var members: [Member] = []
        var memory: Double = 0
        var cpu: Double = 0
        var started: Double = .infinity
        var protectedReason: String?
    }

    /// Interpreters get one row per process, labelled with their script, because "node" alone
    /// says nothing about which program it is.
    private static let interpreters: Set<String> = ["node", "python", "python3", "Python", "ruby", "java", "bun", "deno", "perl", "php"]
    private static let neverQuit: [String: String] = [
        "loginwindow": "Quitting it logs you out.",
        "WindowServer": "Quitting it logs you out.",
        "launchd": "Every other process depends on it.",
    ]

    private let uid = getuid()
    private let selfPid = getpid()
    private let includeIcons: Bool
    private var timebase = mach_timebase_info_data_t()
    private var previous: [pid_t: (start: UInt64, cpu: UInt64)] = [:]
    private var previousTime: UInt64 = 0
    private var descriptions: [String: (label: String, cwd: String?)] = [:]
    private var appNames: [String: String] = [:]
    private var iconCache: [String: String] = [:]
    private var iconsSent = Set<String>()
    private(set) var groups: [String: Group] = [:]

    init(includeIcons: Bool) {
        self.includeIcons = includeIcons
        mach_timebase_info(&timebase)
    }

    /// The page was reloaded and lost its icon cache.
    func resetIcons() { iconsSent.removeAll() }

    func snapshot() -> [String: Any] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let wall = previousTime == 0 ? 0 : Double(now - previousTime)
        var seen: [pid_t: (start: UInt64, cpu: UInt64)] = [:]
        var built: [String: Group] = [:]
        var liveDescriptions = Set<String>()
        var mine = 0

        for pid in Self.allPids() where pid > 0 {
            guard let bsd = Self.bsdInfo(pid), bsd.pbi_uid == uid, let usage = Self.usage(pid) else { continue }
            mine += 1
            let start = Self.startTime(bsd)
            let cpuTime = (usage.ri_user_time &+ usage.ri_system_time) &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
            seen[pid] = (start, cpuTime)
            var cpu = 0.0
            if wall > 0, let before = previous[pid], before.start == start, cpuTime >= before.cpu {
                cpu = Double(cpuTime - before.cpu) / wall * 100
            }

            let path = Self.path(of: pid) ?? ""
            let command = Self.name(bsd)
            let executable = path.isEmpty ? command : (path as NSString).lastPathComponent
            let interpreter = Self.interpreters.contains(executable) || Self.interpreters.contains(command)
            let appPath = interpreter ? nil : Self.outermostApp(path)

            var group: Group
            if let appPath {
                let key = "app:" + appPath
                group = built[key] ?? Group(key: key, name: appName(appPath), kind: "app", appPath: appPath)
            } else {
                // The start time is part of the key, so a stale row can never match a reused PID.
                let key = "pid:\(pid):\(start)"
                liveDescriptions.insert(key)
                let described = descriptions[key] ?? describe(pid: pid, executable: executable, interpreter: interpreter)
                descriptions[key] = described
                group = Group(key: key, name: described.label, kind: "process", detail: described.cwd)
            }
            group.members.append(Member(pid: pid, start: start))
            group.memory += Double(usage.ri_phys_footprint)
            group.cpu += cpu
            group.started = min(group.started, Double(bsd.pbi_start_tvsec))
            if let reason = Self.neverQuit[command] ?? Self.neverQuit[executable] { group.protectedReason = reason }
            if pid == selfPid || appPath == Bundle.main.bundlePath {
                group.protectedReason = "This is MacSense. Quit it with ⌘Q."
            }
            built[group.key] = group
        }

        previous = seen
        previousTime = now
        descriptions = descriptions.filter { liveDescriptions.contains($0.key) }
        groups = built

        // The biggest memory users, plus anything busy on the CPU even if it's small.
        var chosen = Array(built.values.sorted { $0.memory > $1.memory }.prefix(24))
        let busy = built.values.filter { $0.cpu >= 1 }.sorted { $0.cpu > $1.cpu }.prefix(8)
        for group in busy where !chosen.contains(where: { $0.key == group.key }) { chosen.append(group) }

        var icons: [String: String] = [:]
        let rows: [[String: Any]] = chosen.map { group in
            var row: [String: Any] = [
                "key": group.key, "name": group.name, "kind": group.kind,
                "count": group.members.count, "memory": group.memory, "cpu": group.cpu,
            ]
            if let detail = group.detail { row["detail"] = detail }
            if group.started.isFinite { row["started"] = group.started * 1000 }
            if let reason = group.protectedReason { row["protected"] = reason }
            if let appPath = group.appPath {
                row["app"] = appPath
                if includeIcons, !iconsSent.contains(appPath), let icon = icon(for: appPath) {
                    icons[appPath] = icon
                    iconsSent.insert(appPath)
                }
            }
            return row
        }
        var result: [String: Any] = ["rows": rows, "count": mine, "ready": wall > 0]
        if !icons.isEmpty { result["icons"] = icons }
        return result
    }

    /// Quits (or force quits) one row. Every PID is re-checked against the start time it had when
    /// it was listed, so a stale row can't hit a process that has since reused its PID.
    func quit(key: String, force: Bool) -> (ok: Bool, message: String) {
        guard let group = groups[key] else { return (false, "That item isn't running any more.") }
        if let reason = group.protectedReason { return (false, "MacSense won't quit \(group.name). \(reason)") }

        if let appPath = group.appPath {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == appPath }
            if !running.isEmpty {
                let accepted = running.map { force ? $0.forceTerminate() : $0.terminate() }.allSatisfy { $0 }
                guard accepted else { return (false, "\(group.name) didn't accept the request.") }
                return (true, force ? "Force quit \(group.name)." : "Asked \(group.name) to quit. It may ask you to save first.")
            }
        }

        var signalled = 0
        var failure: String?
        for member in group.members where member.pid > 1 && member.pid != selfPid {
            guard let bsd = Self.bsdInfo(member.pid), bsd.pbi_uid == uid, Self.startTime(bsd) == member.start else { continue }
            if kill(member.pid, force ? SIGKILL : SIGTERM) == 0 {
                signalled += 1
            } else {
                failure = String(cString: strerror(errno))
            }
        }
        if signalled > 0 {
            return (true, force ? "Force quit \(group.name)." : "Asked \(group.name) to quit.")
        }
        return (false, failure.map { "Couldn't quit \(group.name): \($0)." } ?? "\(group.name) had already exited.")
    }

    // MARK: - Naming

    private func appName(_ appPath: String) -> String {
        if let cached = appNames[appPath] { return cached }
        let bundle = Bundle(path: appPath)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        appNames[appPath] = name
        return name
    }

    /// "node server/server.js" in "~/Desktop/AEON", instead of a bare "node".
    private func describe(pid: pid_t, executable: String, interpreter: Bool) -> (label: String, cwd: String?) {
        let cwd = Self.workingDirectory(of: pid)
        var label = executable
        // process.title overwrites argv in place and zeroes the rest, which leaves empty strings behind.
        if interpreter, let args = Self.arguments(of: pid)?.filter({ !$0.isEmpty }), let first = args.first {
            if args.count > 1 {
                label = ([executable] + args.dropFirst().map { Self.shorten($0, relativeTo: cwd) }).joined(separator: " ")
            } else if (first as NSString).lastPathComponent != executable {
                label = first   // renamed itself through process.title, e.g. "next-server (v15.5.23)"
            }
        }
        if label.count > 64 { label = String(label.prefix(63)) + "…" }
        return (label, cwd.map(Self.abbreviate))
    }

    /// An absolute path inside the working directory reads better relative to it.
    private static func shorten(_ argument: String, relativeTo cwd: String?) -> String {
        if let cwd, argument.hasPrefix(cwd + "/") { return String(argument.dropFirst(cwd.count + 1)) }
        return abbreviate(argument)
    }

    private func icon(for appPath: String) -> String? {
        if let cached = iconCache[appPath] { return cached }
        let image = NSWorkspace.shared.icon(forFile: appPath)
        let pixels = 64
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        iconCache[appPath] = url
        return url
    }

    // MARK: - libproc

    static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return found > 0 ? Array(pids.prefix(Int(found))) : []
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func startTime(_ info: proc_bsdinfo) -> UInt64 {
        UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    static func usage(_ pid: pid_t) -> rusage_info_v2? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? usage : nil
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    static func name(_ info: proc_bsdinfo) -> String {
        let long = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !long.isEmpty { return long }
        return withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// ".../Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper.app/..." → ".../Google Chrome.app"
    static func outermostApp(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func arguments(of pid: pid_t) -> [String]? {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Int(argmax)
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // executable path
        while index < size && buffer[index] == 0 { index += 1 }   // padding
        var args: [String] = []
        while args.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty || path == "/" ? nil : path
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
