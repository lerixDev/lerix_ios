import Foundation

/// Release Control settings for `Lerix.initialize(appControl:)`
/// (CONTRACT-release-control §2).
public struct LerixAppControlOptions {
    /// Fetch `GET /plugin/app-config` at all. With `false` there is no fetch,
    /// no UI and no events; a cached SDK kill switch still applies.
    public var enabled: Bool
    /// Show the built-in maintenance screen, required-update screen and
    /// update dialog. With `false`, observe `Lerix.appControl.onChange` and
    /// draw your own screens.
    public var ui: Bool

    public init(enabled: Bool = true, ui: Bool = true) {
        self.enabled = enabled
        self.ui = ui
    }
}

public enum LerixUpdateState: String, Equatable, Sendable {
    case available
    case recommended
    case required
}

public enum LerixUpdateReason: String, Equatable, Sendable {
    case outdated
    case belowMinimum = "below_minimum"
    case blockedVersion = "blocked_version"
    case deadlinePassed = "deadline_passed"
}

/// `update` of the app-config response (contract §1.2).
public struct LerixAppUpdate: Equatable, Sendable {
    public let state: LerixUpdateState
    /// `nil` when the server sent a reason this SDK version doesn't know.
    public let reason: LerixUpdateReason?
    public let ruleId: String?
    public let latestVersion: String?
    public let minVersion: String?
    /// `nil`: no store link is known; the built-in UI hides "Update".
    public let storeUrl: URL?
    public let title: String
    public let message: String
    public let releaseNotes: String?
    public let remindAfterHours: Int
    /// Only ever `true` for `available`.
    public let allowSkip: Bool
    /// A `recommended` update that becomes `required` at this time.
    public let requiredAt: Date?
}

/// `maintenance` of the app-config response (contract §1.2). In
/// `LerixAppControlState` it is only present while the window is active.
public struct LerixMaintenance: Equatable, Sendable {
    public let id: String
    public let title: String
    public let message: String
    public let imageUrl: URL?
    public let startsAt: Date
    public let endsAt: Date
    /// Show "Expected back at …" on the screen.
    public let showEndsAt: Bool
}

/// `sdk` of the app-config response: the Lerix vendor kill switch (E6).
public struct LerixSdkControl: Equatable, Sendable {
    /// `all`, or some of `errors`, `analytics`, `tracing`, `feedback`,
    /// `surveys`, `push`.
    public let disabled: [String]
    public let until: Date
}

/// What `Lerix.appControl` currently applies, already filtered by time,
/// "Later" and "Skip this version".
public struct LerixAppControlState: Equatable, Sendable {
    public let update: LerixAppUpdate?
    public let maintenance: LerixMaintenance?
    public let sdk: LerixSdkControl?

    public static let empty = LerixAppControlState(update: nil, maintenance: nil, sdk: nil)

    public init(update: LerixAppUpdate?, maintenance: LerixMaintenance?, sdk: LerixSdkControl?) {
        self.update = update
        self.maintenance = maintenance
        self.sdk = sdk
    }

    /// Precedence (contract §2.3): maintenance > required > recommended/available.
    var screen: LerixAppControlScreen {
        if let maintenance = maintenance { return .maintenance(maintenance) }
        if let update = update {
            return update.state == .required ? .requiredUpdate(update) : .softUpdate(update)
        }
        return .none
    }
}

enum LerixAppControlScreen: Equatable {
    case none
    case maintenance(LerixMaintenance)
    case requiredUpdate(LerixAppUpdate)
    case softUpdate(LerixAppUpdate)
}

/// Modules the vendor kill switch can turn off (contract §2.5). `core` is
/// init/ping/register/identify: only `all` stops it.
enum LerixSdkModule: String, CaseIterable {
    case all
    case errors
    case analytics
    case tracing
    case feedback
    case surveys
    case push
    case core
}

/// The parsed `GET /plugin/app-config` body. Parsing is defensive (contract
/// §2.2): an unknown field is ignored; a part with a wrong type or an
/// unknown enum value is treated as absent, never as an error.
struct LerixAppConfig: Equatable {
    var serverTime: Date?
    var ttlSeconds: TimeInterval
    var etag: String?
    var update: LerixAppUpdate?
    var maintenance: LerixMaintenance?
    var sdk: LerixSdkControl?

    static let defaultTTL: TimeInterval = 3600

    init(serverTime: Date? = nil, ttlSeconds: TimeInterval = defaultTTL, etag: String? = nil,
         update: LerixAppUpdate? = nil, maintenance: LerixMaintenance? = nil, sdk: LerixSdkControl? = nil) {
        self.serverTime = serverTime
        self.ttlSeconds = ttlSeconds
        self.etag = etag
        self.update = update
        self.maintenance = maintenance
        self.sdk = sdk
    }

