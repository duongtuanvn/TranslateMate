import Foundation
import Combine

/// Track local model nào đang bị rate-limited / hết quota.
///
/// OpenRouter không có endpoint trả "model X đã hết quota". Mình suy ra từ:
/// - HTTP 429 response → mark cooldown
/// - HTTP 400 "Developer instruction" / model-incompatible → mark cooldown ngắn
/// - Header `Retry-After` (nếu có) → dùng làm cooldown chính xác
/// - Body có `temporarily rate-limited` / `overloaded` → mark cooldown
///
/// Dùng để skip model trong fallback chain mà không phải retry mỗi lần.
@MainActor
final class RateLimitTracker: ObservableObject {
    static let shared = RateLimitTracker()

    /// model id → thời điểm cooldown hết. Persist qua launches để giữ trạng thái.
    @Published private(set) var cooldowns: [String: Date] = [:]

    /// Reason phát hiện ra rate limit (để show trong UI).
    @Published private(set) var reasons: [String: String] = [:]

    private let storeKey = "rateLimitCooldowns"
    private let reasonKey = "rateLimitReasons"

    init() {
        // Load persistent state
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            self.cooldowns = map
        }
        if let data = UserDefaults.standard.data(forKey: reasonKey),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            self.reasons = map
        }
        // Cleanup expired entries lần đầu
        purgeExpired()
    }

    /// Mark model là rate-limited cho đến `Date() + seconds`.
    func mark(_ modelID: String, cooldownSeconds: TimeInterval, reason: String) {
        let until = Date().addingTimeInterval(cooldownSeconds)
        cooldowns[modelID] = until
        reasons[modelID] = reason
        persist()
        AppLogger.shared.warn("RateLimit: \(modelID) cooldown \(Int(cooldownSeconds))s — \(reason)")
    }

    /// Còn bao nhiêu giây cooldown? nil = OK.
    func remainingCooldown(_ modelID: String) -> TimeInterval? {
        guard let until = cooldowns[modelID] else { return nil }
        let remaining = until.timeIntervalSinceNow
        if remaining <= 0 {
            // Auto-clean
            cooldowns.removeValue(forKey: modelID)
            reasons.removeValue(forKey: modelID)
            persist()
            return nil
        }
        return remaining
    }

    func isRateLimited(_ modelID: String) -> Bool {
        return remainingCooldown(modelID) != nil
    }

    func reason(for modelID: String) -> String? {
        guard isRateLimited(modelID) else { return nil }
        return reasons[modelID]
    }

    /// Format thời gian còn lại đẹp: "12s", "3m", "1h 5m"
    func remainingText(_ modelID: String) -> String? {
        guard let s = remainingCooldown(modelID) else { return nil }
        let total = Int(s)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// Xoá tất cả cooldown (user reset).
    func clearAll() {
        cooldowns.removeAll()
        reasons.removeAll()
        persist()
    }

    /// Loại bỏ entries đã hết hạn.
    func purgeExpired() {
        let now = Date()
        var changed = false
        for (k, v) in cooldowns where v <= now {
            cooldowns.removeValue(forKey: k)
            reasons.removeValue(forKey: k)
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cooldowns) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
        if let data = try? JSONEncoder().encode(reasons) {
            UserDefaults.standard.set(data, forKey: reasonKey)
        }
    }
}
