import Foundation

/// Registration flow — mirrors `atelerix_init.dart`. `ping` is a get-or-create
/// call: it registers this app under the project the first time it's called
/// for a given bundle id + OS, and just looks it up on every call after.
/// `registerUser` then creates a local user scoped to that app record.
enum AtelerixInit {
    private static let userIdKey = "atelerix_user_id"
    private static let pingConfigKey = "atelerix_ping_config"

    /// Registers (or looks up) this app under the project. The returned
    /// `id` is the backend's UUID for the app record — NOT the bundle id
    /// sent in the `appid` header — and is what `registerUser`'s
    /// `projectApp` field and the notifications routes' `appId` field
    /// reference.
    @discardableResult
    static func ping() async throws -> AtelerixPingConfig {
        let app = AtelerixDeviceInfo.collectApp()
        let headers: [String: String] = [
            "appid": app.package ?? "unknown",
            "projectid": AtelerixKeys.shared.projectId,
            "platform": "ios",
            // Despite the name, the backend's dispatch logic (`deliverToDevice`)
            // checks this field against the literal string "ios" to decide
            // which push service to use — it's a platform discriminator, not
            // an OS version. Sending the real OS version here (e.g. "17.0")
            // silently breaks push delivery: no branch matches, so nothing
            // ever gets sent and no error is ever recorded.
            "os": "ios",
        ]

        let response = try await AtelerixBackend.get(route: .ping, headers: headers)
        guard let data = response?["data"] as? [String: Any] else {
            throw AtelerixBackendError.invalidResponse
        }
        let config = try decode(AtelerixPingConfig.self, from: data)

        AtelerixKeys.shared.projectConfig = config
        if let encoded = try? JSONEncoder().encode(config), let json = String(data: encoded, encoding: .utf8) {
            AtelerixKeychain.write(pingConfigKey, value: json)
        }
        return config
    }

    /// Registers (or re-registers) a local user against the app, returning
    /// the user id the backend assigned.
    @discardableResult
    static func registerUser() async throws -> String {
        let config = try await cachedOrFreshPingConfig()
        let app = AtelerixDeviceInfo.collectApp()

        let body: [String: Any] = [
            "projectSlug": AtelerixKeys.shared.projectId,
            "projectApp": config.id ?? "",
            "version": app.version ?? "0.0.0",
        ]

        let response = try await AtelerixBackend.post(route: .registerUser, data: body)
        guard let userId = response?["user"] as? String else {
            throw AtelerixBackendError.invalidResponse
        }

        AtelerixKeychain.write(userIdKey, value: userId)
        AtelerixKeys.shared.projectUser = userId
        return userId
    }

    static func deleteUser() async throws {
        guard let userId = AtelerixKeys.shared.projectUser ?? existingUserId() else { return }
        _ = try await AtelerixBackend.delete(route: .deleteUser, headers: ["app-user": userId])
        AtelerixKeychain.delete(userIdKey)
        AtelerixKeys.shared.projectUser = nil
    }

    static func existingUserId() -> String? {
        if let cached = AtelerixKeys.shared.projectUser { return cached }
        let stored = AtelerixKeychain.read(userIdKey)
        AtelerixKeys.shared.projectUser = stored
        return stored
    }

    /// The app record's backend UUID, needed by `registerUser` and the
    /// notifications routes — cached in memory/Keychain, refreshed via a
    /// fresh `ping()` call if neither has it.
    static func cachedOrFreshPingConfig() async throws -> AtelerixPingConfig {
        if let cached = AtelerixKeys.shared.projectConfig { return cached }
        if let raw = AtelerixKeychain.read(pingConfigKey), let data = raw.data(using: .utf8),
           let stored = try? JSONDecoder().decode(AtelerixPingConfig.self, from: data) {
            AtelerixKeys.shared.projectConfig = stored
            return stored
        }
        return try await ping()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
