import Foundation

/// Where the SDK keeps its files: `Application Support/lerix/` on iOS (the
/// container is per app), `Application Support/<bundle id>/lerix/` on macOS
/// (shared by every non-sandboxed app, so it needs the bundle id).
enum LerixPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #if os(macOS)
        let url = base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "lerix-app", isDirectory: true)
            .appendingPathComponent("lerix", isDirectory: true)
        #else
        let url = base.appendingPathComponent("lerix", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

/// Small persistent key/value state (install marker, app starts, session,
/// kill-switch deadlines, cached configs, survey history), stored as one
/// JSON file in the SDK directory. Unlike the Keychain, it is removed with
/// the app, which is what "first open" needs.
final class LerixStore {
    static let shared = LerixStore(url: LerixPaths.root.appendingPathComponent("state.json"))

    private let url: URL
    private let lock = NSLock()
    private var values: [String: LerixJSON]

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: LerixJSON].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
    }

    func get(_ key: String) -> LerixJSON? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ value: LerixJSON?) {
        lock.lock()
        values[key] = value
        let snapshot = values
        lock.unlock()
        persist(snapshot)
    }

    /// Applies several changes with one write.
    func update(_ changes: (inout [String: LerixJSON]) -> Void) {
        lock.lock()
        changes(&values)
        let snapshot = values
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [String: LerixJSON]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Typed helpers

    func string(_ key: String) -> String? { get(key)?.stringValue }
    func setString(_ key: String, _ value: String?) { set(key, value.map { .string($0) }) }

    func double(_ key: String) -> Double? { get(key)?.doubleValue }
    func int(_ key: String) -> Int? { get(key)?.doubleValue.map { Int($0) } }
    func setInt(_ key: String, _ value: Int?) { set(key, value.map { .number(Double($0)) }) }

    func bool(_ key: String) -> Bool? { get(key)?.boolValue }
    func setBool(_ key: String, _ value: Bool?) { set(key, value.map { .bool($0) }) }

    /// Dates are stored as epoch seconds.
    func date(_ key: String) -> Date? { double(key).map { Date(timeIntervalSince1970: $0) } }
    func setDate(_ key: String, _ value: Date?) { set(key, value.map { .number($0.timeIntervalSince1970) }) }
}

/// Persisted state keys, in one place so they never collide.
enum LerixStoreKey {
    static let firstStartAt = "firstStartAt"           // the install marker
    static let appStarts = "appStarts"
    static let lastAppVersion = "lastAppVersion"
    static let session = "session"
    static let analyticsEnabled = "analyticsEnabled"
    static let userEmail = "feedbackUserEmail"
    static let feedbackConfig = "feedbackConfig"
    static let feedbackConfigAt = "feedbackConfigAt"
    static let surveysConfig = "surveysConfig"
    static let surveysConfigAt = "surveysConfigAt"
    static let appControlCache = "appControl.cache"
    static let appControlRemindVersion = "appControl.remindVersion"
    static let appControlRemindUntil = "appControl.remindUntil"
    static let appControlSkippedVersion = "appControl.skippedVersion"
    static func disabledUntil(_ feature: LerixFeature) -> String { "disabledUntil.\(feature.rawValue)" }
    static func survey(_ id: String, _ field: String) -> String { "survey.\(id).\(field)" }
}

/// A feature whose traffic the server can switch off with `SDK_DISABLED`.
enum LerixFeature: String, CaseIterable {
    case analytics
    case feedback
    case surveys
}
