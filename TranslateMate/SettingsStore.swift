import Foundation
import SwiftUI
import AppKit
import ServiceManagement

enum TranslationStyle: String, CaseIterable, Codable, Identifiable {
    case natural, literal, casual, formal
    var id: String { rawValue }
    var display: String {
        switch self {
        case .natural: return "Natural"
        case .literal: return "Literal"
        case .casual:  return "Casual / chat"
        case .formal:  return "Formal"
        }
    }
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    let date: Date
    let original: String
    let translated: String
    var modelUsed: String? = nil       // model id thực tế đã dùng
    var promptTokens: Int? = nil
    var completionTokens: Int? = nil
    var costUSD: Double? = nil          // cost USD (nil nếu free model hoặc không lookup được pricing)

    /// Tỷ giá USD → VND để hiển thị. 1 USD = 26,000 VND (tham khảo).
    static let usdToVnd: Double = 26_000

    /// Cost dạng VND, format đẹp.
    var costVNDText: String? {
        guard let cost = costUSD else { return nil }
        if cost <= 0 { return "Miễn phí" }
        let vnd = cost * Self.usdToVnd
        if vnd < 1 {
            return String(format: "%.4f đ", vnd)
        } else if vnd < 1000 {
            return String(format: "%.2f đ", vnd)
        } else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = "."
            formatter.maximumFractionDigits = 0
            let n = NSNumber(value: vnd)
            return (formatter.string(from: n) ?? "\(Int(vnd))") + " đ"
        }
    }
}

/// Nơi tập trung mọi setting. Lưu vào UserDefaults + API key lưu Keychain.
@MainActor
final class SettingsStore: ObservableObject {

    // MARK: - Keys
    private let kvHotkey       = "hotkey"
    private let kvTargetLang   = "targetLanguage"
    private let kvModel        = "model"
    private let kvStyle        = "style"
    private let kvCustom       = "customInstructions"
    private let kvHistory      = "history"
    private let kvLaunchAtLogin = "launchAtLogin"
    private let kvForceClipboard = "forceClipboardPaste"
    private let kvPopupHotkey  = "popupHotkey"
    private let kvPopupLang    = "popupTargetLanguage"
    private let kvCachedModels = "cachedModels"
    private let kvCachedModelsAt = "cachedModelsAt"
    private let kvFallbackModels = "fallbackModels"

    /// Keychain service = bundle ID hiện tại (auto-detect, không hardcode).
    /// Fallback nếu lấy không được (chỉ xảy ra trong unit test).
    private let keychainService = Bundle.main.bundleIdentifier ?? "TranslateMate.local"
    private let keychainAccount = "openrouter_api_key"

