import AppKit

/// A transparent strip over the page's header, so the window can be dragged by its top edge like any
/// Mac window. Double-click follows the user's System Settings choice (zoom, minimise or nothing).
final class DragStrip: NSView {
    static let height: CGFloat = 52

    /// Set by the self-test to confirm clicks reach the strip rather than the page.
    var onMouseDown: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
            case "Minimize": window?.performMiniaturize(nil)
            case "None": break
            default: window?.performZoom(nil)
            }
            return
        }
        window?.performDrag(with: event)
    }
}
