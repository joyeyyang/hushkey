import Carbon.HIToolbox
import Foundation

/// A parsed global hotkey: one non-modifier key plus one or more modifiers.
/// Display strings look like "Option+Space" or "Control+Shift+R".
struct HotkeySpec: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    /// Carbon virtual key codes for the keys we accept in a hotkey string.
    private static let keyCodes: [String: Int] = [
        "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return,
        "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
        "delete": kVK_Delete, "backspace": kVK_Delete,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    /// Parses e.g. "Option+Space", "cmd+shift+r", or the glyph form "⌃⌥P".
    /// Returns nil for an unknown key or when no modifier is present (bare keys
    /// are too intrusive).
    static func parse(_ raw: String) -> HotkeySpec? {
        let glyphModifiers: [Character: UInt32] = [
            "⌃": UInt32(controlKey), "⌥": UInt32(optionKey),
            "⌘": UInt32(cmdKey), "⇧": UInt32(shiftKey),
        ]

        // Peel leading modifier glyphs so "⌃⌥P" works as well as "⌃+⌥+P".
        var glyphMods: UInt32 = 0
        var body = raw.trimmingCharacters(in: .whitespaces)
        while let first = body.first, let m = glyphModifiers[first] {
            glyphMods |= m
            body.removeFirst()
        }

        let parts = body
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var modifiers: UInt32 = glyphMods
        var keyName: String?
        for (i, part) in parts.enumerated() {
            switch part.lowercased() {
            case "option", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "command", "cmd", "⌘": modifiers |= UInt32(cmdKey)
            case "control", "ctrl", "⌃": modifiers |= UInt32(controlKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            default:
                // Only the last token may be the actual key.
                guard i == parts.count - 1, keyName == nil else { return nil }
                keyName = part.lowercased()
            }
        }
        guard modifiers != 0, let key = keyName, let code = keyCodes[key] else { return nil }
        return HotkeySpec(keyCode: UInt32(code), modifiers: modifiers, display: display(modifiers: modifiers, key: key))
    }

    private static func display(modifiers: UInt32, key: String) -> String {
        var names: [String] = []
        if modifiers & UInt32(controlKey) != 0 { names.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { names.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { names.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { names.append("Command") }
        let pretty = key.count == 1 ? key.uppercased() : key.prefix(1).uppercased() + key.dropFirst()
        names.append(pretty)
        return names.joined(separator: "+")
    }
}

/// Global hotkey using Carbon RegisterEventHotKey. This does not require
/// Accessibility permission. The key binding can be changed at runtime; each
/// `register` call replaces any previous binding.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void
    private static var instance: Hotkey?

    /// The currently registered spec, or nil when unregistered.
    private(set) var spec: HotkeySpec?

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    /// Registers the string form (e.g. "Option+Space"). Returns false for an
    /// unparseable spec or when Carbon rejects the registration.
    @discardableResult
    func register(_ specString: String) -> Bool {
        guard let parsed = HotkeySpec.parse(specString) else { return false }
        return register(parsed)
    }

    @discardableResult
    func register(_ newSpec: HotkeySpec) -> Bool {
        unregister()
        Hotkey.instance = self
        spec = newSpec

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                Hotkey.instance?.onPress()
                return noErr
            },
            1, &eventSpec, nil, &handler
        )
        guard status == noErr else { spec = nil; return false }

        let id = EventHotKeyID(signature: OSType(0x4F564331), id: 1) // 'OVC1'
        let reg = RegisterEventHotKey(
            newSpec.keyCode, newSpec.modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if reg != noErr {
            // Roll back the handler so a failed rebind does not leave a live one.
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        spec = nil
        Hotkey.instance = nil
    }
}
