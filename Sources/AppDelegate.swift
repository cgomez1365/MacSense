import AppKit
import WebKit

/// One window holding a WKWebView. The page talks to the app only through WebKit's private
/// message channel: there is no HTTP server and no open port, so nothing else on this Mac,
/// and no website, can reach MacSense's actions.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, WKNavigationDelegate {
    private let options: LaunchOptions
    private let monitor = Monitor()
    private var window: NSWindow!
    private var webView: WKWebView!
    private var bridge: ScriptBridge?
    private var pageReady = false
    private lazy var uiDirectory = Bundle.main.bundleURL.absoluteURL
        .appendingPathComponent("Contents/Resources/UI", isDirectory: true).standardizedFileURL

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
        buildWindow()
        watchVolumes()
        monitor.start { [weak self] payload in
            DispatchQueue.main.async { self?.push(payload) }
        }
        if let path = options.snapshotPath { scheduleSnapshot(to: path) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Window

    private func buildWindow() {
        let size = options.size ?? NSSize(width: 1280, height: 860)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "MacSense"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty unified toolbar makes the title bar 52pt tall; the page draws its header under it.
        window.toolbar = NSToolbar(identifier: "MacSenseToolbar")
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(srgbRed: 9 / 255, green: 11 / 255, blue: 16 / 255, alpha: 1)   // --page
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if options.size == nil {
            window.setFrameAutosaveName("MacSenseMain")
            if !window.setFrameUsingName("MacSenseMain") { window.center() }
        } else {
            window.center()
        }
        window.level = UserDefaults.standard.bool(forKey: "keepOnTop") ? .floating : .normal

        let configuration = WKWebViewConfiguration()
        let bridge = ScriptBridge(owner: self)
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "macsense")
        self.bridge = bridge
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { webView.isInspectable = options.inspectable }
        webView.isHidden = true   // shown once the page has painted, so there's no white flash
        window.contentView!.addSubview(webView)
        webView.loadFileURL(uiDirectory.appendingPathComponent("index.html"), allowingReadAccessTo: uiDirectory)

        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    private func watchVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [monitor] _ in monitor.volumesChanged() }
        }
    }

    private func push(_ payload: Payload) {
        if options.verbose { log("sample \(payload.value["t"] ?? "?") ready; page \(pageReady ? "ready" : "not ready")") }
        guard pageReady else { return }
        webView.callAsyncJavaScript("window.MacSense && window.MacSense.onSample(sample)",
                                    arguments: ["sample": payload.value], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { self?.log("sample not delivered to the page: \(error)") }
        }
    }

    // MARK: - Page

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        webView.isHidden = false
        monitor.pageReloaded()
        webView.callAsyncJavaScript("window.MacSense && window.MacSense.init(info)",
                                    arguments: ["info": SystemInfo.collect()], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { self?.log("page setup failed: \(error)") }
        }
    }

    /// The page may only ever show MacSense's own bundled files.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let uiPath = uiDirectory.resolvingSymlinksInPath().path
        let target = navigationAction.request.url
        let allowed = target.map { $0.isFileURL && $0.resolvingSymlinksInPath().path.hasPrefix(uiPath) } ?? false
        if !allowed { log("blocked navigation to \(target?.absoluteString ?? "nothing") (only \(uiPath) is allowed)") }
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("page failed: \(error.localizedDescription)")
    }

    /// Problems go to stderr (and Console.app), never nowhere.
    private func log(_ message: String) {
        FileHandle.standardError.write(Data("MacSense: \(message)\n".utf8))
    }

    /// If WebKit's content process dies, reload rather than leave a blank window.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        webView.reload()
    }

    /// Requests from the page. Each one is checked again on this side before anything happens.
    func handle(type: String, body: [String: Any], reply: @escaping (Bool, String) -> Void) {
        let box = ReplyBox(reply)
        let answer: @Sendable (Bool, String) -> Void = { ok, message in
            DispatchQueue.main.async { box.send(ok, message) }
        }
        switch type {
        case "quit":
            guard let key = body["key"] as? String else { return reply(false, "Nothing selected.") }
            monitor.quit(key: key, force: body["force"] as? Bool ?? false, reply: answer)
        case "eject":
            guard let path = body["path"] as? String else { return reply(false, "No drive selected.") }
            monitor.eject(path: path, reply: answer)
        case "reveal":
            guard let path = body["path"] as? String, FileManager.default.fileExists(atPath: path) else {
                return reply(false, "That drive isn't mounted any more.")
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            reply(true, "")
        case "storageSettings":
            let opened = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
            reply(opened, opened ? "" : "Couldn't open Storage settings.")
        case "activityMonitor":
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                               configuration: NSWorkspace.OpenConfiguration()) { _, error in
                answer(error == nil, error?.localizedDescription ?? "")
            }
        default:
            reply(false, "MacSense doesn't know how to do that.")
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        let app = submenu("MacSense")
        app.addItem(withTitle: "About MacSense", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide MacSense", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit MacSense", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = submenu("Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu("View")
        let onTop = view.addItem(withTitle: "Keep on Top", action: #selector(toggleKeepOnTop(_:)), keyEquivalent: "t")
        onTop.keyEquivalentModifierMask = [.command, .shift]
        onTop.target = self
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let windows = submenu("Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    @objc private func toggleKeepOnTop(_ sender: NSMenuItem) {
        let enabled = window.level != .floating
        window.level = enabled ? .floating : .normal
        UserDefaults.standard.set(enabled, forKey: "keepOnTop")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleKeepOnTop(_:)) {
            menuItem.state = window?.level == .floating ? .on : .off
        }
        return true
    }

    // MARK: - Snapshot (for checking the UI from the command line)

    private func scheduleSnapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + options.snapshotDelay) { [self] in
            let capture = { [self] in
                webView.takeSnapshot(with: nil) { image, error in
                    if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        do {
                            try png.write(to: URL(fileURLWithPath: path))
                            print("snapshot saved: \(path)")
                        } catch {
                            print("snapshot failed: \(error.localizedDescription)")
                        }
                    } else {
                        print("snapshot failed: \(error?.localizedDescription ?? "no image")")
                    }
                    NSApp.terminate(nil)
                }
            }
            // The script is an async function body: it can await, and whatever it returns is printed.
            guard let script = options.evalScript else { return capture() }
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): print("eval: \(value)")
                case .failure(let error): print("eval failed: \(error)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { capture() }
            }
        }
    }
}

struct ReplyBox: @unchecked Sendable {
    let send: (Bool, String) -> Void
    init(_ send: @escaping (Bool, String) -> Void) { self.send = send }
}

/// Receives the page's requests. Holds the app delegate weakly so the web view doesn't keep it alive.
final class ScriptBridge: NSObject, WKScriptMessageHandlerWithReply {
    private weak var owner: AppDelegate?

    init(owner: AppDelegate) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let owner, let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return replyHandler(["ok": false, "message": "MacSense ignored an unrecognised request."], nil)
        }
        owner.handle(type: type, body: body) { ok, text in replyHandler(["ok": ok, "message": text], nil) }
    }
}
