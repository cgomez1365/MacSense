import AppKit

/// Command-line switches. Double-clicking the app passes none of them.
struct LaunchOptions {
    var dump = false             // --dump [--count N]: print samples as JSON and exit, no window
    var dumpCount = 1
    var smcProbe = false         // --smc-probe: list the fan and temperature sensors this Mac exposes
    var snapshotPath: String?    // --snapshot PATH: save a PNG of the window, then quit
    var snapshotDelay = 5.0      // --wait SECONDS before the snapshot
    var evalScript: String?      // --eval JS: async function body run in the page before the snapshot; its return value is printed
    var size: NSSize?            // --size 1280x860
    var inspectable = false      // --inspect: allow Safari's Web Inspector
    var verbose = false          // --verbose: log every sample on its way to the page

    init(_ arguments: [String]) {
        var remaining = arguments.dropFirst().makeIterator()
        while let argument = remaining.next() {
            switch argument {
            case "--dump": dump = true
            case "--count": dumpCount = Int(remaining.next() ?? "") ?? 1
            case "--smc-probe": smcProbe = true
            case "--snapshot": snapshotPath = remaining.next()
            case "--wait": snapshotDelay = Double(remaining.next() ?? "") ?? snapshotDelay
            case "--eval": evalScript = remaining.next()
            case "--size":
                let parts = (remaining.next() ?? "").split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
            case "--inspect": inspectable = true
            case "--verbose": verbose = true
            default: break   // Finder and `open` add flags of their own
            }
        }
    }
}

let options = LaunchOptions(CommandLine.arguments)
if options.dump {
    Diagnostics.dump(count: options.dumpCount)
    exit(0)
}
if options.smcProbe {
    Diagnostics.smcProbe()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate(options: options)
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
