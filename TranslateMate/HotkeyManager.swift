import Foundation
import Carbon.HIToolbox


final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x544D4148 // 'TMAH' = TranslateMate

    /// ID duy nhất cho instance này. Khác nhau giữa các HotkeyManager.
    private let id: UInt32

    /// Bộ đếm tự tăng để tự động cấp ID khác nhau.
    private static var nextID: UInt32 = 1
    private static let idLock = NSLock()

    var onTrigger: (() -> Void)?

    init() {
        Self.idLock.lock()
        self.id = Self.nextID
        Self.nextID += 1
        Self.idLock.unlock()
    }

    @discardableResult
    func register(shortcut: HotkeyShortcut) -> Bool {
        unregister()

        // Cài event handler 1 lần đầu cho instance này.
        if eventHandler == nil {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                hotkeyHandler,
                1,
                &spec,
                selfPtr,
                &eventHandler
            )
            if status != noErr {
                NSLog("InstallEventHandler failed: \(status)")
                return false
            }
        }

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: self.id)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("RegisterEventHotKey failed: \(status) for id=\(self.id)")
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    deinit {
        unregister()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    /// ID getter để C handler check.
    fileprivate var instanceID: UInt32 { id }

    /// Fire onTrigger trên main queue.
    fileprivate func fire() {
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?()
        }
    }
}


private func hotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }

    var hotkeyID = EventHotKeyID()
    let getResult = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    if getResult != noErr { return OSStatus(eventNotHandledErr) }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

    // Nếu event không phải của instance này, KHÔNG consume - pass tiếp.
    if hotkeyID.id != manager.instanceID {
        return OSStatus(eventNotHandledErr)
    }

    manager.fire()
    return noErr
}
