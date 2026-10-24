import Foundation

/// The vendor kill switch (contract §2.5, E6) as every network path sees it.
/// `LerixAppControl` sets it from the app-config `sdk` block (persisted, so
/// it applies before any network on the next launch); it lifts by itself at
/// `until`. `GET /plugin/app-config` is never blocked, so the switch can be
/// lifted.
final class LerixSdkGate {
    static let shared = LerixSdkGate()

    private let lock = NSLock()
    private var modules: Set<String> = []
    /// Device time.
    private var until: Date?
    var now: () -> Date = { Date() }

    func set(modules: [String], until: Date?) {
        lock.lock()
        self.modules = Set(modules)
        self.until = until
        lock.unlock()
    }

    func clear() { set(modules: [], until: nil) }

    /// When `module` is blocked: the time it lifts, else `nil`.
    func blockedUntil(_ module: LerixSdkModule) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let until = until, until > now(), !modules.isEmpty else { return nil }
        if modules.contains(LerixSdkModule.all.rawValue) { return until }
        return modules.contains(module.rawValue) ? until : nil
    }

    func isBlocked(_ module: LerixSdkModule) -> Bool { blockedUntil(module) != nil }

    /// When the request to `path` is blocked: the time it lifts, else `nil`.
    func blockedUntil(path: String) -> Date? {
        guard let module = Self.module(forPath: path) else { return nil }
        return blockedUntil(module)
    }

    /// The module a backend route belongs to; `nil` for the app-config route,
    /// which is never blocked.
    static func module(forPath path: String) -> LerixSdkModule? {
        if path == LerixRoute.appConfig.path { return nil }
        if path.hasPrefix("plugin/bugs") { return .errors }
        if path.hasPrefix("plugin/notifications") { return .push }
        if path.hasPrefix("plugin/feedback") { return .feedback }
        if path.hasPrefix("plugin/surveys") { return .surveys }
        if path.hasPrefix("plugin/events") { return .analytics }
        if path.hasPrefix("plugin/traces") || path.hasPrefix("plugin/tracing") { return .tracing }
        return .core
    }

    static func module(for feature: LerixFeature) -> LerixSdkModule {
        switch feature {
        case .analytics: return .analytics
        case .feedback: return .feedback
        case .surveys: return .surveys
        }
    }
}