    init(json: [String: Any]) {
        serverTime = Self.date(json["serverTime"])
        if let ttl = Self.number(json["ttlSeconds"]), ttl.isFinite, ttl > 0 {
            ttlSeconds = min(max(ttl, 10), 86_400)
        } else {
            ttlSeconds = Self.defaultTTL
        }
        etag = Self.nonEmpty(json["etag"])
        update = (json["update"] as? [String: Any]).flatMap(Self.parseUpdate)
        maintenance = (json["maintenance"] as? [String: Any]).flatMap(Self.parseMaintenance)
        sdk = (json["sdk"] as? [String: Any]).flatMap(Self.parseSdk)
    }

    // MARK: Parts

    static func parseUpdate(_ json: [String: Any]) -> LerixAppUpdate? {
        guard let rawState = json["state"] as? String, let state = LerixUpdateState(rawValue: rawState) else { return nil }
        let ui = LerixUI.shared
        let defaultTitle = ui.string(state == .required ? "appControl.required.title" : "appControl.available.title")
        let defaultMessage = ui.string(state == .required ? "appControl.required.message" : "appControl.available.message")
        let remind = number(json["remindAfterHours"]).flatMap { $0.isFinite ? Int($0) : nil }
        return LerixAppUpdate(
            state: state,
            reason: (json["reason"] as? String).flatMap(LerixUpdateReason.init(rawValue:)),
            ruleId: nonEmpty(json["ruleId"]),
            latestVersion: nonEmpty(json["latestVersion"]),
            minVersion: nonEmpty(json["minVersion"]),
            storeUrl: url(json["storeUrl"]),
            title: nonEmpty(json["title"]) ?? defaultTitle,
            message: nonEmpty(json["message"]) ?? defaultMessage,
            releaseNotes: nonEmpty(json["releaseNotes"]),
            remindAfterHours: min(max(remind ?? 72, 1), 720),
            allowSkip: state == .available && (json["allowSkip"] as? Bool ?? false),
            requiredAt: date(json["requiredAt"])
        )
    }

    static func parseMaintenance(_ json: [String: Any]) -> LerixMaintenance? {
        guard let id = nonEmpty(json["id"]),
              let startsAt = date(json["startsAt"]),
              let endsAt = date(json["endsAt"]),
              endsAt > startsAt else { return nil }
        let ui = LerixUI.shared
        return LerixMaintenance(
            id: id,
            title: nonEmpty(json["title"]) ?? ui.string("appControl.maintenance.title"),
            message: nonEmpty(json["message"]) ?? ui.string("appControl.maintenance.message"),
            imageUrl: url(json["imageUrl"]),
            startsAt: startsAt,
            endsAt: endsAt,
            showEndsAt: json["showEndsAt"] as? Bool ?? true
        )
    }

    static func parseSdk(_ json: [String: Any]) -> LerixSdkControl? {
        guard let until = date(json["until"]), let raw = json["disabled"] as? [Any] else { return nil }
        let known = Set(LerixSdkModule.allCases.filter { $0 != .core }.map(\.rawValue))
        var modules: [String] = []
        for case let module as String in raw where known.contains(module) && !modules.contains(module) {
            modules.append(module)
        }
        guard !modules.isEmpty else { return nil }
        return LerixSdkControl(disabled: modules, until: until)
    }

    // MARK: Scalars

    static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    static func url(_ value: Any?) -> URL? {
        guard let string = nonEmpty(value), let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), ["https", "http", "itms-apps", "macappstore"].contains(scheme) else { return nil }
        return url
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateLock = NSLock()

    static func date(_ value: Any?) -> Date? {
        guard let string = nonEmpty(value) else { return nil }
        dateLock.lock(); defer { dateLock.unlock() }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}

/// The persisted cache (contract §2.2): `{body, etag, fetchedAt, clockOffsetMs}`
/// plus the app/SDK version it was fetched for.
struct LerixAppConfigCache: Equatable {
    var body: LerixJSON
    var etag: String?
    var fetchedAt: Date
    /// `serverTime - deviceNow` at fetch time.
    var clockOffsetMs: Double
    var appVersion: String?
    var build: String?
    var sdkVersion: String?

    var config: LerixAppConfig {
        var config = LerixAppConfig(json: (body.anyValue as? [String: Any]) ?? [:])
        if config.etag == nil { config.etag = etag }
        return config
    }

    var json: LerixJSON {
        var object: [String: LerixJSON] = [
            "body": body,
            "fetchedAt": .number(fetchedAt.timeIntervalSince1970),
            "clockOffsetMs": .number(clockOffsetMs),
        ]
        if let etag = etag { object["etag"] = .string(etag) }
        if let appVersion = appVersion { object["appVersion"] = .string(appVersion) }
        if let build = build { object["build"] = .string(build) }
        if let sdkVersion = sdkVersion { object["sdkVersion"] = .string(sdkVersion) }
        return .object(object)
    }

