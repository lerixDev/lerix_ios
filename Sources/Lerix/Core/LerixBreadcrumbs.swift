import Foundation

/// Breadcrumb categories from contract §3.3.
public enum LerixBreadcrumbCategory: String {
    case navigation
    case log
    case http
    case ui
    case custom
}

/// Ring buffer of the last 50 breadcrumbs, attached to feedback and to
/// handled-error reports (`metadata.breadcrumbs`). Screen views add one
/// automatically. In memory only: a fresh process starts empty.
final class LerixBreadcrumbs {
    static let shared = LerixBreadcrumbs()
    static let capacity = 50

    private struct Crumb {
        let ts: Date
        let category: LerixBreadcrumbCategory
        let message: String
        let data: [String: Any]?
    }

    private let lock = NSLock()
    private var crumbs: [Crumb] = []

    func add(_ message: String, category: LerixBreadcrumbCategory = .custom, data: [String: Any]? = nil, at date: Date = Date()) {
        let trimmed = String(message.prefix(1024))
        guard !trimmed.isEmpty else { return }
        // Keep only JSON-serialisable data so a snapshot can always be sent.
        let safeData = data.flatMap { LerixJSON(any: $0)?.anyValue as? [String: Any] }
        lock.lock()
        crumbs.append(Crumb(ts: date, category: category, message: trimmed, data: safeData))
        if crumbs.count > Self.capacity { crumbs.removeFirst(crumbs.count - Self.capacity) }
        lock.unlock()
    }

    /// Oldest first (newest last), as the contract expects.
    func snapshot() -> [[String: Any]] {
        lock.lock()
        let copy = crumbs
        lock.unlock()
        return copy.map { crumb in
            var entry: [String: Any] = [
                "ts": LerixTime.iso(crumb.ts),
                "category": crumb.category.rawValue,
                "message": crumb.message,
            ]
            if let data = crumb.data { entry["data"] = data }
            return entry
        }
    }

    func clear() {
        lock.lock(); crumbs.removeAll(); lock.unlock()
    }
}
