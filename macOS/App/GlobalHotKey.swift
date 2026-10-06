import AppKit
import Carbon

/// Registers Option + Space without a keyboard event tap or input-monitoring permission.
/// Keep this object alive while the shortcut is enabled. A false result from `start()`
/// means the shortcut is unavailable; keep the app's menu entry usable in that case.
@MainActor
final class GlobalHotKey: NSObject {
    /// The exact Carbon status from the latest registration attempt (zero means success).
    /// -9878 is eventHotKeyExistsErr; other errors must not be reported as a conflict.
    private(set) var lastError: OSStatus = noErr
    private let onTrigger: () -> Void
    private var registration: HotKeyRegistration?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        super.init()
    }

    /// Safe to call more than once. Registration is exclusive, so another app's
    /// existing shortcut is not also triggered by this application's shortcut.
    @discardableResult
    func start() -> Bool {
        if registration != nil {
            lastError = noErr
            return true
        }

        let context = HotKeyContext(owner: self)
        let pending = HotKeyRegistration(context: context)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData,
                      GetEventClass(event) == OSType(kEventClassKeyboard),
                      GetEventKind(event) == UInt32(kEventHotKeyPressed) else {
                    return OSStatus(eventNotHandledErr)
                }
                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                guard parameterStatus == noErr,
                      hotKeyID.signature == 0x48414957, hotKeyID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                // Application-target Carbon events are dispatched by the main run loop.
                let context = Unmanaged<HotKeyContext>.fromOpaque(userData).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    guard let owner = context.owner else {
                        return OSStatus(eventNotHandledErr)
                    }
                    owner.onTrigger()
                    return noErr
                }
            },
            1, &eventType, Unmanaged.passUnretained(context).toOpaque(), &pending.handler
        )
        guard handlerStatus == noErr else {
            lastError = handlerStatus
            pending.invalidate()
            return false
        }

        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(optionKey),
            EventHotKeyID(signature: 0x48414957, id: 1), // "HAIW"
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &pending.hotKey
        )
        guard hotKeyStatus == noErr else {
            lastError = hotKeyStatus
            pending.invalidate()
            return false
        }
        registration = pending
        lastError = noErr
        return true
    }

    func stop() {
        registration?.invalidate()
        registration = nil
    }

    deinit {
        // Actor-isolated objects can receive their final release off the main thread.
        // Keep the registration and callback context alive until main-thread cleanup.
        let pending = registration
        if Thread.isMainThread {
            MainActor.assumeIsolated { pending?.invalidate() }
        } else {
            Task { @MainActor in pending?.invalidate() }
        }
    }
}

/// Carbon borrows the context pointer. The registration owns it until removal, and
/// a weak owner prevents a retain cycle or callback into a deinitialized controller.
private final class HotKeyContext: @unchecked Sendable {
    @MainActor weak var owner: GlobalHotKey?

    @MainActor init(owner: GlobalHotKey) {
        self.owner = owner
    }
}

/// The unchecked conformance only permits transfer to the main actor during deinit.
/// Every Carbon access and reference mutation still occurs on the main actor.
private final class HotKeyRegistration: @unchecked Sendable {
    let context: HotKeyContext
    @MainActor var handler: EventHandlerRef?
    @MainActor var hotKey: EventHotKeyRef?

    init(context: HotKeyContext) {
        self.context = context
    }

    @MainActor func invalidate() {
        context.owner = nil
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }
}
