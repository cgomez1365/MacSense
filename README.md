# MacSense

A native Mac system monitor: CPU, memory pressure, a live network graph, every mounted drive,
GPU, temperatures and fans, and your apps grouped by what they cost you.

Double-click `~/Desktop/MacSense.app`. It's a real app with its own window and Dock icon. There
is no server, no port and no browser, and nothing it reads leaves the Mac.

## What each number is

| Section | Source | Notes |
|---|---|---|
| CPU | `host_processor_info` tick deltas | Total, user/system split, every thread |
| Memory | `host_statistics64` | "Used" = app + wired + compressed, the same as Activity Monitor. Cached files don't count as used |
| Memory pressure | `kern.memorystatus_vm_pressure_level` | macOS's own verdict (Normal / Warning / Critical). This is the number that says whether you're short of memory, not a percentage |
| Network | 64-bit interface counters (`NET_RT_IFLIST2`) | Physical links only: loopback, VPN tunnels and the T2 chip's internal link are excluded. The graph switches between kbps and Mbps as traffic changes |
| Storage | `mountedVolumeURLs`, Disk Arbitration | Every volume Finder shows, external and flash drives included. Free space counts purgeable space, like Finder. Decimal GB |
| GPU | IOKit `PerformanceStatistics` | Per GPU. Read directly, not through a 5 MB `ioreg` dump |
| Temperatures, fans | SMC, read-only | Shown as "Not reported" when a Mac doesn't expose a sensor. Never estimated |
| Apps & processes | libproc | Physical footprint per app, helpers grouped under their app, scripts labelled (`node server/server.js` in `~/Desktop/AEON`). Only your own processes: other users' need admin rights |

## Safety

- The page talks to the app only through WebKit's private message channel. Web pages and other
  programs can't reach MacSense's actions.
- **Quit** is ⌘Q for apps and SIGTERM for other processes; **Force quit** is SIGKILL. Both ask
  first. Before signalling anything, the app checks each PID's start time again, so a stale row
  can't hit a process that has reused its PID. `loginwindow`, `WindowServer`, `launchd` and
  MacSense itself can't be quit from here.
- **Eject** only works on a volume MacSense itself listed as ejectable.
- The page loads only its own bundled files, under a Content-Security-Policy that allows no
  network access.
- MacSense doesn't delete files. v1's "Disk Cleanup" ran `rm -rf ~/Library/Caches/*`. It's gone;
  **Manage storage…** opens System Settings instead.

## Build

Needs only the Xcode Command Line Tools.

```bash
./build.sh              # universal (Intel + Apple silicon) build in build/MacSense.app
./build.sh --install    # also installs ~/Desktop/MacSense.app (only ever replaces a MacSense build)
ARCHS=x86_64 ./build.sh # one architecture, faster while iterating
```

`tools/make_icon.swift` draws the icon from code at build time.

## Checking it from the command line

```bash
build/MacSense.app/Contents/MacOS/MacSense --dump --count 3     # samples as JSON, no window
build/MacSense.app/Contents/MacOS/MacSense --smc-probe          # which sensors this Mac has
build/MacSense.app/Contents/MacOS/MacSense --snapshot out.png   # screenshot of the window after 5 s
build/MacSense.app/Contents/MacOS/MacSense --verbose            # log each sample to stderr
```

## History

v1 (tag `v1`) was a Python web server on `127.0.0.1:58249`. It was analysed and retired on
2026-09-22 because:
- its RAM alarm stayed on CRITICAL permanently, because cached files counted as used;
- it read the sealed system snapshot instead of your data volume;
- it spent a full CPU core on an `ioreg` dump every 1.5 seconds;
- any web page could trigger its kill and delete endpoints.

Run `git show v1:app.py` to see it.
