import Foundation

/// The classification of a reported bug — mirrors `BugType` in the Flutter
/// SDK and the backend's own enum, so a bug reported from a native iOS app
/// shows up identically in the dashboard.
public enum BugType: String {
    case runtimeError = "runtime_error"
    case logicBug = "logic_bug"
    case uiBug = "ui_bug"
    case networkError = "network_error"
    case performance = "performance"
    case compatibility = "compatibility"
    case validationError = "validation_error"
    case security = "security"
    case crash = "crash"
    case unknown = "unknown"
}

/// Mirrors `BugSeverity` in the Flutter SDK.
public enum BugSeverity: String {
    case critical
    case high
    case medium
    case low
    case unknown
}

/// Device metadata attached to every error report — mirrors the Flutter
/// SDK's `Device` model exactly (same JSON keys), collected from
/// `UIDevice`/`Locale`/`TimeZone` instead of a platform channel.
struct LerixDevice: Codable {
    var deviceName: String?
    var arc: String?
    var osName: String?
    var osVersion: String?
    var timeZone: String?
    var countryCode: String?
}

/// App metadata attached to every error report — mirrors the Flutter SDK's
/// `App` model, collected from `Bundle.main` instead of `package_info_plus`.
struct LerixApp: Codable {
    var name: String?
    var package: String?
    var version: String?
    var buildNo: String?
}

/// The `data` payload of a `/plugin/init/ping` response — mirrors `PingModel`.
/// `id` is the backend's UUID for this app record (not the bundle id sent in
/// the `appid` header) — it's what `register-user`'s `projectApp` field and
/// notification calls' `appId` field actually reference.
struct LerixPingConfig: Codable {
    var id: String?
    var appId: String?
    var platform: String?
    var os: String?
    var projectSlug: String?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case appId = "appID"
        case platform
        case os
        case projectSlug
        case status
    }
}
