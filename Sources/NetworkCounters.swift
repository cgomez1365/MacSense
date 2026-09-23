import Foundation
import SystemConfiguration

/// Per-interface byte counters (64-bit, so they never wrap), plus names and addresses.
enum NetworkCounters {
    struct Counter { let rx: UInt64; let tx: UInt64 }
    struct Link { var running: Bool; var ipv4: String? }

    /// Ethernet, Wi-Fi, USB and Thunderbolt adapters all appear as en*. Loopback (lo0) never
    /// leaves the Mac, and a VPN tunnel (utun*) would count the same bytes a second time.
    static func isPhysical(_ name: String) -> Bool { name.hasPrefix("en") }

    static func counters() -> [String: Counter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: Counter] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        result[String(cString: name)] = Counter(rx: message.ifm_data.ifi_ibytes,
                                                                tx: message.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    static func links() -> [String: Link] {
        var result: [String: Link] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            let flags = Int32(bitPattern: entry.ifa_flags)
            var link = result[name] ?? Link(running: false, ipv4: nil)
            link.running = flags & IFF_UP != 0 && flags & IFF_RUNNING != 0
            if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    link.ipv4 = String(cString: host)
                }
            }
            result[name] = link
        }
        return result
    }

    /// BSD name → the name System Settings uses ("en1" → "Wi-Fi").
    static func displayNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in interfaces {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = name
            }
        }
        return names
    }

    private static let store = SCDynamicStoreCreate(nil, "MacSense" as CFString, nil, nil)

    /// The interface macOS is routing internet traffic through right now.
    static func primary() -> String? {
        guard let store,
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return value["PrimaryInterface"] as? String
    }
}
