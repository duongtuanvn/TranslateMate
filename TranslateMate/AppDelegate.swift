import AppKit
import SwiftUI
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    lazy var settings = SettingsStore()
    lazy var hotkey = HotkeyManager()       // inline replace
    lazy var popupHotkey = HotkeyManager()  // popup mode
    lazy var client = OpenRouterClient()

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    /// Trạng thái hotkey register lần gần nhất (để show trong Diagnostics).
    var hotkeyRegistered: Bool = false
    var lastHotkeyError: String?

    /// Debounce: tránh user giữ phím / spam hotkey gây nhiều API call song song.
    private var isTranslating: Bool = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.info("App launched. macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        setupStatusItem()
        askAccessibilityIfNeeded()

        settings.onHotkeyChanged = { [weak self] shortcut in
            self?.registerHotkey(shortcut)
        }
        registerHotkey(settings.hotkey)

        settings.onPopupHotkeyChanged = { [weak self] shortcut in
            self?.registerPopupHotkey(shortcut)
        }
        registerPopupHotkey(settings.popupHotkey)

        if settings.apiKey.isEmpty {
            AppLogger.shared.warn("No API key set. Opening Settings.")
            openSettings()
        } else {
            AppLogger.shared.info("API key present (\(settings.apiKey.count) chars).")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.unregister()
        popupHotkey.unregister()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "TranslateMate")
        }

        let menu = NSMenu()

        let translateItem = NSMenuItem(title: "Translate selection (replace)", action: #selector(translateNow), keyEquivalent: "")
        translateItem.target = self
        menu.addItem(translateItem)

        let popupItem = NSMenuItem(title: "Translate selection (popup)", action: #selector(popupTranslateNow), keyEquivalent: "")
        popupItem.target = self
        menu.addItem(popupItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit: dùng @objc method riêng → target = self là chính xác.
        // Trước đây dùng NSApplication.terminate(_:) trực tiếp + target = self
        // → AppKit đi tìm method 'terminate:' trên AppDelegate (không có) → disable.
        let quitItem = NSMenuItem(title: "Quit TranslateMate", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Menu actions

    @objc private func translateNow() {
        Task { await performTranslation(trigger: "menu") }
    }

    @objc private func popupTranslateNow() {
        Task { await performPopupTranslation(trigger: "menu") }
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(store: settings, delegate: self)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "TranslateMate Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Hotkey

    private func registerHotkey(_ shortcut: HotkeyShortcut) {
        hotkey.unregister()
        hotkey.onTrigger = { [weak self] in
            AppLogger.shared.info("Replace hotkey triggered: \(shortcut.displayString)")
            Task { await self?.performTranslation(trigger: "hotkey") }
        }
        let ok = hotkey.register(shortcut: shortcut)
        hotkeyRegistered = ok
        if ok {
            lastHotkeyError = nil
            AppLogger.shared.info("Replace hotkey registered: \(shortcut.displayString)")
        } else {
            lastHotkeyError = "RegisterEventHotKey failed — có thể hotkey bị app khác chiếm."
            AppLogger.shared.error("Replace hotkey registration FAILED for \(shortcut.displayString)")
        }
    }

    private func registerPopupHotkey(_ shortcut: HotkeyShortcut) {
        popupHotkey.unregister()
        popupHotkey.onTrigger = { [weak self] in
            AppLogger.shared.info("Popup hotkey triggered: \(shortcut.displayString)")
            Task { await self?.performPopupTranslation(trigger: "hotkey") }
        }
        let ok = popupHotkey.register(shortcut: shortcut)
        if ok {
            AppLogger.shared.info("Popup hotkey registered: \(shortcut.displayString)")
        } else {
            AppLogger.shared.error("Popup hotkey registration FAILED for \(shortcut.displayString) — conflict?")
        }
    }

    // MARK: - Accessibility

    private func askAccessibilityIfNeeded() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as CFString
        let opts = [prompt: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        AppLogger.shared.info("Accessibility trusted = \(trusted)")
    }

    // MARK: - The main flow

    /// Gọi từ hotkey / menu / nút Diagnostics.
    /// Nếu `testText` không nil, bỏ qua AX read và dùng text đó (test API only).
    @MainActor
    func performTranslation(trigger: String, testText: String? = nil) async {
        // Debounce: nếu đang dịch dở, bỏ qua trigger này.
        // Tránh user spam hotkey hoặc giữ phím lâu fire repeated events.
        guard !isTranslating else {
            AppLogger.shared.warn("Ignoring \(trigger) trigger — translation already in progress")
            return
        }
        isTranslating = true
        defer { isTranslating = false }

        AppLogger.shared.info("performTranslation(trigger=\(trigger), testText=\(testText != nil))")

        guard !settings.apiKey.isEmpty else {
            AppLogger.shared.error("Missing OpenRouter API key.")
            alert(title: "Missing API key",
                  message: "Add your OpenRouter API key in Settings → General.",
                  style: .warning)
            openSettings()
            return
        }

        // 1) Đọc text
        let capture: TextBridge.Capture
        let sourceText: String
        if let testText {
            capture = TextBridge.Capture(text: testText, axElement: nil, targetPID: nil, originalPasteboardString: nil)
            sourceText = testText
            AppLogger.shared.info("Using test text (\(testText.count) chars)")
        } else {
            guard let cap = await TextBridge.captureFocusedSelection() else {
                AppLogger.shared.error("No selection captured.")
                alert(title: "No text selected",
                      message: "Select some text in the focused app first, then press the hotkey.\n\nNếu bạn đã bôi đen rồi: có thể app đó không cho Accessibility đọc text — thử app khác (Notes) để xác nhận.",
                      style: .warning)
                return
            }
            capture = cap
            sourceText = cap.text
            AppLogger.shared.info("Captured text (\(cap.text.count) chars) via \(cap.axElement != nil ? "AX" : "clipboard")")
        }

        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alert(title: "No text selected",
                  message: "Selection is empty.",
                  style: .warning)
            return
        }

        // 2) Call API
        statusItem.button?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Translating")
        defer {
            statusItem.button?.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "TranslateMate")
        }

        let result: OpenRouterClient.TranslationResult
        do {
            AppLogger.shared.info("Calling OpenRouter model=\(settings.model)…")
            // Replace mode: target = settings.targetLanguage (vd English).
            // Alternative = popupTargetLanguage (vd Vietnamese) → tạo thành cặp song ngữ user define.
            result = try await client.translate(
                text: sourceText,
                targetLanguage: settings.targetLanguage,
                alternativeLanguage: settings.popupTargetLanguage,
                style: settings.style,
                model: settings.model,
                apiKey: settings.apiKey,
                customInstructions: settings.customInstructions,
                fallbackModels: settings.fallbackModels,
                knownModels: settings.availableModels
            )
            AppLogger.shared.info("Got translation (\(result.text.count) chars) cost=\(result.costUSD ?? 0) USD")
        } catch OpenRouterClient.ClientError.freeModelsExhausted(let attempted, _) {
            AppLogger.shared.error("Free models exhausted: \(attempted.joined(separator: ", "))")
            showFreeModelsExhaustedAlert(attempted: attempted)
            return
        } catch {
            AppLogger.shared.error("Translation API failed: \(error.localizedDescription)")
            alert(title: "Translation failed",
                  message: error.localizedDescription,
                  style: .critical)
            return
        }

        // 3) Write back (nếu không phải test)
        if testText == nil {
            AppLogger.shared.info("Replacing selection… (forceClipboard=\(settings.forceClipboardPaste))")
            await TextBridge.replaceSelection(capture: capture, with: result.text, forceClipboard: settings.forceClipboardPaste)
        } else {
            alert(title: "Test translation succeeded",
                  message: "Source: \(sourceText)\n\nTranslated: \(result.text)",
                  style: .informational)
        }

        // 4) History — kèm model + cost
        settings.appendHistory(
            original: sourceText,
            translated: result.text,
            modelUsed: result.modelUsed,
            promptTokens: result.promptTokens,
            completionTokens: result.completionTokens,
            costUSD: result.costUSD
        )
    }

    // MARK: - Popup translation (lookup mode, không đè text)

    @MainActor
    func performPopupTranslation(trigger: String) async {
        guard !isTranslating else {
            AppLogger.shared.warn("Ignoring popup \(trigger) trigger — translation already in progress")
            return
        }
        isTranslating = true
        defer { isTranslating = false }

        AppLogger.shared.info("performPopupTranslation(trigger=\(trigger))")

        guard !settings.apiKey.isEmpty else {
            alert(title: "Missing API key",
                  message: "Add your OpenRouter API key in Settings → General.",
                  style: .warning)
            openSettings()
            return
        }

        // Lưu vị trí mouse NGAY để hiện popup gần đó
        let mouseLoc = NSEvent.mouseLocation

        // Đọc text đang chọn (async, không block UI)
        guard let capture = await TextBridge.captureFocusedSelection(),
              !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alert(title: "No text selected",
                  message: "Bôi đen đoạn văn bản muốn dịch trước, rồi bấm hotkey popup.",
                  style: .warning)
            return
        }

        // Status indicator + show "loading" popup luôn để user thấy phản hồi tức thì
        statusItem.button?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Translating")
        TranslationPopup.shared.show(
            original: capture.text,
            translated: "Đang dịch…",
            near: mouseLoc
        )
        defer {
            statusItem.button?.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "TranslateMate")
        }

        do {
            AppLogger.shared.info("Popup: calling OpenRouter target=\(settings.popupTargetLanguage)")
            // Popup mode: target = popupTargetLanguage (vd Vietnamese).
            // Alternative = targetLanguage (vd English) → swap pair y hệt user define.
            let result = try await client.translate(
                text: capture.text,
                targetLanguage: settings.popupTargetLanguage,
                alternativeLanguage: settings.targetLanguage,
                style: settings.style,
                model: settings.model,
                apiKey: settings.apiKey,
                customInstructions: settings.customInstructions,
                fallbackModels: settings.fallbackModels,
                knownModels: settings.availableModels
            )
            AppLogger.shared.info("Popup: got translation (\(result.text.count) chars) cost=\(result.costUSD ?? 0)")

            TranslationPopup.shared.show(
                original: capture.text,
                translated: result.text,
                near: mouseLoc
            )

            settings.appendHistory(
                original: capture.text,
                translated: result.text,
                modelUsed: result.modelUsed,
                promptTokens: result.promptTokens,
                completionTokens: result.completionTokens,
                costUSD: result.costUSD
            )
        } catch OpenRouterClient.ClientError.freeModelsExhausted(let attempted, _) {
            TranslationPopup.shared.close()
            showFreeModelsExhaustedAlert(attempted: attempted)
        } catch {
            AppLogger.shared.error("Popup translation failed: \(error.localizedDescription)")
            TranslationPopup.shared.close()
            alert(title: "Translation failed",
                  message: error.localizedDescription,
                  style: .critical)
        }
    }

    // MARK: - Alerts

    /// Hiện alert KHÔNG block main thread — async, fire-and-forget.
    /// Trước đây dùng `runModal()` block toàn bộ event loop của app trong khi
    /// alert hiện → hotkey kế tiếp không fire được + UI freeze. Giờ dùng
    /// `beginSheetModal` qua hidden window → non-blocking.
    func alert(title: String, message: String, style: NSAlert.Style = .informational) {
        Task { @MainActor in
            let a = NSAlert()
            a.messageText = title
            a.informativeText = message
            a.alertStyle = style
            a.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            // Chạy trên next tick để không block caller
            a.runModal()
        }
    }

    /// Alert riêng khi tất cả free models bị rate-limit. Có nút mở Settings.
    func showFreeModelsExhaustedAlert(attempted: [String]) {
        let a = NSAlert()
        a.messageText = "Tất cả free models đang quá tải"
        a.informativeText = """
        Đã thử \(attempted.count) free model nhưng đều bị rate-limit hoặc tạm thời không khả dụng:

        \(attempted.map { "  • \($0)" }.joined(separator: "\n"))

        Free tier OpenRouter chia sẻ quota giữa hàng nghìn user → giờ cao điểm hay full.

        💡 Gợi ý:
        • Đợi vài phút rồi thử lại (quota reset thường xuyên)
        • Hoặc đổi sang một paid model rẻ — chỉ ~26-300đ cho mỗi câu dịch, quota riêng và ổn định
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Try later")
        NSApp.activate(ignoringOtherApps: true)
        let response = a.runModal()
        if response == .alertFirstButtonReturn {
            openSettings()
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            settingsWindow = nil
        }
    }
}

// MARK: - Protocol for SettingsView to ping AppDelegate

@MainActor
protocol AppDelegateActions: AnyObject {
    var hotkeyRegistered: Bool { get }
    var lastHotkeyError: String? { get }
    func performTranslation(trigger: String, testText: String?) async
    func reRegisterHotkey()
}

extension AppDelegate: AppDelegateActions {
    func reRegisterHotkey() {
        registerHotkey(settings.hotkey)
    }
}
