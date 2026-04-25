import AppKit
import SwiftUI

/// Floating HUD popup chỉ để ĐỌC bản dịch.
/// - Esc để đóng (cả khi popup ở trên app khác hoặc trên TranslateMate)
/// - Click X để đóng
/// - ScrollView cho text dài, không bao giờ phình to chiếm màn hình
@MainActor
final class TranslationPopup {
    static let shared = TranslationPopup()

    private var window: NSWindow?
    private var globalEscMonitor: Any?
    private var localEscMonitor: Any?

    /// Width cố định, height clamp [120, 480].
    private let popupWidth: CGFloat = 460
    private let popupMinHeight: CGFloat = 120
    private let popupMaxHeight: CGFloat = 480

    func show(original: String, translated: String, near point: NSPoint? = nil) {
        close()

        let mouseLoc = point ?? NSEvent.mouseLocation
        AppLogger.shared.info("Popup show: near \(mouseLoc), translated len=\(translated.count)")

        let view = TranslationPopupView(
            original: original,
            translated: translated,
            maxHeight: popupMaxHeight,
            onClose: { [weak self] in self?.close() }
        )

        let hosting = NSHostingController(rootView: view)
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = [.preferredContentSize]
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: popupWidth, height: popupMinHeight),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.contentViewController = hosting
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isMovableByWindowBackground = true

        // Force layout, đo height thật của SwiftUI view.
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let actualHeight = max(popupMinHeight, min(popupMaxHeight, fitting.height))
        let actualSize = NSSize(width: popupWidth, height: actualHeight)
        w.setContentSize(actualSize)

        let origin = positionFor(size: actualSize, near: mouseLoc)
        w.setFrameOrigin(origin)
        w.orderFrontRegardless()

        // Esc đóng - cần CẢ 2 monitor:
        // - Global: khi popup show trên app khác (Telegram, Notes, ...)
        // - Local: khi user đang focus TranslateMate (ít khi xảy ra nhưng cho chắc)
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                DispatchQueue.main.async { self?.close() }
            }
        }
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                DispatchQueue.main.async { self?.close() }
                return nil
            }
            return event
        }

        window = w
        AppLogger.shared.info("Popup window orderedFront origin=\(origin) size=\(actualSize) (fittingHeight=\(fitting.height))")
    }

    func close() {
        if let w = window {
            w.orderOut(nil)
            AppLogger.shared.info("Popup window closed")
        }
        window = nil
        if let m = globalEscMonitor { NSEvent.removeMonitor(m); globalEscMonitor = nil }
        if let m = localEscMonitor  { NSEvent.removeMonitor(m); localEscMonitor = nil }
    }

    private func positionFor(size: NSSize, near mouseLoc: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let frame = screen.visibleFrame

        var x = mouseLoc.x + 16
        var y = mouseLoc.y - size.height - 16

        if x + size.width > frame.maxX { x = frame.maxX - size.width - 16 }
        if x < frame.minX + 8 { x = frame.minX + 8 }
        if y < frame.minY + 8 { y = mouseLoc.y + 16 }
        if y + size.height > frame.maxY { y = frame.maxY - size.height - 16 }
        // Đảm bảo lúc nào cũng trong screen
        y = max(frame.minY + 8, min(frame.maxY - size.height - 8, y))

        return NSPoint(x: x, y: y)
    }
}

// MARK: - SwiftUI

private struct TranslationPopupView: View {
    let original: String
    let translated: String
    let maxHeight: CGFloat
    let onClose: () -> Void

    /// Body content max height = maxHeight - header - dividers - paddings
    private var scrollMaxHeight: CGFloat { maxHeight - 60 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ─── Header (fixed) ───
            HStack(spacing: 6) {
                Image(systemName: "character.bubble.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 13))
                Text("TranslateMate")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("Esc to close")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            // ─── Body (scrollable) ───
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(original)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Text(translated)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: scrollMaxHeight)
        }
        .frame(width: 460)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}
