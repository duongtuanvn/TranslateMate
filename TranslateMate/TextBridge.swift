import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Đọc và ghi văn bản đang được chọn ở app đang focus.
///
/// Toàn bộ method là `async` + dùng `Task.sleep` thay vì `Thread.sleep` để
/// KHÔNG block main thread → UI luôn responsive trong khi dịch.
///
/// Chiến lược ghi text:
/// 1. Đọc: `kAXSelectedTextAttribute` → fallback clipboard + Cmd+C
/// 2. Ghi:
///    a. Check `kAXSelectedTextAttribute` có `settable` không
///    b. Nếu có → set, rồi READ BACK verify (vài app như Telegram/Discord/Electron
///       trả `success` nhưng thực tế không apply)
///    c. Nếu unchanged/fail → thử `kAXValueAttribute`
///    d. Fail tất cả → backup pasteboard, set clipboard, Cmd+V, restore pasteboard
enum TextBridge {

    struct Capture {
        let text: String
        let axElement: AXUIElement?
        let targetPID: pid_t?
        let originalPasteboardString: String?
    }

    /// Timeout cho AX calls - 2 giây đủ cho Electron chậm.
    private static let axTimeoutSeconds: Float = 2.0

    // MARK: - Read

    static func captureFocusedSelection() async -> Capture? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let pid = frontApp?.processIdentifier
        let name = frontApp?.localizedName ?? "?"
        AppLogger.shared.info("Frontmost app at capture: \(name) (pid=\(pid ?? -1))")

