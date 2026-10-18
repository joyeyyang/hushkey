import AppKit
import ApplicationServices

/// Inserts text into the focused field.
/// Primary: place text on the pasteboard, post Cmd+V via CGEvent. Requires Accessibility permission.
/// Fallback: leave text on the pasteboard and report `.copiedOnly` so the user can paste manually.
enum InjectionResult {
    case pasted
    /// Accessibility is not granted, so the text was only copied. Distinct from
    /// `.copiedOnly` so the caller can surface the fix instead of a bare note.
    case needsPermission(reason: String)
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
            requestAccessibility()
            return .needsPermission(reason: "未取得輔助使用權限，無法自動貼上（文字已複製）。請到「系統設定 → 隱私權與安全性 → 輔助使用」開啟 OfflineVoiceAssistant，再重新試一次")
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
