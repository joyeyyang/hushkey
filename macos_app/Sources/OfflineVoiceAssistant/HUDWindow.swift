import AppKit

/// Floating capsule HUD shown above other windows. Non-activating, so it does not steal focus
/// from the target text field.
final class HUDWindow {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Draggable from anywhere on the panel; stays where the user puts it.
        panel.isMovableByWindowBackground = true
        panel.isMovable = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: panel.contentView!.bounds)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 28
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]
        panel.contentView = bg

        label.frame = bg.bounds.insetBy(dx: 16, dy: 10)
        label.autoresizingMask = [.width, .height]
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        bg.addSubview(label)
        // Hidden until a hotkey action shows it. Nothing is visible during model setup.
        panel.orderOut(nil)
    }

    private var placed = false

    func show(text: String) {
        label.stringValue = text
        // Place once at the default spot; afterwards keep the user's dragged position.
        if !placed, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 80))
            placed = true
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
