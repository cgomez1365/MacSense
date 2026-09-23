import AppKit
import IOKit

/// Reads every metric straight from the kernel and IOKit. No shell commands, and no made-up
/// fallback values: a reading that isn't available is left out, and the page shows "—".
/// Used from one serial queue only (see Monitor).
final class Sampler: @unchecked Sendable {
    let processes: ProcessTable
    let volumes = VolumeReader()
    var volumesChanged = true

    private let host = mach_host_self()
    private var previousTicks: [[UInt32]] = []
    private var previousNet: [String: NetworkCounters.Counter] = [:]
    private var previousNetTime: UInt64 = 0
    private var sessionRx: UInt64 = 0
    private var sessionTx: UInt64 = 0
    private var interfaceMoved: [String: UInt64] = [:]
    private var interfaceNames: [String: String]
    private var tick = 0
    private let smc: SMCSensors?

    init(includeIcons: Bool = true) {
        processes = ProcessTable(includeIcons: includeIcons)
        smc = SMCSensors.open()
        interfaceNames = NetworkCounters.displayNames()
    }

    /// Takes the baselines that CPU, network and per-process rates are measured against,
    /// so the first sample the page sees is already a real one.
    func prime() {
        _ = cpu()
        _ = network()
        _ = processes.snapshot()
    }

    /// Everything that doesn't need a time interval, sent the moment the window opens so the
    /// page isn't empty while the first CPU and network interval runs. Rates say "not ready yet".
    func initialSample() -> [String: Any] {
        [
            "t": Date().timeIntervalSince1970 * 1000,
            "cpu": ["ready": false], "net": ["ready": false, "ifaces": [[String: Any]]()],
            "mem": memory(), "gpu": gpus(), "thermal": thermal(), "volumes": volumes.read(),
        ]
    }

    func sample(everything: Bool = false) -> [String: Any] {
        tick += 1
        var sample: [String: Any] = [
            "t": Date().timeIntervalSince1970 * 1000,
            "cpu": cpu(), "mem": memory(), "net": network(), "gpu": gpus(), "thermal": thermal(),
        ]
        if everything || tick % 2 == 1 { sample["procs"] = processes.snapshot() }
        if everything || volumesChanged || tick % 5 == 1 {
            sample["volumes"] = volumes.read()
            volumesChanged = false
        }
        if tick % 10 == 0 { interfaceNames = NetworkCounters.displayNames() }   // picks up a newly plugged adapter
        return sample
    }

    // MARK: - CPU

    private func cpu() -> [String: Any] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return ["ready": false] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        let current: [[UInt32]] = (0..<Int(cpuCount)).map { core in
            (0..<states).map { UInt32(bitPattern: info[core * states + $0]) }
        }
        defer { previousTicks = current }
        guard previousTicks.count == current.count else { return ["ready": false] }

