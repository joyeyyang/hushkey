import AppKit
import ApplicationServices

/// Inserts text into whatever field is focused, by putting it on the pasteboard
/// and posting a synthesised ⌘V.
///
/// This is the delivery half of the voice-input method, lifted from the app's
/// `TextInjector.swift`. It is kept opt-in by design: posting a key event to
/// another app needs the Accessibility permission, and a caller that only wants
/// a transcript should never have to ask for it. When permission is missing the
/// text is still placed on the pasteboard and the call returns `false`, so
/// nothing is lost — it degrades to "copy, and let the user paste".
///
/// The app used a richer result type (`.pasted` / `.needsPermission` /
/// `.copiedOnly`) because it had a HUD to explain each. A library caller does
/// not, so `Bool` is the whole contract here; `lastOutcome` is offered for the
/// rare caller that wants to know *why* it did not paste.
public enum CursorInserter {

    /// Why the last `insert` succeeded or failed. Kept out of the return value
    /// so the common path stays a plain `Bool`.
    public enum Outcome: String, Sendable {
        case pasted
        case needsPermission
        case empty
        case eventFailed
    }

    /// Set by `insert`, readable afterwards. Not thread-safe; it exists for
    /// logging and for a caller that wants a one-line reason.
    public private(set) static var lastOutcome: Outcome = .empty

    /// True when this process may post synthetic events.
    public static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Prompts the system Accessibility dialog. This is also the only supported
    /// way to get the calling process *listed* in that pane with the signature
    /// it is running now; dragging a bundle in by hand registers whichever copy
    /// the user picked, which after a rebuild may not be the one running.
    public static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Places `text` on the pasteboard and, if permitted, pastes it.
    ///
    /// Returns `false` when the text was empty, when Accessibility is not
    /// granted, or when the event could not be created. In the permission case
    /// the text remains on the pasteboard.
    @discardableResult
    public static func insert(_ text: String, restoreClipboard: Bool = true) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastOutcome = .empty
            return false
        }
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        _ = pb.clearContents()
        _ = pb.setString(trimmed, forType: .string)

        guard hasAccessibility else {
            requestAccessibility()
            lastOutcome = .needsPermission
            return false
        }
        guard postCommandV() else {
            lastOutcome = .eventFailed
            return false
        }

        // Restore the previous clipboard shortly after the paste is consumed, so
        // using the kit does not silently clobber what the user had copied.
        if restoreClipboard, let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                _ = pb.clearContents()
                _ = pb.setString(previous, forType: .string)
            }
        }
        lastOutcome = .pasted
        return true
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

/// Free-function form of `CursorInserter.insert`, for callers that treat
/// delivery as one step of a pipeline. Returns `false` rather than throwing,
/// because a failed paste must never lose a transcript that already exists.
@discardableResult
public func insertAtCursor(_ text: String) -> Bool {
    CursorInserter.insert(text)
}
