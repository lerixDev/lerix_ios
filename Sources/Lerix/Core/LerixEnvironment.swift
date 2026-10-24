import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// SDK identity, sent as `context.sdk` / `context.sdkVersion`. Keep
/// `version` equal to `Lerix.podspec`'s `s.version`.
enum LerixSDK {
    static let name = "lerix-ios"
    static let version = "1.5.1"
}

/// Environment resolution (contract §0): an explicit value from `initialize`
/// wins; otherwise `dev` for debug builds and the simulator, `prod` otherwise.
enum LerixEnvironment {
    private static let pattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_-]{1,31}$")

    static func isValid(_ value: String) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    static var autoDetected: String {
        #if DEBUG
        return "dev"
        #else
        #if targetEnvironment(simulator)
        return "dev"
        #else
        return "prod"
        #endif
        #endif
    }

    static func resolve(_ explicit: String?) -> String {
        guard let explicit = explicit?.trimmingCharacters(in: .whitespaces).lowercased(), !explicit.isEmpty else {
            return autoDetected
        }
        guard isValid(explicit) else {
            print("[Lerix] Invalid environment \"\(explicit)\" (must match ^[a-z][a-z0-9_-]{1,31}$); using \(autoDetected)")
            return autoDetected
        }
        return explicit
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

/// Platform values from contract §0 — the new feedback/survey/event routes
/// take `ios`/`macos` (unlike `register-user`, which needs `desktop`).
enum LerixPlatform {
    #if os(macOS)
    static let value = "macos"
    static let osName = "macOS"
    #else
    static let value = "ios"
    static var osName: String { UIDevice.current.systemName }
    #endif

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Hardware model such as `iPhone15,2` (the simulator reports the model
    /// it simulates).
    static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buffer, &size, nil, 0)
            return String(cString: buffer)
        }
        #endif
        return LerixDeviceInfo.architecture()
    }

    /// BCP-47 style, e.g. `ar-OM`.
    static var locale: String {
        Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    }

    static var countryCode: String? { Locale.current.regionCode }
}

enum LerixIds {
    private static let pattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{8,64}$")

    /// A client id (`clientId`, `eventId`): lowercase UUID v4.
    static func make() -> String { UUID().uuidString.lowercased() }

    static func isValid(_ id: String) -> Bool {
        pattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }
}

enum LerixTime {
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func iso(_ date: Date) -> String { iso.string(from: date) }
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

enum LerixLog {
    static func debug(_ message: @autoclosure () -> String) {
        if LerixKeys.shared.debug { print("[Lerix] \(message())") }
    }
}
