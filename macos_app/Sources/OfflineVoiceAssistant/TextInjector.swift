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
    ///
    /// This is also the only supported way to get the app *listed* in that pane
    /// with the signature it is running now; dragging the bundle in by hand
    /// registers whichever copy the user picked, which after a rebuild may not be
    /// the one that is running.
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// What TCC is being asked about, for the log. "Which app did I grant?" is
    /// the first question when the switch looks on and the API says no.
    static var identity: String {
        let bundle = Bundle.main
        return "\(bundle.bundlePath) id=\(bundle.bundleIdentifier ?? "?") trusted=\(hasAccessibility)"
    }

    /// Deletes this bundle's Accessibility row.
    ///
    /// A grant is bound to the code signature, and rebuilding in place changes
    /// it. macOS then keeps the old row: the switch shows ON, cannot be switched
    /// off and on again (the row's code requirement no longer matches anything
    /// running), and every check still fails. Removing the row is the only way
    /// out, and `tccutil` is the only tool for it that does not need the user to
    /// hunt through the list. Returns the exit status, 0 on success.
    static func resetAccessibility() -> Int32 {
        guard let id = Bundle.main.bundleIdentifier else { return -1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", id]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
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
