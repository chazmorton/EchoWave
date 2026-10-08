import Carbon.HIToolbox

/// Registers system-wide hotkeys through Carbon, reporting both key-down and key-up
/// so shortcuts can be used as push-to-talk. Needs no special permissions.
@MainActor
final class HotkeyManager {
    typealias Handler = @MainActor (_ isPressed: Bool) -> Void

    fileprivate nonisolated static let signature: OSType = 0x4557_4156 // 'EWAV'

    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: Handler] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyEventCallback, eventTypes.count, &eventTypes,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// Returns false when the shortcut can't be registered, usually because another app owns it.
    @discardableResult
    func register(_ shortcut: KeyShortcut, id: UInt32, handler: @escaping Handler) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeys[id] = ref
        handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        if let ref = hotKeys.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers[id] = nil
    }

    fileprivate func handle(id: UInt32, isPressed: Bool) {
        handlers[id]?(isPressed)
    }
}

private func hotKeyEventCallback(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }

    let isPressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handle(id: hotKeyID.id, isPressed: isPressed)
    }
    return noErr
}
