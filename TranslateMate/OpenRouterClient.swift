import Foundation

/// Gọi OpenRouter (https://openrouter.ai/api/v1/chat/completions).
/// OpenRouter hỗ trợ OpenAI-compatible schema.
struct OpenRouterClient {

    struct Message: Encodable {
        let role: String   // "system" | "user"
        let content: String
    }

    struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let max_tokens: Int?
    }

    struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String? }
            let message: Msg
        }
        struct APIError: Decodable {
            let message: String
            let code: String?
        }
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
        }
        let choices: [Choice]?
        let error: APIError?
        let usage: Usage?
        let model: String?  // model thực tế provider dùng (đôi khi khác request)
    }

    /// Kết quả translate — kèm metadata để tính cost.
    struct TranslationResult {
        let text: String
        let modelUsed: String       // model id được dùng thực tế
        let promptTokens: Int
        let completionTokens: Int
        /// Cost USD ước tính (nếu lookup được pricing).
        let costUSD: Double?
    }

    enum ClientError: LocalizedError {
        case badResponse(Int, String)
        case emptyResult
        case apiError(String)
        case invalidURL
        /// Toàn bộ chain (toàn free model) đều fail vì rate-limit / capacity
        /// → gợi ý user chuyển sang paid model.
        case freeModelsExhausted(attempted: [String], lastBody: String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let code, let body):
                return "OpenRouter HTTP \(code): \(body.prefix(300))"
            case .emptyResult:
                return "OpenRouter returned an empty translation."
            case .apiError(let msg):
                return "OpenRouter error: \(msg)"
            case .invalidURL:
                return "Invalid OpenRouter URL."
            case .freeModelsExhausted(let attempted, _):
                return "All free models attempted are currently rate-limited or busy.\n\nTried: \(attempted.joined(separator: ", "))"
            }
        }
    }

    /// Public translate — tự động thử primary model trước, nếu 429 thì fallback chain.
    /// Trả về `TranslationResult` kèm tokens và cost ước tính.
    /// `alternativeLanguage`: ngôn ngữ "đối lập" cho auto-swap. Khi source đã là
    /// targetLanguage, model sẽ output alternativeLanguage thay vì rewrite cùng ngôn ngữ.
    /// User đã config cả 2 target (replace + popup) → cặp song ngữ tự nhiên.
    func translate(
        text: String,
        targetLanguage: String,
        alternativeLanguage: String,
        style: TranslationStyle,
        model: String,
        apiKey: String,
        customInstructions: String,
        fallbackModels: [String] = [],
        knownModels: [ModelInfo] = []
    ) async throws -> TranslationResult {
        // Tổng hợp chain: primary + fallbacks (loại duplicate)
        var chain = [model]
        for f in fallbackModels where !chain.contains(f) { chain.append(f) }

        var lastError: Error = ClientError.emptyResult
        var lastBody: String = ""
        var attempted: [String] = []
        var allFreeAndCapacityIssue = true  // true nếu mọi failure đều là free model + rate-limit/capacity

        // Snapshot cooldown status từ MainActor 1 lần.
        let cooldownSet: Set<String> = await MainActor.run {
            let tracker = RateLimitTracker.shared
            return Set(chain.filter { tracker.isRateLimited($0) })
        }
        var filteredChain = chain.filter { !cooldownSet.contains($0) }
        for skipped in cooldownSet {
            AppLogger.shared.info("⏭️  Skipping \(skipped) — in cooldown")
        }
        // Nếu CẢ chain đang cooldown, vẫn thử primary (có thể vừa hết hạn).
        if filteredChain.isEmpty { filteredChain = [chain[0]] }

        for (idx, m) in filteredChain.enumerated() {
            attempted.append(m)
            do {
                let raw = try await translateOnce(
                    text: text,
                    targetLanguage: targetLanguage,
                    alternativeLanguage: alternativeLanguage,
                    style: style,
                    model: m,
                    apiKey: apiKey,
                    customInstructions: customInstructions
                )
                if idx > 0 {
                    AppLogger.shared.info("✅ Fallback succeeded with: \(m) (after \(idx) failure(s))")
                }
                // Tính cost USD nếu có pricing.
                let cost = estimateCost(modelID: raw.modelUsed, prompt: raw.promptTokens,
                                        completion: raw.completionTokens, knownModels: knownModels)
                return TranslationResult(
                    text: raw.text,
                    modelUsed: raw.modelUsed,
                    promptTokens: raw.promptTokens,
                    completionTokens: raw.completionTokens,
                    costUSD: cost
                )
            } catch {
                lastError = error
                if let ce = error as? ClientError, case let .badResponse(_, body) = ce {
                    lastBody = body
                }
                // Mark cooldown nếu lỗi rate-limit / capacity / model-incompatible.
                await markCooldownIfNeeded(model: m, error: error)

                // Track: nếu có model paid trong chain hoặc lỗi không phải rate-limit/capacity,
                // thì không phải scenario "free exhausted".
                if !m.hasSuffix(":free") {
                    allFreeAndCapacityIssue = false
                } else if !isRateLimitOrCapacity(error: error) {
                    allFreeAndCapacityIssue = false
                }
                if shouldFallback(error: error) && idx < filteredChain.count - 1 {
                    AppLogger.shared.warn("Model \(m) failed (\(error.localizedDescription.prefix(80))), trying next…")
                    continue
                } else {
                    break
                }
            }
        }

        // Tất cả chain đã thử mà fail. Nếu toàn free + lý do rate-limit/capacity → throw exhausted.
        if allFreeAndCapacityIssue && attempted.count >= 2 {
            AppLogger.shared.error("All \(attempted.count) free models exhausted (rate-limit/capacity). Suggesting paid models.")
            throw ClientError.freeModelsExhausted(attempted: attempted, lastBody: lastBody)
        }
        throw lastError
    }

    /// Đặt cooldown cho model dựa vào loại error.
    @MainActor
    private func markCooldownIfNeeded(model: String, error: Error) {
        guard let ce = error as? ClientError, case let .badResponse(code, body) = ce else { return }
        let tracker = RateLimitTracker.shared

        // 429 hoặc body chứa rate-limit → mark theo Retry-After hoặc 60s default.
        if code == 429 || body.contains("rate-limited") || body.contains("rate limit") {
            // Cố parse Retry-After từ body (OpenRouter đôi khi nhúng số giây)
            let cooldown = parseRetryAfter(from: body) ?? 60
            tracker.mark(model, cooldownSeconds: cooldown, reason: "Rate limited (429)")
            return
        }
        // 503 / overloaded → cooldown ngắn 30s
        if code == 503 || body.contains("overloaded") || body.contains("temporarily") {
            tracker.mark(model, cooldownSeconds: 30, reason: "Provider tạm thời unavailable")
            return
        }
        // 400 model-incompatible (vd Gemma không nhận system) → cooldown DÀI vì lỗi vĩnh viễn
        if code == 400 && body.contains("Developer instruction") {
            tracker.mark(model, cooldownSeconds: 24 * 3600, reason: "Model không hỗ trợ system instruction")
            return
        }
        // 404 No endpoints → cooldown dài (model có thể đã bị remove)
        if code == 404 || body.contains("No endpoints found") {
            tracker.mark(model, cooldownSeconds: 24 * 3600, reason: "Endpoint không khả dụng")
            return
        }
    }

    /// Tìm số giây retry-after trong body. Ví dụ "Please retry after 45 seconds" → 45.
    private func parseRetryAfter(from body: String) -> TimeInterval? {
        // Pattern đơn giản: tìm số tiếp theo từ "retry"
        let lower = body.lowercased()
        if let range = lower.range(of: "retry") {
            let tail = String(lower[range.upperBound...]).prefix(50)
            // Lấy số nguyên đầu tiên
            let chars = Array(tail)
            var i = 0; var num = ""
            while i < chars.count, !chars[i].isNumber { i += 1 }
            while i < chars.count, chars[i].isNumber { num.append(chars[i]); i += 1 }
            if let n = TimeInterval(num), n > 0, n < 600 { return n }
        }
        return nil
    }

    /// Lỗi là do rate limit hoặc capacity của free tier không?
    private func isRateLimitOrCapacity(error: Error) -> Bool {
        guard let ce = error as? ClientError, case let .badResponse(code, body) = ce else {
            return false
        }
        if code == 429 { return true }
        if body.contains("rate-limited") || body.contains("rate limit") { return true }
        if body.contains("temporarily") || body.contains("capacity") { return true }
        if body.contains("overloaded") { return true }
        // 400 với "Developer instruction" cũng coi là incompatible (không phải rate limit
        // nhưng cùng nhóm "free model đang gặp vấn đề")
        if code == 400 && body.contains("Developer instruction") { return true }
        return false
    }

    /// Quyết định có nên fallback sang model khác không.
    /// Fallback cho: 429 rate limit, 404 model not found, 5xx server error,
    /// timeout, và một số lỗi 400 chỉ ra model bất tương thích (vd Gemma không
    /// nhận system instruction).
    /// KHÔNG fallback cho: 401/403 (auth issue), 400 do API key/payload sai
    /// hoàn toàn (sẽ luôn fail với mọi model).
    private func shouldFallback(error: Error) -> Bool {
        if let ce = error as? ClientError, case let .badResponse(code, body) = ce {
            if code == 429 { return true }                       // rate limit
            if code == 404 { return true }                       // model not found
            if code >= 500 && code < 600 { return true }         // server error
            if body.contains("rate-limited") || body.contains("rate limit") { return true }
            if body.contains("No endpoints found") { return true }

            // Lỗi 400 do model-specific incompatibility — fallback sang model khác
            if code == 400 {
                let modelIncompatible = [
                    "Developer instruction is not enabled",  // Gemma không nhận system
                    "INVALID_ARGUMENT",                      // Google generic invalid
                    "system_instruction",                    // Generic system msg issue
                    "does not support",                      // Provider không hỗ trợ feature
                    "is not supported",                      // Tương tự
                ]
                for hint in modelIncompatible where body.contains(hint) { return true }
            }
            return false
        }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain { return true }      // network/timeout
        return false
    }

    /// Một lần gọi API, không retry. Trả về raw result (chưa có cost).
    private func translateOnce(
        text: String,
        targetLanguage: String,
        alternativeLanguage: String,
        style: TranslationStyle,
        model: String,
        apiKey: String,
        customInstructions: String
    ) async throws -> TranslationResult {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw ClientError.invalidURL
        }

        let system = buildSystemPrompt(
            targetLanguage: targetLanguage,
            alternativeLanguage: alternativeLanguage,
            style: style,
            customInstructions: customInstructions
        )
        let user = "<source_text>\n\(text)\n</source_text>"

        let body = RequestBody(
            model: model,
            messages: [Message(role: "system", content: system),
                       Message(role: "user", content: user)],
            temperature: 0.2,
            max_tokens: 2000
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("TranslateMate/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("TranslateMate", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 30

        AppLogger.shared.info("OpenRouter POST model=\(model) target=\(targetLanguage) len=\(text.count)")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            AppLogger.shared.error("OpenRouter HTTP \(http.statusCode) for \(model): \(bodyStr.prefix(200))")
            throw ClientError.badResponse(http.statusCode, bodyStr)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        if let apiErr = decoded.error {
            AppLogger.shared.error("OpenRouter API error for \(model): \(apiErr.message)")
            throw ClientError.apiError(apiErr.message)
        }
        guard let content = decoded.choices?.first?.message.content, !content.isEmpty else {
            AppLogger.shared.error("OpenRouter returned empty content for \(model)")
            throw ClientError.emptyResult
        }

        let promptT = decoded.usage?.prompt_tokens ?? 0
        let completionT = decoded.usage?.completion_tokens ?? 0
        AppLogger.shared.info("Tokens: prompt=\(promptT) completion=\(completionT) for \(model)")

        return TranslationResult(
            text: sanitize(content),
            modelUsed: decoded.model ?? model,
            promptTokens: promptT,
            completionTokens: completionT,
            costUSD: nil  // sẽ được tính ở translate()
        )
    }

    /// Tính cost USD từ tokens và pricing của model.
    /// Pricing trong OpenRouter là USD/token (vd "0.000001" = $1/1M tokens).
    private func estimateCost(modelID: String, prompt: Int, completion: Int, knownModels: [ModelInfo]) -> Double? {
        guard let m = knownModels.first(where: { $0.id == modelID }) else {
            // Cũng thử match bỏ ":free" suffix
            let stripped = modelID.replacingOccurrences(of: ":free", with: "")
            if let m2 = knownModels.first(where: { $0.id == stripped || $0.id.hasPrefix(stripped) }) {
                return computeCost(pricing: m2.pricing, prompt: prompt, completion: completion)
            }
            return nil
        }
        return computeCost(pricing: m.pricing, prompt: prompt, completion: completion)
    }

    private func computeCost(pricing: ModelInfo.Pricing?, prompt: Int, completion: Int) -> Double? {
        guard let pricing else { return nil }
        let pPrice = Double(pricing.prompt ?? "0") ?? 0
        let cPrice = Double(pricing.completion ?? "0") ?? 0
        let cost = (Double(prompt) * pPrice) + (Double(completion) * cPrice)
        return cost
    }

    // MARK: - Models discovery

    struct ModelInfo: Codable, Identifiable, Equatable {
        let id: String
        let name: String?
        let pricing: Pricing?
        let context_length: Int?

        struct Pricing: Codable, Equatable {
            let prompt: String?
            let completion: String?
        }

        var displayName: String { name ?? id }

        var isFree: Bool {
            // Free khi prompt = "0" hoặc id kết thúc bằng :free
            if id.hasSuffix(":free") { return true }
            if let p = pricing?.prompt, (p == "0" || p == "0.0" || Double(p) == 0) {
                return true
            }
            return false
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [ModelInfo]
    }

    /// Fetch danh sách models hiện có trên OpenRouter. Endpoint public, không cần auth.
    func fetchModels() async throws -> [ModelInfo] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else {
            throw ClientError.invalidURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("TranslateMate/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0, "No HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.badResponse(http.statusCode, body)
        }
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        AppLogger.shared.info("fetchModels: got \(decoded.data.count) models, \(decoded.data.filter(\.isFree).count) free")
        return decoded.data
    }

    /// Kiểm tra nhanh API key có hợp lệ không bằng endpoint /auth/key.
    /// Không tiêu credit, trả về thông tin subscription/rate-limit.
    func validateKey(apiKey: String) async throws -> String {
        guard let url = URL(string: "https://openrouter.ai/api/v1/auth/key") else {
            throw ClientError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0, "No HTTP response")
        }
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        if !(200..<300).contains(http.statusCode) {
            AppLogger.shared.error("validateKey HTTP \(http.statusCode): \(bodyStr.prefix(300))")
            throw ClientError.badResponse(http.statusCode, bodyStr)
        }
        AppLogger.shared.info("validateKey OK: \(bodyStr.prefix(200))")
        return bodyStr
    }

    private func buildSystemPrompt(
        targetLanguage: String,
        alternativeLanguage: String,
        style: TranslationStyle,
        customInstructions: String
    ) -> String {
        // Nếu user vô tình config target == alt (cùng ngôn ngữ), không có gì để swap.
        // Khi đó tắt logic auto-swap, chỉ dịch sang target.
        let sameLang = targetLanguage.lowercased() == alternativeLanguage.lowercased()

        var s: String
        if sameLang {
            s = """
            You are a professional translator.
            Translate the text inside <source_text>...</source_text> to \(targetLanguage).
            Auto-detect the source language. If the source is already \(targetLanguage), keep it as-is or refine it slightly.

            Return ONLY the translated text — no explanations, no quotes, no prefixes or suffixes, no markdown, no language label.
            Preserve line breaks and inline formatting of the source.
            """
        } else {
            s = """
            You are a professional bilingual translator working between \(targetLanguage) and \(alternativeLanguage).

            How to decide the OUTPUT language:
            1. Detect the language of the text inside <source_text>...</source_text>.
            2. If the source is \(targetLanguage), output \(alternativeLanguage) (auto-swap).
            3. Otherwise, output \(targetLanguage).

            This way the output is ALWAYS in a different language than the input — the user is always swapping between \(targetLanguage) and \(alternativeLanguage).

            Return ONLY the translated text — no explanations, no quotes, no prefixes or suffixes, no markdown, no language label.
            Preserve line breaks and inline formatting of the source.
            """
        }
        switch style {
        case .natural:
            s += "\nUse natural, fluent phrasing that a native speaker would actually say."
        case .literal:
            s += "\nUse a faithful, literal translation that stays close to the source wording."
        case .casual:
            s += "\nUse a casual, friendly tone — like a chat message to a friend. Keep it conversational."
        case .formal:
            s += "\nUse a formal, polite register suitable for business or professional contexts."
        }
        let extra = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            s += "\nAdditional instructions: \(extra)"
        }
        return s
    }

    /// Bỏ các ký tự thừa phổ biến mà LLM hay thêm (backtick, dấu ngoặc ôm toàn bộ).
    private func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Gỡ markdown fences nếu có
        if s.hasPrefix("```") {
            if let firstNL = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNL)...])
            }
            if s.hasSuffix("```") {
                s = String(s.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Gỡ cặp quote ôm trọn
        if s.count >= 2 {
            let first = s.first!, last = s.last!
            let pairs: [(Character, Character)] = [("\"","\""), ("'","'"), ("“","”"), ("‘","’")]
            if pairs.contains(where: { $0.0 == first && $0.1 == last }) {
                s = String(s.dropFirst().dropLast())
            }
        }
        return s
    }
}
