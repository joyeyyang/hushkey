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

    /// Replaces the text this app pasted last, in place.
    ///
    /// A spoken edit ("第二點改成禮拜五") has to land where the original went, so
    /// the characters have to be found in someone else's editor: the paste that
    /// put them there was the app's last contact with them, and the only handle
    /// left is the Accessibility value of the focused element. The search is
    /// deliberately strict -- the exact string that was inserted, ending at or
    /// before the caret -- because the failure that matters is not "could not
    /// replace" (the result is on the clipboard either way) but "replaced the
    /// wrong thing".
    static func replaceLastInsertion(expected: String, with replacement: String) -> InjectionResult {
        // First, not last: every failure path below tells the user the result is
        // on the clipboard, and a field whose text cannot be read or selected
        // leaves pasting it by hand as the only way to use the edit at all.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)

        guard hasAccessibility else {
            requestAccessibility()
            return .needsPermission(reason: "未取得輔助使用權限，無法自動取代（編輯結果已複製）。請到「系統設定 → 隱私權與安全性 → 輔助使用」開啟 OfflineVoiceAssistant，再重新試一次")
        }
        guard let element = focusedElement(), let text = stringAttribute(element, kAXValueAttribute as CFString) else {
            return .copiedOnly(reason: "這個 App 不提供文字內容，無法自動取代（編輯結果已複製）")
        }
        guard let range = locateInsertion(expected, in: text as NSString, element: element) else {
            return .copiedOnly(reason: "找不到剛剛貼上的文字，無法自動取代（編輯結果已複製）")
        }
        guard select(range, in: element) else {
            return .copiedOnly(reason: "無法選取剛剛貼上的文字，編輯結果已複製")
        }
        return insert(replacement)
    }

    /// The system-wide focused element, i.e. whatever editor the user is typing in.
    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }
        return (element as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? String
    }

    private static func rangeAttribute(_ element: AXUIElement, _ name: CFString) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Where the insertion sits: the last occurrence of `expected` at or before
    /// the caret. Offsets are UTF-16 units, which is what an AX text range counts
    /// in, so `NSString` and not `String` does the searching.
    private static func locateInsertion(_ expected: String, in text: NSString, element: AXUIElement) -> NSRange? {
        guard !expected.isEmpty, text.length > 0 else { return nil }
        let caret = rangeAttribute(element, kAXSelectedTextRangeAttribute as CFString)
        let limit = min(text.length, caret.map { $0.location + $0.length } ?? text.length)
        guard limit > 0 else { return nil }
        let found = text.range(of: expected, options: .backwards, range: NSRange(location: 0, length: limit))
        return found.location == NSNotFound ? nil : found
    }

    /// Selects `range`, and waits for the target app to agree before returning:
    /// the selection is applied on that app's own thread, and a Cmd+V that
    /// arrived first would paste at the old caret -- appending the edit instead
    /// of replacing the text it corrects.
    private static func select(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
            return false
        }
        for _ in 0..<20 {
            if rangeAttribute(element, kAXSelectedTextRangeAttribute as CFString) == range { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
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
