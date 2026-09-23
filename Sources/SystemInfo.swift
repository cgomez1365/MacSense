import Foundation

/// sysctl readers. Each returns nil on failure, and the page shows "—" rather than an invented number.
enum Sysctl {
    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func swap() -> (total: UInt64, used: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_total, usage.xsu_used)
    }

    static func bootTime() -> Double? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
    }
}

/// Facts that don't change while MacSense runs. Sent to the page once.
enum SystemInfo {
    static func collect() -> [String: Any] {
        let model = Sysctl.string("hw.model") ?? "Mac"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var info: [String: Any] = [
            "model": model,
            "modelName": marketingName() ?? model,
            "physicalCores": Int(Sysctl.int32("hw.physicalcpu") ?? 0),
            "logicalCores": Int(Sysctl.int32("hw.logicalcpu") ?? 0),
            "memTotal": Double(ProcessInfo.processInfo.physicalMemory),
            "os": "macOS \(version.majorVersion).\(version.minorVersion)"
                + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        ]
        if let cpu = Sysctl.string("machdep.cpu.brand_string") { info["cpu"] = tidy(cpu) }
        if let boot = Sysctl.bootTime() { info["bootTime"] = boot * 1000 }
        return info
    }

    /// "Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz" → "Intel Core i5-10500 @ 3.10GHz"
    private static func tidy(_ brand: String) -> String {
        brand.replacingOccurrences(of: "(R)", with: "")
            .replacingOccurrences(of: "(TM)", with: "")
            .replacingOccurrences(of: " CPU", with: "")
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// The name About This Mac shows ("iMac (Retina 5K, 27-inch, 2020)"), read from the cache it writes.
    private static func marketingName() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.SystemProfiler.plist")
        guard let plist = NSDictionary(contentsOf: url),
              let names = plist["CPU Names"] as? [String: String] else { return nil }
        return names.values.first
    }
}
