import AppKit

/// Menu bar status item — the entry point that (re)opens the main control
/// window. Left click opens the window; right click shows a small menu with
/// Open and Quit. It never quits the app on its own.
final class StatusItem {
    private let item: NSStatusItem
    private let onOpen: () -> Void
    private let onExport: () -> Void
    private let onQuit: () -> Void

    init(onOpen: @escaping () -> Void, onExport: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onExport = onExport
        self.onQuit = onQuit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "OfflineVoiceAssistant")
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if secondary {
            showMenu()
        } else {
            onOpen()
        }
    }

    /// Shows the menu only for this click, so a normal left click keeps opening
    /// the window instead of popping a menu.
    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "開啟主視窗", action: #selector(openAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let export = NSMenuItem(title: "匯出最近一次逐字稿…", action: #selector(exportAction), keyEquivalent: "")
        export.target = self
        menu.addItem(export)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "結束 Offline Voice Assistant", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openAction() { onOpen() }
    @objc private func exportAction() { onExport() }
    @objc private func quitAction() { onQuit() }

    /// Recording-state indicator: a red record glyph while capturing,
    /// the normal waveform icon otherwise.
    func updateState(dictating: Bool, meeting: Bool) {
        let recording = dictating || meeting
        let symbol = recording ? "record.circle.fill" : "waveform"
        let desc = recording ? "Recording" : "OfflineVoiceAssistant"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
        item.button?.image?.isTemplate = true
        item.button?.contentTintColor = recording ? .systemRed : nil
    }
}
