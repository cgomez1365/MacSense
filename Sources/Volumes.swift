import AppKit
import DiskArbitration

/// Every mounted volume Finder shows: the startup disk, external and flash drives, disk images.
final class VolumeReader {
    private let session = DASessionCreate(kCFAllocatorDefault)
    private var devices: [String: [String: Any]] = [:]
    /// Mount path → name, for every volume that may be ejected. Eject requests are checked against it.
    private(set) var ejectable: [String: String] = [:]

    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeLocalizedFormatDescriptionKey,
        .volumeIsReadOnlyKey, .volumeIsLocalKey,
    ]

    func read() -> [[String: Any]] {
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys,
                                                               options: [.skipHiddenVolumes]) else { return [] }
        var volumes: [[String: Any]] = []
        var ejectable: [String: String] = [:]
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            let root = values.volumeIsRootFileSystem ?? false
            let name = values.volumeLocalizedName ?? url.lastPathComponent
            let available = Double(values.volumeAvailableCapacity ?? 0)
            // Finder's "Available" also counts purgeable space (caches macOS clears on demand).
            let free = max(available, values.volumeAvailableCapacityForImportantUsage.map { Double($0) } ?? 0)
            var volume: [String: Any] = [
                "path": url.path, "name": name, "total": Double(total), "free": free,
                "used": max(0, Double(total) - free), "root": root,
                "internal": values.volumeIsInternal ?? false, "removable": values.volumeIsRemovable ?? false,
                "readOnly": values.volumeIsReadOnly ?? false, "local": values.volumeIsLocal ?? true,
                "format": values.volumeLocalizedFormatDescription ?? "",
            ]
            if free - available > 1_000_000_000 { volume["purgeable"] = free - available }
            let canEject = !root && ((values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false)
                || !(values.volumeIsInternal ?? true))
            volume["ejectable"] = canEject
            if canEject { ejectable[url.path] = name }
            volume.merge(device(for: url)) { current, _ in current }
            volumes.append(volume)
        }
        self.ejectable = ejectable
        let live = Set(volumes.compactMap { $0["path"] as? String })
        devices = devices.filter { live.contains($0.key) }
        return volumes.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : (a["name"] as? String ?? "") < (b["name"] as? String ?? "")
        }
    }

    private func rank(_ volume: [String: Any]) -> Int {
        if volume["root"] as? Bool == true { return 0 }
        return volume["internal"] as? Bool == true ? 1 : 2
    }

    /// Bus and hardware name from Disk Arbitration, e.g. "USB" and "SanDisk Ultra".
    private func device(for url: URL) -> [String: Any] {
        if let cached = devices[url.path] { return cached }
        var info: [String: Any] = [:]
        if let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
           let description = DADiskCopyDescription(disk) as? [String: Any] {
            if let bus = description[kDADiskDescriptionDeviceProtocolKey as String] as? String { info["bus"] = bus }
            let vendor = (description[kDADiskDescriptionDeviceVendorKey as String] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let hardware = (vendor.isEmpty || model.lowercased().hasPrefix(vendor.lowercased()) ? model : "\(vendor) \(model)")
                .trimmingCharacters(in: .whitespaces)
            if !hardware.isEmpty { info["device"] = hardware }
        }
        devices[url.path] = info
        return info
    }
}
