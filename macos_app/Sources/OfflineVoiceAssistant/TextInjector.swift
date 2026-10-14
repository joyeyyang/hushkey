import AppKit
import ApplicationServices

/// Inserts text into the focused field.
/// Primary: place text on the pasteboard, post Cmd+V via CGEvent. Requires Accessibility permission.
/// Fallback: leave text on the pasteboard and report `.copiedOnly` so the user can paste manually.
enum InjectionResult {
    case pasted
    case copiedOnly(reason: String)
}

enum TextInjector {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Prompts the system Accessibility dialog. The user must enable the app in System Settings.
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func insert(_ text: String) -> InjectionResult {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard hasAccessibility else {
            return .copiedOnly(reason: "Accessibility permission not granted; text copied to clipboard")
        }
        guard postCommandV() else {
            return .copiedOnly(reason: "could not create CGEvent; text copied to clipboard")
        }

        // Restore the previous clipboard shortly after the paste has been consumed.
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
        return .pasted
    }

    private static func postCommandV() -> Bool {
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
