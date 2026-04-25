import SwiftUI
import AppKit
import ApplicationServices

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var rateLimitTracker = RateLimitTracker.shared
    weak var delegate: (any AppDelegateActions)?

    @State private var selectedTab: Tab = .general
    @State private var logEntries: [AppLogger.Entry] = []
    @State private var axTrusted: Bool = AXIsProcessTrusted()
    @State private var testInput: String = "Xin chào bạn, hôm nay bạn khỏe không?"
    @State private var testing: Bool = false
    @State private var refreshTick: Int = 0
    @State private var validating: Bool = false
    @State private var validateResult: (ok: Bool, message: String)?
    /// Toggle giữa "cheap+popular" (default) và "all paid models"
    @State private var showAllPaidModels: Bool = false
    private let axTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    enum Tab: String, CaseIterable {
        case general = "General"
        case translation = "Translation"
        case history = "History"
        case diagnostics = "Diagnostics"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            translationTab
                .tabItem { Label("Translation", systemImage: "character.bubble") }
                .tag(Tab.translation)
            historyTab
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            diagnosticsTab
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(Tab.diagnostics)
        }
        .frame(minWidth: 560, minHeight: 580)
        .padding()
        .onAppear {
            AppLogger.shared.onChange { entries in
                self.logEntries = entries
            }
        }
        .onReceive(axTimer) { _ in
            axTrusted = AXIsProcessTrusted()
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Replace hotkey (dịch & đè text gốc)") {
                HStack {
                    Text("Trigger:")
                    HotkeyRecorderView(shortcut: Binding(
                        get: { store.hotkey },
                        set: { store.hotkey = $0 }
                    ))
                    .frame(width: 200, height: 24)
                    Spacer()
                    Button("Reset") { store.hotkey = .default }
                }
                Picker("Translate to:", selection: $store.targetLanguage) {
                    ForEach(SettingsStore.suggestedLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                Text("Bôi đen text bạn vừa gõ (Vietnamese) → bấm hotkey → text bị đè bằng \(store.targetLanguage). Dùng khi compose tin nhắn.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Popup hotkey (lookup, hiện popup không đè text)") {
                HStack {
                    Text("Trigger:")
                    HotkeyRecorderView(shortcut: Binding(
                        get: { store.popupHotkey },
                        set: { store.popupHotkey = $0 }
                    ))
                    .frame(width: 200, height: 24)
                    Spacer()
                    Button("Reset") { store.popupHotkey = .popupDefault }
                }
                Picker("Translate to:", selection: $store.popupTargetLanguage) {
                    ForEach(SettingsStore.suggestedLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                Text("Bôi đen text họ gửi (English) → bấm hotkey → popup hiện bản dịch \(store.popupTargetLanguage). Esc để đóng. Text gốc KHÔNG bị thay đổi. Dùng khi đọc tin nhắn.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("OpenRouter API key") {
                SecureField("sk-or-v1-…", text: $store.apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Length: \(store.apiKey.count) chars")
                        .font(.caption)
                        .foregroundColor(store.apiKey.count == 0 ? .secondary :
                                         store.apiKey.count == 73 ? .green : .orange)
                    Spacer()
                    Button {
                        Task { await validateKey() }
                    } label: {
                        if validating { ProgressView().controlSize(.small) }
                        else { Text("Validate key") }
                    }
                    .disabled(store.apiKey.isEmpty || validating)

                    if !store.apiKey.isEmpty {
                        Button("Clear") { store.apiKey = "" }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
                if let validateResult {
                    Text(validateResult.message)
                        .font(.caption)
                        .foregroundColor(validateResult.ok ? .green : .red)
                        .textSelection(.enabled)
                }
                HStack {
                    Link("Get / check your key at openrouter.ai/keys",
                         destination: URL(string: "https://openrouter.ai/keys")!)
                        .font(.caption)
                    Spacer()
                    Text("Standard key = 73 chars. Stored in Keychain.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Section("Compatibility") {
                Toggle("Always use clipboard paste (recommended for Telegram, Discord, Slack)",
                       isOn: $store.forceClipboardPaste)
                Text("Many apps (Telegram, Discord, Slack, VS Code…) say they accepted the text but silently ignore it. When this is on, TranslateMate always uses clipboard + Cmd+V, which is more reliable. Turn off for maximum compatibility with native macOS apps that support formatting preservation.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                HStack {
                    Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(axTrusted ? .green : .orange)
                    Text(axTrusted
                         ? "Accessibility permission granted."
                         : "Accessibility permission required.")
                    Spacer()
                    if !axTrusted {
                        Button("Open System Settings") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Translation

    private var translationTab: some View {
        Form {
            Section("Target languages") {
                Picker("Replace mode → output:", selection: $store.targetLanguage) {
                    ForEach(SettingsStore.suggestedLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .pickerStyle(.menu)

                Picker("Popup mode → output:", selection: $store.popupTargetLanguage) {
                    ForEach(SettingsStore.suggestedLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .pickerStyle(.menu)

                Text("App tự auto-detect ngôn ngữ nguồn. Nếu nguồn trùng target, app tự đảo sang ngôn ngữ đối lập (vd target = Vietnamese mà nguồn là Vietnamese → output English).")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Model") {
                HStack {
                    Text("Model ID:")
                    TextField("paste any model id", text: $store.model)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                if store.model.hasSuffix(":free") {
                    Label("FREE model — no cost.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                } else if !store.availableModels.isEmpty,
                          let m = store.availableModels.first(where: { $0.id == store.model }) {
                    Label("Paid model — uses your OpenRouter credit.", systemImage: "dollarsign.circle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    if let prompt = m.pricing?.prompt {
                        Text("Pricing: $\(prompt)/1M tokens prompt").font(.caption).foregroundColor(.secondary)
                    }
                }

                // ─── Dynamic model browser ───
                HStack {
                    Text("Available: \(store.freeModels.count) free + \(store.cheapPaidModels.count) cheap-paid (\(store.paidModels.count) total)")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    if let date = store.modelsLastFetchedAt {
                        Text("updated \(date.formatted(.relative(presentation: .numeric)))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Button {
                        Task { await store.refreshModels() }
                    } label: {
                        if store.isFetchingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isFetchingModels)
                }

                if store.availableModels.isEmpty {
                    Button("Fetch model list from OpenRouter") {
                        Task { await store.refreshModels() }
                    }
                } else {
                    DisclosureGroup("Free models (\(store.freeModels.count))") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(store.freeModels) { m in
                                Button {
                                    store.model = m.id
                                } label: {
                                    HStack {
                                        Image(systemName: store.model == m.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(store.model == m.id ? .accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(m.displayName).font(.system(size: 12))
                                            Text(m.id).font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        // Badge cooldown
                                        if let remaining = rateLimitTracker.remainingText(m.id) {
                                            Text("⏳ \(remaining)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.orange)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .opacity(rateLimitTracker.isRateLimited(m.id) ? 0.55 : 1.0)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    DisclosureGroup(showAllPaidModels
                                    ? "All paid models (\(store.paidModels.count))"
                                    : "Cheap + popular paid models (\(store.cheapPaidModels.count))") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(showAllPaidModels ? store.paidModels : store.cheapPaidModels) { m in
                                Button {
                                    store.model = m.id
                                } label: {
                                    HStack {
                                        Image(systemName: store.model == m.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(store.model == m.id ? .accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(m.displayName).font(.system(size: 12))
                                            Text(m.id).font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if let p = m.pricing?.prompt, let pVal = Double(p), pVal > 0 {
                                            Text("$\(String(format: "%.3f", pVal * 1_000_000))/1M")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }

                            HStack {
                                Toggle(isOn: $showAllPaidModels) {
                                    Text(showAllPaidModels
                                         ? "Showing all (incl. expensive). Click to filter."
                                         : "Show all paid models (\(store.paidModels.count))")
                                        .font(.caption)
                                }
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                Spacer()
                            }
                            .padding(.top, 4)

                            Text("Hidden: model trên $2/1M tokens hoặc của provider niche. Bạn vẫn có thể paste model ID bất kỳ vào ô \"Model ID\" ở trên.")
                                .font(.caption2).foregroundColor(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Link("openrouter.ai/models", destination: URL(string: "https://openrouter.ai/models")!)
                        .font(.caption)
                    Spacer()
                }
            }
            .onAppear {
                // Auto-fetch nếu chưa có hoặc cache > 1 ngày
                let stale = store.modelsLastFetchedAt.map { Date().timeIntervalSince($0) > 86400 } ?? true
                if store.availableModels.isEmpty || stale {
                    Task { await store.refreshModels() }
                }
            }

            Section("Fallback chain (auto-retry khi rate limited)") {
                Text("Khi model chính bị 429 hoặc 5xx, app sẽ tự động thử các model dưới đây theo thứ tự. Rất hữu ích vì free models hay bị rate-limit ngẫu nhiên.")
                    .font(.caption).foregroundColor(.secondary)

                ForEach(Array(store.fallbackModels.enumerated()), id: \.offset) { idx, m in
                    HStack {
                        Text("\(idx + 1).")
                            .foregroundColor(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(m)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            store.fallbackModels.remove(at: idx)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if !store.availableModels.isEmpty {
                    Menu("Add a free model to fallback chain") {
                        ForEach(store.freeModels) { m in
                            if !store.fallbackModels.contains(m.id) {
                                Button(m.displayName) {
                                    store.fallbackModels.append(m.id)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Button("Reset to defaults") {
                        store.fallbackModels = SettingsStore.defaultFallbackModels
                    }
                    Spacer()
                    Button("Clear all", role: .destructive) {
                        store.fallbackModels = []
                    }
                    .disabled(store.fallbackModels.isEmpty)
                }
                .font(.caption)
            }

            Section("Style") {
                Picker("Tone", selection: $store.style) {
                    ForEach(TranslationStyle.allCases) { s in
                        Text(s.display).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Custom instructions (optional)") {
                TextEditor(text: $store.customInstructions)
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3)))
                Text("Appended to the system prompt. e.g. \"Keep emoji and URLs as-is. Match the casual tone of Telegram chat.\"")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - History

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last \(store.history.count) translations").font(.headline)
                Spacer()
                Button("Clear all", role: .destructive) { store.clearHistory() }
                    .disabled(store.history.isEmpty)
            }

            // Tổng chi phí tích luỹ
            if !store.history.isEmpty {
                let total = store.totalCost
                HStack(spacing: 14) {
                    Label {
                        if total.usd > 0 {
                            Text(String(format: "Tổng: $%.5f ≈ %@", total.usd, formatVND(total.vnd)))
                                .font(.system(size: 12, design: .monospaced))
                        } else {
                            Text("Tổng: Miễn phí (free models)").font(.system(size: 12))
                                .foregroundColor(.green)
                        }
                    } icon: {
                        Image(systemName: "dollarsign.circle.fill")
                            .foregroundColor(total.usd > 0 ? .orange : .green)
                    }
                    Spacer()
                    Text("Tỷ giá: 1 USD = \(formatVND(HistoryEntry.usdToVnd))")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }

            if store.history.isEmpty {
                VStack {
                    Spacer()
                    Text("No translations yet. Select text in any app and press your hotkey.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.history) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        // Header: ngày + model + cost
                        HStack(spacing: 8) {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundColor(.secondary)
                            if let m = entry.modelUsed {
                                Text(m)
                                    .font(.caption.monospaced())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(3)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if let costText = entry.costVNDText {
                                let isFree = (entry.costUSD ?? 0) <= 0
                                Text(costText)
                                    .font(.caption.monospaced())
                                    .foregroundColor(isFree ? .green : .orange)
                            }
                            if let p = entry.promptTokens, let c = entry.completionTokens, p + c > 0 {
                                Text("\(p)+\(c) tok")
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text(entry.original).font(.body).lineLimit(3)
                        Text(entry.translated).font(.body).foregroundColor(.accentColor).lineLimit(3)
                    }
                    .contextMenu {
                        Button("Copy original") { copy(entry.original) }
                        Button("Copy translation") { copy(entry.translated) }
                        if let m = entry.modelUsed {
                            Button("Copy model id") { copy(m) }
                        }
                    }
                }
            }
        }
        .padding()
    }

    /// Format VND có dấu chấm phân cách hàng ngàn.
    private func formatVND(_ vnd: Double) -> String {
        if vnd <= 0 { return "0 đ" }
        if vnd < 1 { return String(format: "%.4f đ", vnd) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        f.maximumFractionDigits = vnd < 1000 ? 2 : 0
        return (f.string(from: NSNumber(value: vnd)) ?? "\(Int(vnd))") + " đ"
    }

    // MARK: - Diagnostics

    private var diagnosticsTab: some View {
        VStack(alignment: .leading, spacing: 14) {

            // ── Status cards ──
            VStack(alignment: .leading, spacing: 6) {
                row("Accessibility trust:", axTrusted ? "✅ granted" : "❌ NOT granted",
                    help: axTrusted ? nil : "System Settings → Privacy & Security → Accessibility → bật cho TranslateMate.")
                row("Hotkey registered:",
                    (delegate?.hotkeyRegistered ?? false) ? "✅ \(store.hotkey.displayString)" : "❌ FAILED",
                    help: delegate?.lastHotkeyError)
                row("API key:", store.apiKey.isEmpty ? "❌ missing" : "✅ set (\(store.apiKey.count) chars)")
                row("Model:", store.model)
                row("Target language:", store.targetLanguage)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)

            // ── Test actions ──
            VStack(alignment: .leading, spacing: 8) {
                Text("Test pipeline").font(.headline)

                HStack {
                    Button {
                        Task { await runTestTranslate() }
                    } label: {
                        Label("Test API (dịch đoạn text mẫu)", systemImage: "network")
                    }
                    .disabled(testing || store.apiKey.isEmpty)

                    Button {
                        delegate?.reRegisterHotkey()
                    } label: {
                        Label("Re-register hotkey", systemImage: "arrow.clockwise")
                    }
                }

                TextField("Test text", text: $testInput)
                    .textFieldStyle(.roundedBorder)

                Text("\"Test API\" chỉ test OpenRouter (không cần selection). Để test full pipeline, dùng hotkey thực ở app khác (Notes, Telegram, …).")
                    .font(.caption).foregroundColor(.secondary)
            }

            // ── Rate-limited models ──
            if !rateLimitTracker.cooldowns.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Rate-limited models (\(rateLimitTracker.cooldowns.count))")
                            .font(.headline)
                        Spacer()
                        Button("Clear all") { rateLimitTracker.clearAll() }
                            .controlSize(.small)
                    }

                    ForEach(Array(rateLimitTracker.cooldowns.keys.sorted()), id: \.self) { modelID in
                        HStack(spacing: 8) {
                            Image(systemName: "hourglass")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(modelID)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                if let r = rateLimitTracker.reason(for: modelID) {
                                    Text(r).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if let txt = rateLimitTracker.remainingText(modelID) {
                                Text(txt)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.orange)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    Text("Models này tạm thời bị skip khỏi fallback chain. Tự động thử lại khi cooldown hết.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
            }

            // ── Log viewer ──
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Log (\(logEntries.count))").font(.headline)
                    Spacer()
                    Button("Clear") { AppLogger.shared.clear() }
                    Button("Copy all") {
                        let text = logEntries.map {
                            "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.level.rawValue.uppercased())] \($0.message)"
                        }.joined(separator: "\n")
                        copy(text)
                    }
                }
                ScrollView {
                    ScrollViewReader { proxy in
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(logEntries) { e in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(e.date.formatted(date: .omitted, time: .standard))
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                    Text(e.level.rawValue.uppercased())
                                        .font(.caption2.monospaced().bold())
                                        .foregroundColor(color(for: e.level))
                                        .frame(width: 40, alignment: .leading)
                                    Text(e.message)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                                .id(e.id)
                            }
                        }
                        .padding(6)
                        .onChange(of: logEntries.count) { _ in
                            if let last = logEntries.last?.id {
                                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                            }
                        }
                    }
                }
                .frame(minHeight: 180)
                .background(Color.black.opacity(0.05))
                .cornerRadius(6)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ label: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).fontWeight(.medium)
                Spacer()
                Text(value).textSelection(.enabled).font(.body.monospaced())
            }
            if let help {
                Text(help).font(.caption).foregroundColor(.orange)
            }
        }
    }

    private func color(for level: AppLogger.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        }
    }

    @MainActor
    private func runTestTranslate() async {
        testing = true
        defer { testing = false }
        await delegate?.performTranslation(trigger: "diagnostics-test", testText: testInput)
    }

    @MainActor
    private func validateKey() async {
        validating = true
        defer { validating = false }
        let client = OpenRouterClient()
        do {
            let body = try await client.validateKey(apiKey: store.apiKey)
            validateResult = (true, "✅ Valid. \(body.prefix(200))")
        } catch {
            validateResult = (false, "❌ \(error.localizedDescription)")
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
