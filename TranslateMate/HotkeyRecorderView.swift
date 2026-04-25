import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Ô bấm để "ghi" một tổ hợp phím tắt. Khi đang record, nhấn bất kỳ tổ hợp nào có modifier
/// sẽ được lưu vào shortcut.
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var shortcut: HotkeyShortcut

    func makeNSView(context: Context) -> RecorderButton {
        let btn = RecorderButton()
        btn.onCapture = { s in shortcut = s }
        btn.currentShortcut = shortcut
        return btn
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.currentShortcut = shortcut
        nsView.needsDisplay = true
    }
}

/// NSButton custom: khi click vào sẽ vào "recording mode", nhận phím tiếp theo.
final class RecorderButton: NSButton {
    var onCapture: ((HotkeyShortcut) -> Void)?
    var currentShortcut: HotkeyShortcut = .default { didSet { updateTitle() } }

    private var isRecording = false
    private var localMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    private func updateTitle() {
        title = isRecording ? "Press a shortcut…" : currentShortcut.displayString
        if isRecording { contentTintColor = .systemOrange } else { contentTintColor = nil }
    }

    @objc private func toggleRecording() {
        isRecording.toggle()
        updateTitle()
        if isRecording { startMonitor() } else { stopMonitor() }
    }

    private func startMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
                let modsOnly = flags.intersection(relevant)
                if modsOnly.isEmpty {
                    // bấm Esc để huỷ
                    if event.keyCode == kVK_Escape {
                        self.isRecording = false
                        self.updateTitle()
                        self.stopMonitor()
                        return nil
                    }
                    // không có modifier thì bỏ qua
                    return event
                }
                let newShortcut = HotkeyShortcut(keyCode: UInt32(event.keyCode), cocoaModifiers: modsOnly.rawValue)
                self.currentShortcut = newShortcut
                self.onCapture?(newShortcut)
                self.isRecording = false
                self.updateTitle()
                self.stopMonitor()
                return nil
            }
            return event
        }
    }

    private func stopMonitor() {
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }
}
