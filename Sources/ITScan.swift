import AppKit
import IOKit
import SystemConfiguration

/// The IT health scan: the questions IT asks when a Mac misbehaves, answered in plain English.
///
/// Read-only, and limited to hardware, health and security settings. It never collects which apps are
/// open, file names or browsing. Everything reads without admin rights except the system-wide crash
/// reports, which macOS keeps for administrators; those unlock with an admin password (ITAdmin).
/// It runs Apple's own command-line tools once per scan, because several answers (management
/// enrollment, FileVault, SIP) have no public API.
enum ITScan {
    enum Status: String { case good, warning, critical, info, locked }

    struct Item {
        let title: String
        var status: Status
        var value: String
        var detail = ""
        var fix = ""

        var dictionary: [String: Any] {
            var entry: [String: Any] = ["title": title, "status": status.rawValue, "value": value]
            if !detail.isEmpty { entry["detail"] = detail }
            if !fix.isEmpty { entry["fix"] = fix }
            return entry
        }
    }

    static let systemReports = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
    static let userReports = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    /// Whether this account can read the system crash reports without an admin password.
    static var systemReportsReadable: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: systemReports.path)) != nil
    }

    /// Runs every check in parallel; the slowest (the macOS log search) takes about 15 seconds.
    /// `unlockedSystemReports` is a readable copy of the system crash folder made with an admin password.
    static func run(unlockedSystemReports: URL? = nil) -> [String: Any] {
        let results = Results()
        let group = DispatchGroup()
        func check(_ key: String, _ work: @escaping @Sendable () -> [Item]) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                results.set(key, work())
                group.leave()
            }
        }
        check("machine") { machine() }
        check("management") { management() }
        check("security") { security() }
        check("storage") { storage() }
        check("battery") { battery() }
        check("thermal") { thermal() }
        check("memory") { memory() }
        check("restarts") { restarts(unlocked: unlockedSystemReports) }
        check("cause") { [shutdownCause()] }
        check("crashes") { crashes(unlocked: unlockedSystemReports) }
        group.wait()

        let sections: [(String, [Item])] = [
            ("This Mac", results.get("machine")),
            ("Management & security", results.get("management") + results.get("security")),
            ("Health", results.get("storage") + results.get("battery") + results.get("thermal") + results.get("memory")),
            ("Restarts & crashes", results.get("restarts") + results.get("cause") + results.get("crashes")),
        ]
        let all = sections.flatMap { $0.1 }
        let count = { (status: Status) in all.filter { $0.status == status }.count }
        let computer = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "This Mac"
        return [
            "generated": Date().timeIntervalSince1970 * 1000,
            "computer": computer,
            "serial": serialNumber() ?? "Not reported",
            "model": SystemInfo.collect()["modelName"] as? String ?? "Mac",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "summary": ["critical": count(.critical), "warning": count(.warning), "good": count(.good), "locked": count(.locked)],
            "needsAdmin": count(.locked) > 0,
            "privacy": "Hardware, health and security settings only. No apps in use, files or browsing.",
            "sections": sections.map { ["title": $0.0, "items": $0.1.map(\.dictionary)] },
        ]
    }

    // MARK: - This Mac

    static func machine() -> [Item] {
        let info = SystemInfo.collect()
        let modelName = info["modelName"] as? String ?? "Mac"
        let identifier = info["model"] as? String ?? ""
        var items = [
            Item(title: "Computer name", status: .info, value: (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Not reported"),
            Item(title: "Serial number", status: .info, value: serialNumber() ?? "Not reported",
                 detail: "Match it against your asset list or your management system."),
            Item(title: "Model", status: .info, value: identifier.isEmpty || identifier == modelName ? modelName : "\(modelName) · \(identifier)"),
        ]
        if let year = modelYear(modelName) {
            let age = Calendar.current.component(.year, from: Date()) - year
            items.append(Item(title: "Age", status: age >= 7 ? .warning : .info, value: "From \(year), about \(age) year\(age == 1 ? "" : "s") old",
                              fix: age >= 7 ? "Check this Mac still gets macOS security updates, and plan its replacement." : ""))
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let build = Sysctl.string("kern.osversion").map { " (\($0))" } ?? ""
        items.append(Item(title: "macOS", status: .info, value: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)\(build)"))
        if let cpu = info["cpu"] as? String { items.append(Item(title: "Processor", status: .info, value: cpu)) }
        if let memory = info["memTotal"] as? Double {
            items.append(Item(title: "Memory installed", status: .info, value: "\(Int((memory / 1_073_741_824).rounded())) GB"))
        }
        if let boot = Sysctl.bootTime() {
            let days = Int((Date().timeIntervalSince1970 - boot) / 86_400)
            items.append(Item(title: "Last restart", status: days > 30 ? .warning : .info,
                              value: "\(formatDate(Date(timeIntervalSince1970: boot))) (\(days) day\(days == 1 ? "" : "s") ago)",
                              fix: days > 30 ? "Restart this Mac. macOS finishes installing updates when it restarts." : ""))
        }
        return items
    }

    static func serialNumber() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// "iMac (Retina 5K, 27-inch, 2020)" → 2020
    static func modelYear(_ marketingName: String) -> Int? {
        guard let range = marketingName.range(of: #"(19|20)\d{2}(?=\)\s*$)"#, options: .regularExpression) else { return nil }
        return Int(marketingName[range])
    }

    // MARK: - Management & security

    static func management() -> [Item] {
        guard let output = Tool.run("/usr/bin/profiles", ["status", "-type", "enrollment"]) else {
            return [Item(title: "Management (MDM)", status: .info, value: "Couldn't check")]
        }
        let automated = value(after: "Enrolled via DEP:", in: output) ?? "unknown"
        let mdm = value(after: "MDM enrollment:", in: output) ?? ""
        let enrolled = mdm.lowercased().hasPrefix("yes")
        // A Jamf configuration profile can name the system (key ManagementName, e.g. "Jamf").
        let system = UserDefaults.standard.string(forKey: "ManagementName") ?? "your management system"
        return [Item(title: "Management (MDM)", status: enrolled ? .good : .critical,
                     value: enrolled ? (mdm.contains("User Approved") ? "Enrolled (user approved)" : "Enrolled") : "Not enrolled",
                     detail: "Automated enrollment through Apple Business Manager: \(automated).",
                     fix: enrolled ? "" : "This Mac isn't managed. Enroll it in \(system) so it gets your security settings and apps.")]
    }

    static func security() -> [Item] {
        var items: [Item] = []
        let fileVault = Tool.run("/usr/bin/fdesetup", ["status"])
        let fileVaultOn = fileVault?.contains("FileVault is On") == true
        items.append(Item(title: "Disk encryption (FileVault)", status: fileVault == nil ? .info : (fileVaultOn ? .good : .critical),
                          value: fileVault == nil ? "Couldn't check" : (fileVaultOn ? "On" : "Off"),
                          fix: fileVault == nil || fileVaultOn ? "" : "Turn on FileVault so a lost or stolen Mac doesn't expose its data."))

        let firewall = Tool.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        let firewallOn = firewall?.contains("enabled") == true
        items.append(Item(title: "Firewall", status: firewall == nil ? .info : (firewallOn ? .good : .warning),
                          value: firewall == nil ? "Couldn't check" : (firewallOn ? "On" : "Off"),
                          fix: firewall == nil || firewallOn ? "" : "Turn on the firewall in System Settings → Network → Firewall."))

        let sip = Tool.run("/usr/bin/csrutil", ["status"])
        let sipOn = sip?.contains("status: enabled") == true
        items.append(Item(title: "System Integrity Protection", status: sip == nil ? .info : (sipOn ? .good : .critical),
                          value: sip == nil ? "Couldn't check" : (sipOn ? "On" : "Off or customised"),
                          fix: sip == nil || sipOn ? "" : "SIP protects macOS itself. Turn it back on from Recovery unless there's a documented reason."))

        let gatekeeper = Tool.run("/usr/sbin/spctl", ["--status"])
        let gatekeeperOn = gatekeeper?.contains("assessments enabled") == true
        items.append(Item(title: "Gatekeeper (app checks)", status: gatekeeper == nil ? .info : (gatekeeperOn ? .good : .critical),
                          value: gatekeeper == nil ? "Couldn't check" : (gatekeeperOn ? "On" : "Off"),
                          fix: gatekeeper == nil || gatekeeperOn ? "" : "Gatekeeper stops unverified apps. Turn it back on."))
        return items
    }

    // MARK: - Health

    static func storage() -> [Item] {
        var items: [Item] = []
        var health = Item(title: "Startup disk health", status: .info, value: "Couldn't check")
        if let root = diskInfo("/"),
           let store = ((root["APFSPhysicalStores"] as? [[String: Any]])?.first?["APFSPhysicalStore"] as? String)
            ?? (root["ParentWholeDisk"] as? String),
           let storeInfo = diskInfo(store),
           let whole = storeInfo["ParentWholeDisk"] as? String ?? Optional(store),
           let wholeInfo = diskInfo(whole) {
            let smart = wholeInfo["SMARTStatus"] as? String ?? "Not reported"
            let media = (wholeInfo["MediaName"] as? String).map { " · \($0)" } ?? ""
            switch smart {
            case "Verified": health = Item(title: "Startup disk health", status: .good, value: "Verified\(media)")
            case "Failing": health = Item(title: "Startup disk health", status: .critical, value: "Failing\(media)",
                                          fix: "Back up this Mac now and replace the drive.")
            default: health = Item(title: "Startup disk health", status: .info, value: "\(smart)\(media)")
            }
        }
        items.append(health)

        let root = URL(fileURLWithPath: "/")
        if let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let total = values.volumeTotalCapacity, total > 0 {
            let free = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let share = free / Double(total)
            let text = "\(gigabytes(free)) free of \(gigabytes(Double(total))) (\(Int((share * 100).rounded()))%)"
            items.append(Item(title: "Startup disk space", status: share < 0.10 ? .critical : (share < 0.20 ? .warning : .good), value: text,
                              fix: share < 0.20 ? "Free up space: macOS needs room for updates, and a nearly full disk slows everything down." : ""))
        }
        return items
    }

    static func battery() -> [Item] {
        guard let data = Tool.runData("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"], timeout: 30),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["SPPowerDataType"] as? [[String: Any]] else {
            return [Item(title: "Battery", status: .info, value: "Couldn't check")]
        }
        guard let health = entries.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first else {
            return [Item(title: "Battery", status: .info, value: "No battery (desktop Mac)")]
        }
        let cycles = (health["sppower_battery_cycle_count"] as? NSNumber)?.intValue
        let condition = health["sppower_battery_health"] as? String ?? "Unknown"
        let capacityText = health["sppower_battery_health_maximum_capacity"] as? String
        let capacity = capacityText.flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        let serviceNeeded = condition.lowercased().contains("service") || condition.lowercased().contains("poor")
        let worn = (capacity ?? 100) < 80
        var parts = ["Condition: \(condition)"]
        if let capacity { parts.append("\(capacity)% of its original capacity") }
        if let cycles { parts.append("\(cycles) charge cycles") }
        return [Item(title: "Battery", status: serviceNeeded ? .critical : (worn ? .warning : .good), value: parts.joined(separator: " · "),
                     fix: serviceNeeded ? "The battery needs service. Worn batteries cause sudden shutdowns." :
                          (worn ? "The battery has lost capacity. Expect shorter runtime; plan a replacement." : ""))]
    }

    static func thermal() -> [Item] {
        var items: [Item] = []
        let names = ["Nominal", "Fair", "Serious", "Critical"]
        let state = ProcessInfo.processInfo.thermalState.rawValue
        items.append(Item(title: "Thermal state right now", status: state >= 2 ? .critical : (state == 1 ? .warning : .good),
                          value: names[min(max(state, 0), 3)],
                          fix: state >= 1 ? "The Mac is running hot. Check the vents aren't blocked and close heavy apps." : ""))

        if let smc = SMCSensors.open() {
            if let key = smc.cpuKey, let celsius = SMCSensors.read(key) {
                items.append(Item(title: "CPU temperature", status: celsius >= 95 ? .warning : .good, value: "\(Int(celsius.rounded()))°C",
                                  fix: celsius >= 95 ? "Very hot. Check the vents and fan; heat is a common cause of sudden shutdowns." : ""))
            }
            if smc.fans > 0, let rpm = SMCSensors.read("F0Ac") {
                var value = "\(Int(rpm.rounded())) rpm"
                if let low = SMCSensors.read("F0Mn"), let high = SMCSensors.read("F0Mx") {
                    value += " (range \(Int(low.rounded()))–\(Int(high.rounded())))"
                }
                items.append(Item(title: "Fan", status: .info, value: value))
            }
        }

        if let therm = Tool.run("/usr/bin/pmset", ["-g", "therm"]) {
            let quiet = therm.contains("No thermal warning level has been recorded")
                && therm.contains("No performance warning level has been recorded")
            items.append(Item(title: "Heat warnings since last restart", status: quiet ? .good : .warning,
                              value: quiet ? "None recorded" : "macOS recorded heat or performance warnings",
                              fix: quiet ? "" : "The Mac has slowed itself down because of heat. Check the vents and fan."))
        }
        return items
    }

    static func memory() -> [Item] {
        var items: [Item] = []
        if let level = Sysctl.int32("kern.memorystatus_vm_pressure_level") {
            let (status, text): (Status, String) = level >= 4 ? (.critical, "Critical") : (level == 2 ? (.warning, "Warning") : (.good, "Normal"))
            items.append(Item(title: "Memory pressure now", status: status, value: text,
                              fix: level >= 2 ? "This Mac is short of memory for what's open. Close apps, or it needs more memory." : ""))
        }
        if let swap = Sysctl.swap(), swap.total > 0 {
            items.append(Item(title: "Swap in use", status: .info, value: "\(gigabytes(Double(swap.used), binary: true)) of \(gigabytes(Double(swap.total), binary: true))",
                              detail: "Disk space macOS uses when memory is full. High numbers alongside slowness mean not enough memory."))
        }
        return items
    }

    // MARK: - Restarts & crashes

    /// Every clean shutdown and every boot is recorded. A boot with no clean shutdown before it means
    /// the Mac went down unexpectedly: a crash, a power loss or a held power button. A kernel panic
    /// within minutes of that boot says which.
    static func restarts(unlocked: URL?) -> [Item] {
        guard let output = Tool.run("/usr/bin/last", ["reboot", "shutdown"]) else {
            return [Item(title: "Restarts, last 30 days", status: .info, value: "Couldn't check")]
        }
        let panics = panicReports(unlocked: unlocked)
        let events = parseLast(output)
        let since = Date().addingTimeInterval(-30 * 86_400)
        var unexpected: [Date] = []
        var restarts = 0
        for (index, event) in events.enumerated() where event.kind == "reboot" && event.date >= since {
            restarts += 1
            // A restart can only be judged when the record also holds the boot before it.
            guard let previous = events[..<index].last(where: { $0.kind == "reboot" }) else { continue }
            let cleanBefore = events.contains { $0.kind == "shutdown" && $0.date >= previous.date && $0.date <= event.date }
            if !cleanBefore { unexpected.append(event.date) }
        }
        let status: Status = unexpected.isEmpty ? .good : (unexpected.count == 1 ? .warning : .critical)
        let explained = unexpected.map { date -> String in
            let why: String
            if panics.readable == false {
                why = "unlock crash reports to see if a crash caused it"
            } else if panics.list.contains(where: { abs($0.date.timeIntervalSince(date)) < 900 }) {
                why = "a kernel panic (see below)"
            } else {
                why = "no crash report, so most likely a power loss or a held power button"
            }
            return "\(formatDate(date)): \(why)"
        }
        return [Item(title: "Restarts, last 30 days", status: status,
                     value: "\(restarts) restart\(restarts == 1 ? "" : "s"), \(unexpected.count) unexpected",
                     detail: unexpected.isEmpty ? "Every restart followed a normal shutdown."
                         : "No normal shutdown came before these. " + explained.joined(separator: "; ") + ".",
                     fix: unexpected.isEmpty ? "" : "Repeated unexpected restarts usually mean heat, a failing battery, power problems or a hardware fault.")]
    }

    struct PowerEvent { let kind: String; let date: Date }

    /// Parses `last reboot shutdown` ("reboot time   Mon Sep 14 20:11"). It prints no year, so each date
    /// takes the most recent year that isn't in the future.
    static func parseLast(_ output: String) -> [PowerEvent] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy EEE MMM d HH:mm"
        let year = Calendar.current.component(.year, from: Date())
        var events: [PowerEvent] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 6, parts[1] == "time", parts[0] == "reboot" || parts[0] == "shutdown" else { continue }
            let stamp = parts[2...5].joined(separator: " ")
            guard var date = formatter.date(from: "\(year) \(stamp)") else { continue }
            if date > Date().addingTimeInterval(86_400), let earlier = formatter.date(from: "\(year - 1) \(stamp)") { date = earlier }
            events.append(PowerEvent(kind: String(parts[0]), date: date))
        }
        return events.sorted { $0.date < $1.date }
    }

    /// macOS writes "Previous shutdown cause: N" into its log at boot. The log rotates within days,
    /// so this answers only when the scan runs soon after the event.
    static func shutdownCause() -> Item {
        let title = "Why it last shut down"
        guard let boot = Sysctl.bootTime() else { return Item(title: title, status: .info, value: "Couldn't check") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let start = formatter.string(from: Date(timeIntervalSince1970: boot - 120))
        let end = formatter.string(from: Date(timeIntervalSince1970: boot + 600))
        guard let output = Tool.run("/usr/bin/log", ["show", "--style", "compact", "--start", start, "--end", end,
                                                     "--predicate", "eventMessage CONTAINS \"shutdown cause\""], timeout: 45) else {
            return Item(title: title, status: .info, value: "Couldn't check")
        }
        guard let match = output.range(of: #"[Pp]revious shutdown cause:\s*-?\d+"#, options: .regularExpression),
              let code = Int(output[match].split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") else {
            return Item(title: title, status: .info, value: "No longer in the macOS log",
                        detail: "macOS keeps this for a few days. Run the scan soon after an unexpected shutdown to catch it.")
        }
        let (meaning, status) = shutdownMeaning(code)
        return Item(title: title, status: status, value: "Code \(code): \(meaning)",
                    detail: "Apple doesn't publish these codes; the meaning shown is the one IT teams widely report.")
    }

    static func shutdownMeaning(_ code: Int) -> (String, Status) {
        switch code {
        case 5: return ("a normal shutdown or restart", .good)
        case 3: return ("forced off by holding the power button", .warning)
        case 0: return ("power was lost", .warning)
        case -3: return ("overheated (several temperature sensors over their limit)", .critical)
        case -62: return ("the system stopped responding and restarted itself", .critical)
        case -71: return ("memory overheated", .critical)
        case -74: return ("battery overheated", .critical)
        case -75, -78: return ("a problem with the power adapter", .critical)
        case -86: return ("overheated (proximity sensor)", .critical)
        case -95: return ("the CPU overheated", .critical)
        case -100: return ("the power supply overheated", .critical)
        case -103: return ("the battery ran too low or failed", .critical)
        case -128: return ("an unknown fault, often memory-related", .critical)
        default: return (code < 0 ? "a hardware or power problem (uncommon code)" : "an uncommon code", code < 0 ? .critical : .info)
        }
    }

    struct Panic { let date: Date; let message: String }

    /// Whole-Mac crashes from the last 30 days. macOS files them in more than one place: a hidden
    /// `.contents.panic` summary, `panic-full-*.ips` reports, and on Macs with a T2 chip a
    /// `ProxiedDevice-Bridge` subfolder. The same panic can appear in several, so each is counted once.
    static func panicReports(unlocked: URL?) -> (list: [Panic], readable: Bool) {
        guard let folder = unlocked ?? (systemReportsReadable ? systemReports : nil) else { return ([], false) }
        let since = Date().addingTimeInterval(-30 * 86_400)
        var byReport: [String: Panic] = [:]
        for file in reportFiles(in: folder) + reportFiles(in: userReports) {
            let name = file.lastPathComponent
            guard file.pathExtension == "panic" || name.hasPrefix("panic-full") || file.pathExtension == "ips" else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard date >= since, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            let text = String(decoding: data.prefix(1_048_576), as: UTF8.self)
            let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
            let first = lines.first.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            var message: String?
            var identity = name
            if let panicText = first?["panic_string"] as? String {               // the hidden .contents.panic summary
                message = panicText
                identity = (first?["log_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? name
            } else if first?["bug_type"] as? String == "210" || name.hasPrefix("panic-full") {
                let body = lines.count > 1 ? (try? JSONSerialization.jsonObject(with: Data(lines[1].utf8))) as? [String: Any] : nil
                message = body?["panicString"] as? String
                    ?? text.range(of: #"panic\([^\n]{0,200}"#, options: .regularExpression).map { String(text[$0]) }
                    ?? "Kernel panic"
            }
            guard let message else { continue }
            let panic = Panic(date: date, message: message)
            if let existing = byReport[identity], existing.date <= date { continue }
            byReport[identity] = panic
        }
        return (byReport.values.sorted { $0.date > $1.date }, true)
    }

    /// Report files at the top of a crash folder and one level down, where macOS files some panics.
    static func reportFiles(in folder: URL) -> [URL] {
        let manager = FileManager.default
        guard let top = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else { return [] }
        return top.flatMap { url -> [URL] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [url] }
            return (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
    }

    /// The first line of a panic message in words a person can act on.
    static func panicCause(_ message: String) -> String {
        let text = message.lowercased()
        if text.contains("machine check") { return "the processor reported a hardware error. Once can be a glitch; if it repeats, the Mac needs hardware service (CPU, memory, power or heat)" }
        if text.contains("sleep wake") || text.contains("sleep/wake") { return "it crashed going to sleep or waking up" }
        if text.contains("watchdog") { return "the system stopped responding and was restarted" }
        if text.contains("gpu") || text.contains("amdradeon") || text.contains("iogpu") { return "the graphics hardware or its driver crashed" }
        if text.contains("thermal") { return "it overheated" }
        if text.contains("page fault") || text.contains("kernel trap") { return "a driver or system extension crashed" }
        return "a whole-system crash"
    }

    /// Kernel panics (the whole Mac crashed) and app crashes from the last 30 days.
    static func crashes(unlocked: URL?) -> [Item] {
        let since = Date().addingTimeInterval(-30 * 86_400)
        var appCrashes: [String: Int] = [:]
        let systemFolder: URL? = unlocked ?? (systemReportsReadable ? systemReports : nil)
        var seen = Set<String>()
        for folder in [userReports] + (systemFolder.map { [$0] } ?? []) {
            for file in reportFiles(in: folder) where file.pathExtension == "ips" && seen.insert(file.lastPathComponent).inserted {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard date >= since, let header = firstLine(of: file),
                      let meta = (try? JSONSerialization.jsonObject(with: Data(header.utf8))) as? [String: Any],
                      meta["bug_type"] as? String == "309" else { continue }
                appCrashes[meta["app_name"] as? String ?? file.deletingPathExtension().lastPathComponent, default: 0] += 1
            }
        }

        var items: [Item] = []
        let panics = panicReports(unlocked: unlocked)
        if !panics.readable {
            items.append(Item(title: "Kernel panics, last 30 days", status: .locked, value: "Admin password needed",
                              detail: "macOS keeps whole-Mac crash reports for administrators. Unlock to include them."))
        } else if panics.list.isEmpty {
            items.append(Item(title: "Kernel panics, last 30 days", status: .good, value: "None"))
        } else {
            let list = panics.list.prefix(5).map { panic -> String in
                let first = panic.message.replacingOccurrences(of: "\r", with: "").split(separator: "\n").first.map(String.init) ?? "Kernel panic"
                return "\(formatDate(panic.date)): \(panicCause(panic.message)). macOS recorded: \"\(first.prefix(120))\""
            }
            items.append(Item(title: "Kernel panics, last 30 days", status: .critical, value: "\(panics.list.count)",
                              detail: list.joined(separator: "\n"),
                              fix: "The whole Mac crashed. Keep this report with the Mac's record; if it happens again, book hardware service."))
        }
        let total = appCrashes.values.reduce(0, +)
        let top = appCrashes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(6)
            .map { "\($0.key) ×\($0.value)" }
        items.append(Item(title: "App crashes, last 30 days", status: total >= 10 ? .warning : .info,
                          value: total == 0 ? "None" : "\(total)",
                          detail: total == 0 ? (systemFolder == nil ? "Only this account's reports were checked." : "")
                              : top.joined(separator: ", ") + (systemFolder == nil ? ". Only this account's reports were checked." : "")))
        return items
    }

    static func firstLine(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return String(decoding: head, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    // MARK: - Helpers

    static func diskInfo(_ target: String) -> [String: Any]? {
        guard let data = Tool.runData("/usr/sbin/diskutil", ["info", "-plist", target]) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func value(after label: String, in text: String) -> String? {
        text.split(separator: "\n").first { $0.contains(label) }?
            .components(separatedBy: label).last?.trimmingCharacters(in: .whitespaces)
    }

    static func gigabytes(_ bytes: Double, binary: Bool = false) -> String {
        let value = bytes / (binary ? 1_073_741_824 : 1_000_000_000)
        return value >= 100 ? "\(Int(value.rounded())) GB" : String(format: "%.1f GB", value)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: [Item]] = [:]
        func set(_ key: String, _ value: [Item]) { lock.lock(); items[key] = value; lock.unlock() }
        func get(_ key: String) -> [Item] { lock.lock(); defer { lock.unlock() }; return items[key] ?? [] }
    }
}

/// Runs one of Apple's own tools with fixed arguments, with a time limit. Nothing from the page is ever
/// passed to it.
enum Tool {
    static func runData(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let output = Output()
        let reading = DispatchGroup()
        do { try process.run() } catch { return nil }
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        _ = reading.wait(timeout: .now() + 2)
        return output.data
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) -> String? {
        runData(path, arguments, timeout: timeout).map { String(decoding: $0, as: UTF8.self) }
    }

    final class Output: @unchecked Sendable { var data = Data() }
}

/// Unlocks the system crash reports with an administrator's name and password: macOS shows its own
/// password dialog, under MacSense's name. The privileged step only copies the reports into a private
/// folder this account can read; all the reading happens without admin rights. The command is fixed text.
enum ITAdmin {
    static func unlockSystemReports() -> (folder: URL?, message: String) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSense-reports-\(UUID().uuidString)", isDirectory: true)
        let source = """
        set dest to "\(folder.path)"
        do shell script "/bin/mkdir -p " & quoted form of dest & " && /bin/cp -Rp /Library/Logs/DiagnosticReports/. " & quoted form of dest & "/ 2>/dev/null; /usr/sbin/chown -R \(getuid()) " & quoted form of dest & "; /bin/chmod -R u+rwX " & quoted form of dest & "; exit 0" with prompt "MacSense needs an administrator to read this Mac's crash reports." with administrator privileges
        """
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            return (nil, code == -128 ? "Cancelled." : "Couldn't unlock: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error").")
        }
        return (folder, "Crash reports unlocked.")
    }
}
