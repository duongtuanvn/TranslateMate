import Foundation
import AppKit
import Carbon.HIToolbox

/// Một tổ hợp phím (keyCode + modifiers) có thể serialize được.
struct HotkeyShortcut: Codable, Equatable {
    /// Virtual keycode (kVK_ANSI_D, kVK_ANSI_B, ...)
    var keyCode: UInt32
    /// Cocoa modifier mask (NSEvent.ModifierFlags.rawValue, filter tới deviceIndependentFlagsMask)
    var cocoaModifiers: UInt

    static let `default` = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_D),
        cocoaModifiers: NSEvent.ModifierFlags([.command]).rawValue
    )

    /// Default cho popup mode: ⌘⇧T
    static let popupDefault = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_T),
        cocoaModifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )

    /// Chuyển Cocoa modifiers -> Carbon modifier bitmask cho RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: cocoaModifiers)
        var mods: UInt32 = 0
        if flags.contains(.command)  { mods |= UInt32(cmdKey) }
        if flags.contains(.option)   { mods |= UInt32(optionKey) }
        if flags.contains(.control)  { mods |= UInt32(controlKey) }
        if flags.contains(.shift)    { mods |= UInt32(shiftKey) }
        return mods
    }

    /// Hiển thị đẹp, ví dụ: "⌘D" hoặc "⌘⇧T".
    var displayString: String {
        var s = ""
        let flags = NSEvent.ModifierFlags(rawValue: cocoaModifiers)
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += HotkeyShortcut.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        // Map vài keycode phổ biến; phần còn lại lấy từ layout hiện tại.
        let named: [Int: String] = [
            kVK_Space: "Space",
            kVK_Tab: "⇥",
            kVK_Return: "↩",
            kVK_Escape: "⎋",
            kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←",
            kVK_RightArrow: "→",
            kVK_UpArrow: "↑",
            kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = named[Int(keyCode)] { return s }
        return charFromKeyCode(keyCode) ?? "Key\(keyCode)"
    }

    /// Dùng TIS API để suy ra ký tự của keycode theo layout hiện tại.
    private static func charFromKeyCode(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        let bytes = data.withUnsafeBytes { $0.bindMemory(to: UCKeyboardLayout.self).baseAddress }
        guard let layout = bytes else { return nil }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var realLength = 0
        let err = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState, chars.count, &realLength, &chars
        )
        if err != noErr || realLength == 0 { return nil }
        return String(utf16CodeUnits: chars, count: realLength).uppercased()
    }
}
