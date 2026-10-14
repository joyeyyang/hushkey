import Carbon.HIToolbox
import Foundation

/// Global Option+Space hotkey using Carbon RegisterEventHotKey.
/// This does not require Accessibility permission (verified only by compilation in this environment).
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void
    private static var instance: Hotkey?

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    func register() -> Bool {
        Hotkey.instance = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                Hotkey.instance?.onPress()
                return noErr
            },
            1, &spec, nil, &handler
        )
        guard status == noErr else { return false }

        let id = EventHotKeyID(signature: OSType(0x4F564331), id: 1) // 'OVC1'
        let reg = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(optionKey), id,
            GetApplicationEventTarget(), 0, &ref
        )
        return reg == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        Hotkey.instance = nil
    }
}