        var cores: [Double] = []
        var user = 0.0, system = 0.0, total = 0.0
        for (now, before) in zip(current, previousTicks) {
            let delta = (0..<states).map { Double(now[$0] &- before[$0]) }
            let sum = delta.reduce(0, +)
            let coreUser = delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]
            let coreSystem = delta[Int(CPU_STATE_SYSTEM)]
            user += coreUser
            system += coreSystem
            total += sum
            cores.append(sum > 0 ? (coreUser + coreSystem) / sum * 100 : 0)
        }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return [
            "ready": total > 0,
            "user": total > 0 ? user / total * 100 : 0,
            "system": total > 0 ? system / total * 100 : 0,
            "cores": cores, "load": load,
        ]
    }

    // MARK: - Memory

    /// The same split Activity Monitor shows. "Used" is app memory + wired + compressed;
    /// cached files are not counted as used, because macOS hands that memory back the
    /// moment an app needs it. Whether the Mac is actually short of memory is the kernel's
    /// pressure level, not a percentage.
    private func memory() -> [String: Any] {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return [:] }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let page = Double(pageSize)

        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        let cached = (Double(stats.external_page_count) + Double(stats.purgeable_count)) * page
        let used = app + wired + compressed
        var memory: [String: Any] = [
            "total": total, "app": app, "wired": wired, "compressed": compressed, "cached": cached,
            "used": used, "free": max(0, total - used - cached),
        ]
        if let level = Sysctl.int32("kern.memorystatus_vm_pressure_level") { memory["pressure"] = Int(level) }
        if let available = Sysctl.int32("kern.memorystatus_level") { memory["availablePct"] = Int(available) }
        if let swap = Sysctl.swap() {
            memory["swapTotal"] = Double(swap.total)
            memory["swapUsed"] = Double(swap.used)
        }
        return memory
    }

    // MARK: - Network

    private func network() -> [String: Any] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let counters = NetworkCounters.counters()
        let links = NetworkCounters.links()
        let seconds = previousNetTime == 0 ? 0 : Double(now - previousNetTime) / 1_000_000_000
        // After sleep or a long stall the old baseline says nothing about the current rate.
        let ready = seconds > 0 && seconds < 10
        defer {
            previousNet = counters
            previousNetTime = now
        }

        let primary = NetworkCounters.primary()
        var interfaces: [[String: Any]] = []
        var rx = 0.0, tx = 0.0
        for (name, counter) in counters.sorted(by: { $0.key < $1.key }) {
            // Only links System Settings lists. That leaves out loopback, VPN tunnels and the
            // T2 chip's private USB link (en4 here), whose traffic never reaches the internet.
            guard NetworkCounters.isPhysical(name), let label = interfaceNames[name],
                  let link = links[name], link.running else { continue }
            var entry: [String: Any] = ["name": name, "label": label]
            if let ip = link.ipv4 { entry["ipv4"] = ip }
            if ready, let before = previousNet[name], counter.rx >= before.rx, counter.tx >= before.tx {
                let inBytes = counter.rx - before.rx, outBytes = counter.tx - before.tx
                entry["rx"] = Double(inBytes) / seconds
                entry["tx"] = Double(outBytes) / seconds
                rx += Double(inBytes) / seconds
                tx += Double(outBytes) / seconds
                sessionRx += inBytes
                sessionTx += outBytes
                interfaceMoved[name, default: 0] += inBytes + outBytes
            }
            // List a link once it has an address or has carried traffic; idle ports stay out of the way.
            if link.ipv4 != nil || name == primary || interfaceMoved[name, default: 0] > 0 { interfaces.append(entry) }
        }
        var network: [String: Any] = [
            "ready": ready, "ifaces": interfaces,
            "sessionRx": Double(sessionRx), "sessionTx": Double(sessionTx),
        ]
        if ready {
            network["rx"] = rx
            network["tx"] = tx
        }
        if let primary { network["primary"] = primary }
        return network
    }

    // MARK: - GPU

    private func gpus() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var seen = Set<String>()
        var gpus: [[String: Any]] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            else { continue }
            let name = gpuName(entry)
            guard seen.insert(name).inserted else { continue }
            var gpu: [String: Any] = ["name": name]
            if let value = number(stats, "Device Utilization %") ?? number(stats, "GPU Activity(%)") { gpu["util"] = value }
            if let value = number(stats, "Temperature(C)"), value > 0 { gpu["tempC"] = value }
            if let value = number(stats, "Total Power(W)"), value > 0 { gpu["powerW"] = value }
            if let value = number(stats, "vramUsedBytes") { gpu["vramUsed"] = value }
            if let value = number(stats, "In use system memory") { gpu["sharedUsed"] = value }
            gpus.append(gpu)
        }
        // A discrete GPU first: it's the one that does the heavy work when it's present.
        return gpus.sorted { ($0["tempC"] != nil ? 0 : 1) < ($1["tempC"] != nil ? 0 : 1) }
    }

    private func gpuName(_ entry: io_registry_entry_t) -> String {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let model = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "model" as CFString, kCFAllocatorDefault, options)
        if let data = model as? Data {
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
        }
        if let text = model as? String { return text }
        var className = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &className)
        return String(cString: className)
    }

    private func number(_ dictionary: [String: Any], _ key: String) -> Double? {
        (dictionary[key] as? NSNumber)?.doubleValue
    }

    // MARK: - Thermals

    private func thermal() -> [String: Any] {
        var thermal: [String: Any] = ["state": ProcessInfo.processInfo.thermalState.rawValue]
        guard let smc else { return thermal }
        if let key = smc.cpuKey, let value = SMCSensors.read(key) { thermal["cpuC"] = value }
        if let key = smc.gpuKey, let value = SMCSensors.read(key) { thermal["gpuC"] = value }
        var fans: [[String: Any]] = []
        for index in 0..<smc.fans {
            guard let rpm = SMCSensors.read("F\(index)Ac") else { continue }
            var fan: [String: Any] = ["rpm": rpm]
            if let low = SMCSensors.read("F\(index)Mn") { fan["min"] = low }
            if let high = SMCSensors.read("F\(index)Mx") { fan["max"] = high }
            fans.append(fan)
        }
        if !fans.isEmpty { thermal["fans"] = fans }
        return thermal
    }
}

/// Fan and temperature sensors via the SMC. If this Mac doesn't expose one, the page says
/// "not reported" instead of estimating.
struct SMCSensors {
    let cpuKey: String?
    let gpuKey: String?
    let fans: Int

    static func open() -> SMCSensors? {
        guard ms_smc_open() else { return nil }
        // First key that exists and reads as a plausible temperature.
        func first(_ keys: [String]) -> String? {
            keys.first { key in read(key).map { $0 > 5 && $0 < 125 } ?? false }
        }
        return SMCSensors(
            cpuKey: first(["TC0D", "TC0E", "TC0F", "TC0P", "TC0H", "TCXC", "TC1C", "Tp09", "Tp0T", "Tp01", "Tp05"]),
            gpuKey: first(["TG0D", "TG0P", "TG0H", "TGDD", "Tg0T", "Tg05", "Tg0D"]),
            fans: max(0, min(Int(read("FNum") ?? 0), 4)))
    }

    static func read(_ key: String) -> Double? {
        var value = 0.0
        return ms_smc_read(key, &value) ? value : nil
    }
}