    // MARK: - Published
    @Published var hotkey: HotkeyShortcut { didSet { saveHotkey(); onHotkeyChanged?(hotkey) } }
    @Published var targetLanguage: String { didSet { UserDefaults.standard.set(targetLanguage, forKey: kvTargetLang) } }
    @Published var model: String          { didSet { UserDefaults.standard.set(model, forKey: kvModel) } }
    @Published var style: TranslationStyle{ didSet { UserDefaults.standard.set(style.rawValue, forKey: kvStyle) } }
    @Published var customInstructions: String { didSet { UserDefaults.standard.set(customInstructions, forKey: kvCustom) } }
    @Published var apiKey: String {
        didSet {
            // Tự cắt whitespace/newline - lỗi 401 "User not found" rất hay do paste dính \n hoặc space.
            let cleaned = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned != apiKey {
                apiKey = cleaned   // trigger didSet lần nữa với giá trị sạch
                return
            }
            Keychain.set(apiKey, service: keychainService, account: keychainAccount)
        }
    }
    @Published var history: [HistoryEntry] { didSet { saveHistory() } }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: kvLaunchAtLogin)
            applyLaunchAtLogin()
        }
    }
    /// Bỏ qua AX set, luôn dùng clipboard + Cmd+V. Cần cho Telegram/Discord/Electron apps
    /// (AX set trả .success nhưng không apply thật).
    @Published var forceClipboardPaste: Bool {
        didSet { UserDefaults.standard.set(forceClipboardPaste, forKey: kvForceClipboard) }
    }
    /// Popup mode hotkey (lookup → hiện popup, không đè text).
    @Published var popupHotkey: HotkeyShortcut {
        didSet { savePopupHotkey(); onPopupHotkeyChanged?(popupHotkey) }
    }
    /// Ngôn ngữ đích cho popup mode (default Vietnamese).
    @Published var popupTargetLanguage: String {
        didSet { UserDefaults.standard.set(popupTargetLanguage, forKey: kvPopupLang) }
    }
    /// Models lấy động từ OpenRouter API.
    @Published var availableModels: [OpenRouterClient.ModelInfo] = []
    @Published var modelsLastFetchedAt: Date?
    @Published var isFetchingModels: Bool = false
    /// Fallback chain: nếu model chính 429, app tự thử các model trong list này.
    @Published var fallbackModels: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(fallbackModels) {
                UserDefaults.standard.set(data, forKey: kvFallbackModels)
            }
        }
    }

    var onPopupHotkeyChanged: ((HotkeyShortcut) -> Void)?

    /// Callback cho AppDelegate re-register hotkey khi user đổi.
    var onHotkeyChanged: ((HotkeyShortcut) -> Void)?

    // MARK: - Init
    init() {
        let ud = UserDefaults.standard

        // Hotkey
        if let data = ud.data(forKey: kvHotkey),
           let s = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) {
            self.hotkey = s
        } else {
            self.hotkey = .default
        }

        // Sanitize: nếu giá trị cũ user gõ tay không khớp list (vd "tiếng việt", "english(US)"),
        // map về tên chuẩn hoặc fallback "English".
        let savedTarget = ud.string(forKey: kvTargetLang) ?? "English"
        self.targetLanguage = SettingsStore.normalizeLanguage(savedTarget) ?? "English"
        // Default = paste model id; user sẽ click "Refresh" trong Settings → Translation
        // để fetch list current free models. Để trống là an toàn nhất.
        self.model             = ud.string(forKey: kvModel) ?? "deepseek/deepseek-chat-v3-0324:free"
        self.style             = TranslationStyle(rawValue: ud.string(forKey: kvStyle) ?? "natural") ?? .natural
        self.customInstructions = ud.string(forKey: kvCustom) ?? ""
        self.launchAtLogin     = ud.bool(forKey: kvLaunchAtLogin)
        // Mặc định BẬT để tương thích tối đa với Telegram/Discord/Slack...
        if ud.object(forKey: kvForceClipboard) == nil {
            self.forceClipboardPaste = true
        } else {
            self.forceClipboardPaste = ud.bool(forKey: kvForceClipboard)
        }

        // Popup hotkey
        if let data = ud.data(forKey: kvPopupHotkey),
           let s = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) {
            self.popupHotkey = s
        } else {
            self.popupHotkey = .popupDefault
        }
        let savedPopup = ud.string(forKey: kvPopupLang) ?? "Vietnamese"
        self.popupTargetLanguage = SettingsStore.normalizeLanguage(savedPopup) ?? "Vietnamese"

        // History
        if let data = ud.data(forKey: kvHistory),
           let items = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            self.history = items
        } else {
            self.history = []
        }

        // API key từ Keychain
        let raw = Keychain.get(service: keychainService, account: keychainAccount) ?? ""
        self.apiKey = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Load cached models nếu có
        if let data = ud.data(forKey: kvCachedModels),
           let cached = try? JSONDecoder().decode([OpenRouterClient.ModelInfo].self, from: data) {
            self.availableModels = cached
        }
        if let date = ud.object(forKey: kvCachedModelsAt) as? Date {
            self.modelsLastFetchedAt = date
        }

        // Fallback models - default = 3 model free thường ổn định nhất
        if let data = ud.data(forKey: kvFallbackModels),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            self.fallbackModels = list
        } else {
            self.fallbackModels = SettingsStore.defaultFallbackModels
        }
    }

    /// Default fallback chain — chọn các model có nhiều provider/quota rộng,
    /// ít khi cùng lúc bị rate-limit hết.
    static let defaultFallbackModels = [
        "deepseek/deepseek-chat-v3-0324:free",
        "meta-llama/llama-3.3-70b-instruct:free",
        "qwen/qwen-2.5-72b-instruct:free",
        "mistralai/mistral-small-3.2-24b-instruct:free",
    ]

    // MARK: - Models fetch

    /// Fetch models từ OpenRouter và cache vào UserDefaults.
    func refreshModels() async {
        await MainActor.run { self.isFetchingModels = true }
        defer { Task { @MainActor in self.isFetchingModels = false } }

        do {
            let client = OpenRouterClient()
            let models = try await client.fetchModels()
            await MainActor.run {
                self.availableModels = models
                self.modelsLastFetchedAt = Date()
                if let data = try? JSONEncoder().encode(models) {
                    UserDefaults.standard.set(data, forKey: kvCachedModels)
                }
                UserDefaults.standard.set(Date(), forKey: kvCachedModelsAt)
            }
        } catch {
            AppLogger.shared.error("refreshModels failed: \(error.localizedDescription)")
        }
    }

    /// Lấy free models từ availableModels, sort by name.
    var freeModels: [OpenRouterClient.ModelInfo] {
        availableModels.filter(\.isFree).sorted { ($0.displayName) < ($1.displayName) }
    }

    /// Tất cả paid models, sort by price ascending.
    var paidModels: [OpenRouterClient.ModelInfo] {
        availableModels.filter { !$0.isFree }.sorted { lhs, rhs in
            let l = Double(lhs.pricing?.prompt ?? "999") ?? 999
            let r = Double(rhs.pricing?.prompt ?? "999") ?? 999
            return l < r
        }
    }

    /// Paid models rẻ và phổ biến: ≤ $2/1M tokens prompt, từ provider lớn,
    /// dùng cho dịch text thường. Đủ cho 95% user. Còn lại type model ID custom.
    var cheapPaidModels: [OpenRouterClient.ModelInfo] {
        let popularProviders: Set<String> = [
            "openai", "anthropic", "google", "deepseek",
            "meta-llama", "mistralai", "qwen", "x-ai",
        ]
        let maxPricePerMillion: Double = 2.0  // $2/1M tokens

        return availableModels
            .filter { !$0.isFree }
            .compactMap { m -> (OpenRouterClient.ModelInfo, Double)? in
                guard let priceStr = m.pricing?.prompt,
                      let price = Double(priceStr),
                      price > 0 else { return nil }
                let pricePerMillion = price * 1_000_000
                guard pricePerMillion <= maxPricePerMillion else { return nil }
                let provider = m.id.split(separator: "/").first.map(String.init) ?? ""
                guard popularProviders.contains(provider) else { return nil }
                return (m, pricePerMillion)
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }

    // MARK: - Persistence

    private func saveHotkey() {
        if let data = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(data, forKey: kvHotkey)
        }
    }

    private func savePopupHotkey() {
        if let data = try? JSONEncoder().encode(popupHotkey) {
            UserDefaults.standard.set(data, forKey: kvPopupHotkey)
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: kvHistory)
        }
    }

    // MARK: - History

    func appendHistory(
        original: String,
        translated: String,
        modelUsed: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        costUSD: Double? = nil
    ) {
        let entry = HistoryEntry(
            date: Date(),
            original: original,
            translated: translated,
            modelUsed: modelUsed,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            costUSD: costUSD
        )
        history.insert(entry, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
    }

    /// Tổng cost USD và VND tích luỹ trong history.
    var totalCost: (usd: Double, vnd: Double) {
        let usd = history.compactMap(\.costUSD).reduce(0, +)
        return (usd, usd * HistoryEntry.usdToVnd)
    }

    func clearHistory() { history.removeAll() }

    // MARK: - Launch at login (macOS 13+)

    private func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Launch at login toggle failed: \(error)")
            }
        }
    }

    // MARK: - Convenience: suggested OpenRouter models
    /// Free models đứng đầu (rate-limited ~20 req/min, ~200 req/day - đủ cho personal use).
    /// User có thể paste model ID khác vào ô "Or enter any OpenRouter model id".
    /// Danh sách model miễn phí cập nhật tại: https://openrouter.ai/models?max_price=0
    static let suggestedModels: [(name: String, id: String)] = [
        // ─── FREE TIER ───
        ("FREE • Gemini 2.0 Flash (recommended)", "google/gemini-2.0-flash-exp:free"),
        ("FREE • Gemini 2.0 Flash Thinking",      "google/gemini-2.0-flash-thinking-exp:free"),
        ("FREE • DeepSeek V3 (great for CJK)",    "deepseek/deepseek-chat:free"),
        ("FREE • DeepSeek R1 (reasoning)",        "deepseek/deepseek-r1:free"),
        ("FREE • Llama 3.3 70B",                  "meta-llama/llama-3.3-70b-instruct:free"),
        ("FREE • Qwen 2.5 72B (good for Asian)",  "qwen/qwen-2.5-72b-instruct:free"),
        ("FREE • Mistral 7B",                     "mistralai/mistral-7b-instruct:free"),

        // ─── PAID (cho ai cần chất lượng cao hơn) ───
        ("$ Gemini 2.5 Flash (fast)",     "google/gemini-2.5-flash"),
        ("$$ Gemini 2.5 Pro",             "google/gemini-2.5-pro"),
        ("$$ Claude Sonnet 4",            "anthropic/claude-sonnet-4"),
        ("$ Claude Haiku 4.5",            "anthropic/claude-haiku-4.5"),
        ("$ GPT-4o mini",                 "openai/gpt-4o-mini"),
        ("$$ GPT-4o",                     "openai/gpt-4o"),
    ]

    /// Map giá trị cũ user đã lưu (có thể typo / tên không chuẩn) về tên chuẩn trong list.
    /// Trả nil nếu không match được.
    static func normalizeLanguage(_ raw: String) -> String? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Đã chuẩn rồi
        if let exact = suggestedLanguages.first(where: { $0.lowercased() == lower }) {
            return exact
        }

        // Map vài alias phổ biến
        let aliases: [(keys: [String], canonical: String)] = [
            (["tieng viet", "tiếng việt", "vn", "viet", "vietnam", "vietnamses", "vietnamse"], "Vietnamese"),
            (["tieng anh", "tiếng anh", "en", "us", "usa", "english (us)", "english(us)", "anglais"], "English"),
            (["tieng nhat", "tiếng nhật", "jp", "ja", "nhat"], "Japanese"),
            (["tieng han", "tiếng hàn", "kr", "ko", "han"], "Korean"),
            (["tieng trung", "tiếng trung", "cn", "zh", "chinese"], "Chinese (Simplified)"),
            (["zh-tw", "traditional chinese", "trung phon the"], "Chinese (Traditional)"),
            (["thai lan", "thái"], "Thai"),
            (["indo", "indonesia"], "Indonesian"),
            (["phap"], "French"),
            (["duc"], "German"),
            (["tay ban nha", "es"], "Spanish"),
            (["nga", "ru"], "Russian"),
        ]
        for entry in aliases {
            if entry.keys.contains(where: { lower.contains($0) }) {
                return entry.canonical
            }
        }

        // Fuzzy: thử match prefix
        if let m = suggestedLanguages.first(where: { lower.hasPrefix($0.lowercased().prefix(4)) }) {
            return m
        }
        return nil
    }

    /// Danh sách ngôn ngữ thường dùng. Tên dùng tiếng Anh chuẩn (English, Vietnamese, …)
    /// để AI nhận diện chính xác — khác cách user gõ "tiếng Việt" / "vietnamse".
    static let suggestedLanguages = [
        "English",
        "Vietnamese",
        "Japanese",
        "Korean",
        "Chinese (Simplified)",
        "Chinese (Traditional)",
        "Thai",
        "Indonesian",
        "Malay",
        "Filipino",
        "Spanish",
        "French",
        "German",
        "Italian",
        "Portuguese",
        "Russian",
        "Arabic",
        "Hindi",
        "Bengali",
        "Turkish",
        "Polish",
        "Dutch",
        "Swedish",
        "Norwegian",
        "Danish",
        "Greek",
        "Hebrew",
        "Czech",
        "Hungarian",
        "Ukrainian",
        "Romanian",
    ]
}