        if let ax = captureViaAX(pid: pid) {
            AppLogger.shared.info("Capture: \(ax.text.count) chars via AX from pid=\(pid ?? -1)")
            return ax
        }
        AppLogger.shared.warn("Capture: AX failed, falling back to clipboard (Cmd+C)")
        if let pb = await captureViaClipboard(pid: pid) {
            AppLogger.shared.info("Capture: \(pb.text.count) chars via clipboard from pid=\(pid ?? -1)")
            return pb
        }
        AppLogger.shared.error("Capture: both AX and clipboard returned nothing")
        return nil
    }

    private static func captureViaAX(pid: pid_t?) -> Capture? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axTimeoutSeconds)

        var focusedAppRef: CFTypeRef?
        let r1 = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef)
        guard r1 == .success, let focusedAppCF = focusedAppRef else {
            AppLogger.shared.warn("AX: kAXFocusedApplicationAttribute failed: \(ax(r1))")
            return nil
        }
        let focusedApp = focusedAppCF as! AXUIElement
        AXUIElementSetMessagingTimeout(focusedApp, axTimeoutSeconds)

        var focusedElementRef: CFTypeRef?
        let r2 = AXUIElementCopyAttributeValue(focusedApp, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        guard r2 == .success, let focusedElementCF = focusedElementRef else {
            AppLogger.shared.warn("AX: kAXFocusedUIElementAttribute failed: \(ax(r2))")
            return nil
        }
        let focusedElement = focusedElementCF as! AXUIElement
        AXUIElementSetMessagingTimeout(focusedElement, axTimeoutSeconds)

        logFocusedEditor(focusedElement)

        var selectedTextRef: CFTypeRef?
        let r3 = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedTextRef)
        if r3 == .success, let selectedText = selectedTextRef as? String, !selectedText.isEmpty {
            return Capture(text: selectedText, axElement: focusedElement, targetPID: pid, originalPasteboardString: nil)
        }
        AppLogger.shared.warn("AX: kAXSelectedTextAttribute read result=\(ax(r3))")
        return nil
    }

    private static func captureViaClipboard(pid: pid_t?) async -> Capture? {
        let pb = NSPasteboard.general
        let backup = backupPasteboard(pb)
        let snapshotCount = pb.changeCount

        pb.clearContents()
        simulate(keyCode: CGKeyCode(kVK_ANSI_C), withCommand: true)

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if pb.changeCount != snapshotCount, let s = pb.string(forType: .string), !s.isEmpty {
                restorePasteboard(pb, items: backup)
                return Capture(text: s, axElement: nil, targetPID: pid, originalPasteboardString: nil)
            }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms - non-blocking
        }
        restorePasteboard(pb, items: backup)
        AppLogger.shared.warn("Clipboard unchanged after Cmd+C — no selection in frontmost app")
        return nil
    }

    // MARK: - Write

    static func replaceSelection(capture: Capture, with newText: String, forceClipboard: Bool = false) async {
        await reactivateTargetApp(pid: capture.targetPID)

        let element = capture.axElement

        if forceClipboard {
            AppLogger.shared.info("forceClipboardPaste=true, skipping AX set")
            await clipboardPaste(newText)
            return
        }

        guard let element else {
            AppLogger.shared.info("No AX element (clipboard capture) → clipboard paste")
            await clipboardPaste(newText)
            return
        }

        AXUIElementSetMessagingTimeout(element, axTimeoutSeconds)

        if await trySetAttribute(element, kAXSelectedTextAttribute, to: newText, expectedContains: newText) {
            AppLogger.shared.info("Replaced via kAXSelectedTextAttribute (verified)")
            return
        }
        if await trySetAttribute(element, kAXValueAttribute, to: newText, expectedContains: newText) {
            AppLogger.shared.info("Replaced via kAXValueAttribute (verified)")
            return
        }

        AppLogger.shared.warn("All AX writes failed or unchanged — falling back to clipboard paste")
        await clipboardPaste(newText)
    }

    private static func trySetAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        to newValue: String,
        expectedContains: String
    ) async -> Bool {
        var settable: DarwinBoolean = false
        let rSettable = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        if rSettable != .success || !settable.boolValue {
            AppLogger.shared.warn("\(attribute): not settable (r=\(ax(rSettable)), settable=\(settable.boolValue))")
            return false
        }

        let rSet = AXUIElementSetAttributeValue(element, attribute as CFString, newValue as CFString)
        if rSet != .success {
            AppLogger.shared.warn("\(attribute): set failed (r=\(ax(rSet)))")
            return false
        }

        // Đợi UI update — non-blocking
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        var readBack: CFTypeRef?
        let rRead = AXUIElementCopyAttributeValue(element, attribute as CFString, &readBack)
        guard rRead == .success, let current = readBack as? String else {
            AppLogger.shared.info("\(attribute): set OK but cannot verify (read r=\(ax(rRead))) - assuming success")
            return true
        }

        if attribute == kAXSelectedTextAttribute {
            var fullValueRef: CFTypeRef?
            let rFull = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fullValueRef)
            if rFull == .success, let full = fullValueRef as? String {
                if full.contains(expectedContains) { return true }
                AppLogger.shared.warn("\(attribute): set returned success but value unchanged (Telegram/Electron lie detected)")
                return false
            }
            return true
        } else {
            if current.contains(expectedContains) { return true }
            AppLogger.shared.warn("\(attribute): set returned success but value unchanged")
            return false
        }
    }

    // MARK: - Clipboard paste

    private static func clipboardPaste(_ text: String) async {
        let pb = NSPasteboard.general
        let backup = backupPasteboard(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Chờ clipboard ổn định + app focus xong - non-blocking
        try? await Task.sleep(nanoseconds: 120_000_000)  // 120ms
        simulate(keyCode: CGKeyCode(kVK_ANSI_V), withCommand: true)

        // Restore pasteboard sau 600ms (cho app paste xong)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            restorePasteboard(pb, items: backup)
            AppLogger.shared.info("Pasteboard restored")
        }

        let front = NSWorkspace.shared.frontmostApplication
        AppLogger.shared.info("Replaced via clipboard+Cmd+V (frontmost=\(front?.localizedName ?? "?") pid=\(front?.processIdentifier ?? -1))")
    }

    // MARK: - Pasteboard backup / restore

    private struct PasteboardItemSnapshot {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }

    private static func backupPasteboard(_ pb: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pb.pasteboardItems else { return [] }
        var out: [PasteboardItemSnapshot] = []
        for item in items {
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { data[type] = d }
            }
            out.append(PasteboardItemSnapshot(types: item.types, data: data))
        }
        return out
    }

    private static func restorePasteboard(_ pb: NSPasteboard, items: [PasteboardItemSnapshot]) {
        pb.clearContents()
        let newItems: [NSPasteboardItem] = items.map { snap in
            let item = NSPasteboardItem()
            for (type, d) in snap.data { item.setData(d, forType: type) }
            return item
        }
        if !newItems.isEmpty { pb.writeObjects(newItems) }
    }

    // MARK: - Helpers

    private static func reactivateTargetApp(pid: pid_t?) async {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
        if !app.isActive {
            let from = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            AppLogger.shared.info("Reactivating target: \(from) → \(app.localizedName ?? "?")")
            app.activate(options: [])
            // Poll non-blocking đến khi focus chuyển hoặc timeout 250ms
            let deadline = Date().addingTimeInterval(0.25)
            while Date() < deadline {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try? await Task.sleep(nanoseconds: 80_000_000) // chờ caret/selection khôi phục
        }
    }

    private static func simulate(keyCode: CGKeyCode, withCommand: Bool) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            AppLogger.shared.error("Failed to create CGEvent for key \(keyCode)")
            return
        }
        if withCommand {
            down.flags = .maskCommand
            up.flags = .maskCommand
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func logFocusedEditor(_ el: AXUIElement) {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "?"

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? "-"

        var settableSel: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settableSel)
        var settableVal: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settableVal)

        AppLogger.shared.info("Focused editor role=\(role) subrole=\(subrole) selectedText.settable=\(settableSel.boolValue) value.settable=\(settableVal.boolValue)")
    }

    private static func ax(_ err: AXError) -> String {
        switch err {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled(NO permission!)"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(err.rawValue))"
        }
    }
}
