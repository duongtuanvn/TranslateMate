import Foundation
import os

/// Logger tập trung: in ra Console.app (filter bằng `subsystem=<bundle id>`)
/// đồng thời giữ buffer N entry cuối cùng để hiện trong Diagnostics tab.
final class AppLogger {
    static let shared = AppLogger()

    /// Subsystem = bundle ID của app hiện tại (auto-detect, không hardcode).
    /// Fallback "TranslateMate" nếu không lấy được.
    private let osLog = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TranslateMate",
        category: "main"
    )
    private let queue = DispatchQueue(label: "applogger", qos: .utility)
    private var buffer: [Entry] = []
    private let maxEntries = 200

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }
    enum Level: String { case info, warn, error }

    /// Listeners for UI refresh.
    private var listeners: [(([Entry]) -> Void)] = []

    func onChange(_ cb: @escaping ([Entry]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.listeners.append(cb)
            DispatchQueue.main.async { cb(self.buffer) }
        }
    }

    func info(_ message: String)  { log(.info, message)  }
    func warn(_ message: String)  { log(.warn, message)  }
    func error(_ message: String) { log(.error, message) }

    func log(_ level: Level, _ message: String) {
        switch level {
        case .info:  osLog.info("\(message, privacy: .public)")
        case .warn:  osLog.warning("\(message, privacy: .public)")
        case .error: osLog.error("\(message, privacy: .public)")
        }
        queue.async { [weak self] in
            guard let self else { return }
            let e = Entry(date: Date(), level: level, message: message)
            self.buffer.append(e)
            if self.buffer.count > self.maxEntries { self.buffer.removeFirst(self.buffer.count - self.maxEntries) }
            let snapshot = self.buffer
            DispatchQueue.main.async {
                for l in self.listeners { l(snapshot) }
            }
        }
    }

    func snapshot(completion: @escaping ([Entry]) -> Void) {
        queue.async { [weak self] in
            let b = self?.buffer ?? []
            DispatchQueue.main.async { completion(b) }
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.removeAll()
            let snapshot = self.buffer
            DispatchQueue.main.async {
                for l in self.listeners { l(snapshot) }
            }
        }
    }
}
