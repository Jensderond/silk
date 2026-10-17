import Carbon.HIToolbox
import Foundation

/// Modifier keys of a global hotkey.
public struct HotkeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let cmd = HotkeyModifiers(rawValue: 1 << 0)
    public static let alt = HotkeyModifiers(rawValue: 1 << 1)
    public static let ctrl = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)

    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.cmd) { flags |= UInt32(cmdKey) }
        if contains(.alt) { flags |= UInt32(optionKey) }
        if contains(.ctrl) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}

/// A global hotkey: virtual key code (`kVK_*`) plus modifiers, identified by a caller-chosen id.
public struct Hotkey: Hashable, Sendable {
    public var id: UInt32
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers

    public init(id: UInt32, keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// A hotkey that could not be registered.
public struct HotkeyRegistrationFailure: Error, Hashable, Sendable {
    public var hotkey: Hotkey
    public var status: OSStatus
    /// The combination is already registered (typically by another app).
    public var isAlreadyTaken: Bool { status == eventHotKeyExistsErr }
}

/// Global hotkeys via Carbon `RegisterEventHotKey` (needs no Input Monitoring permission; stops
/// working while secure input is on). Main thread only; requires a running main event loop.
public final class HotkeyCenter {
    private static let signature: OSType = 0x5349_4C4B // 'SILK'

    private var eventHandler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    /// Carbon id → caller id. Carbon ids are never reused, so an event queued before a
    /// replacement can't trigger a binding of the new set.
    private var callerIDs: [UInt32: UInt32] = [:]
    private var nextCarbonID: UInt32 = 1
    private var handler: ((UInt32) -> Void)?

    public init() {}

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Replaces the whole set of registered hotkeys (e.g. on a binding-mode switch). `handler` is
    /// called on the main thread with the ``Hotkey/id`` of the pressed hotkey. Returns the hotkeys
    /// that could not be registered; all others are active.
    @discardableResult
    public func replaceAll(with hotkeys: [Hotkey], handler: @escaping (UInt32) -> Void) -> [HotkeyRegistrationFailure] {
        dispatchPrecondition(condition: .onQueue(.main))
        installEventHandlerIfNeeded()
        unregisterAll()
        self.handler = handler
        var failures: [HotkeyRegistrationFailure] = []
        for hotkey in hotkeys {
            let carbonID = nextCarbonID
            nextCarbonID &+= 1
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                hotkey.keyCode, hotkey.modifiers.carbonFlags, EventHotKeyID(signature: Self.signature, id: carbonID),
                GetApplicationEventTarget(), 0, &reference
            )
            if status == noErr, let reference {
                registrations.append(reference)
                callerIDs[carbonID] = hotkey.id
            } else {
                failures.append(HotkeyRegistrationFailure(hotkey: hotkey, status: status))
            }
        }
        return failures
    }

    /// Unregisters every hotkey.
    public func unregisterAll() {
        for reference in registrations { UnregisterEventHotKey(reference) }
        registrations = []
        callerIDs = [:]
        handler = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID
            )
            guard status == noErr, hotkeyID.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue().pressed(carbonID: hotkeyID.id)
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func pressed(carbonID: UInt32) {
        guard let id = callerIDs[carbonID] else { return }
        handler?(id)
    }
}