    init(body: LerixJSON, etag: String?, fetchedAt: Date, clockOffsetMs: Double,
         appVersion: String?, build: String?, sdkVersion: String?) {
        self.body = body
        self.etag = etag
        self.fetchedAt = fetchedAt
        self.clockOffsetMs = clockOffsetMs
        self.appVersion = appVersion
        self.build = build
        self.sdkVersion = sdkVersion
    }

    init?(json: LerixJSON?) {
        guard let object = json?.objectValue, let body = object["body"], body.objectValue != nil,
              let fetchedAt = object["fetchedAt"]?.doubleValue else { return nil }
        self.body = body
        etag = object["etag"]?.stringValue
        self.fetchedAt = Date(timeIntervalSince1970: fetchedAt)
        let offset = object["clockOffsetMs"]?.doubleValue ?? 0
        clockOffsetMs = offset.isFinite ? offset : 0
        appVersion = object["appVersion"]?.stringValue
        build = object["build"]?.stringValue
        sdkVersion = object["sdkVersion"]?.stringValue
    }
}

/// "Later" / "Skip this version", persisted per `latestVersion`.
struct LerixUpdatePrefs: Equatable {
    var remindVersion: String?
    var remindUntil: Date?
    var skippedVersion: String?
}

/// Turns a cached config into the state to apply (contract §2.2 table).
/// Pure, so the offline rules are testable without a clock or a server.
enum LerixAppControlEvaluator {
    /// A cached available/recommended update is dropped after this long.
    static let softUpdateMaxAge: TimeInterval = 7 * 86_400

    /// The `latestVersion` key "Later"/"Skip" are stored under.
    static func versionKey(_ update: LerixAppUpdate) -> String { update.latestVersion ?? "" }

    static func evaluate(
        cache: LerixAppConfigCache?,
        prefs: LerixUpdatePrefs,
        appVersion: String?,
        build: String?,
        sdkVersion: String,
        now: Date
    ) -> LerixAppControlState {
        guard let cache = cache else { return .empty }
        let config = cache.config
        let serverNow = now.addingTimeInterval(cache.clockOffsetMs / 1000)

        // A response for another app version says nothing about this one
        // (the user updated, or downgraded): its update part is void.
        var update = config.update
        if cache.appVersion != appVersion || cache.build != build { update = nil }
        if let current = update, current.state != .required {
            if now.timeIntervalSince(cache.fetchedAt) >= softUpdateMaxAge || now < cache.fetchedAt.addingTimeInterval(-86_400) {
                update = nil
            } else if isHidden(current, prefs: prefs, now: now) {
                update = nil
            }
        }

        var maintenance: LerixMaintenance?
        if let window = config.maintenance, window.startsAt <= serverNow, serverNow < window.endsAt {
            maintenance = window
        }

        var sdk: LerixSdkControl?
        if let control = config.sdk, cache.sdkVersion == nil || cache.sdkVersion == sdkVersion, serverNow < control.until {
            sdk = control
        }
        return LerixAppControlState(update: update, maintenance: maintenance, sdk: sdk)
    }

    static func isHidden(_ update: LerixAppUpdate, prefs: LerixUpdatePrefs, now: Date) -> Bool {
        guard update.state != .required else { return false }
        let key = versionKey(update)
        if update.state == .available, update.allowSkip, prefs.skippedVersion == key { return true }
        if prefs.remindVersion == key, let until = prefs.remindUntil, now < until { return true }
        return false
    }

    /// The next device time at which `evaluate` can give a different answer
    /// without a fetch (maintenance start/end, kill-switch expiry, "Later"
    /// expiry, soft-update cache expiry).
    static func nextTransition(cache: LerixAppConfigCache?, prefs: LerixUpdatePrefs, now: Date) -> Date? {
        guard let cache = cache else { return nil }
        let config = cache.config
        let offset = cache.clockOffsetMs / 1000
        var candidates: [Date] = []
        if let window = config.maintenance {
            candidates.append(window.startsAt.addingTimeInterval(-offset))
            candidates.append(window.endsAt.addingTimeInterval(-offset))
        }
        if let sdk = config.sdk { candidates.append(sdk.until.addingTimeInterval(-offset)) }
        if let until = prefs.remindUntil { candidates.append(until) }
        if let update = config.update, update.state != .required {
            candidates.append(cache.fetchedAt.addingTimeInterval(softUpdateMaxAge))
        }
        return candidates.filter { $0 > now }.min()
    }
}
