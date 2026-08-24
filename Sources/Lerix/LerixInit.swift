import Foundation

/// Registration flow — mirrors `atelerix_init.dart`. `ping` is a get-or-create
/// call: it registers this app under the project the first time it's called
/// for a given bundle id + OS, and just looks it up on every call after.
/// `registerUser` then creates a local user scoped to that app record.
enum LerixInit {
    private static let userIdKey = "lerix_user_id"
    private static let pingConfigKey = "lerix_ping_config"

    /// Registers (or looks up) this app under the project. The returned
    /// `id` is the backend's UUID for the app record — NOT the bundle id
    /// sent in the `appid` header — and is what `registerUser`'s
    /// `projectApp` field and the notifications routes' `appId` field
    /// reference.
    @discardableResult
    static func ping() async throws -> LerixPingConfig {
        let app = LerixDeviceInfo.collectApp()
        let headers: [String: String] = [
            "appid": app.package ?? "unknown",
            "projectid": LerixKeys.shared.projectId,
            "platform": "ios",
            // Despite the name, the backend's dispatch logic (`deliverToDevice`)
            // checks this field against the literal string "ios" to decide
            // which push service to use — it's a platform discriminator, not
            // an OS version. Sending the real OS version here (e.g. "17.0")
            // silently breaks push delivery: no branch matches, so nothing
            // ever gets sent and no error is ever recorded.
            "os": "ios",
        ]

        let response = try await LerixBackend.get(route: .ping, headers: headers)
        guard let data = response?["data"] as? [String: Any] else {
            throw LerixBackendError.invalidResponse
        }
        let config = try decode(LerixPingConfig.self, from: data)

        LerixKeys.shared.projectConfig = config
        if let encoded = try? JSONEncoder().encode(config), let json = String(data: encoded, encoding: .utf8) {
            LerixKeychain.write(pingConfigKey, value: json)
        }
        return config
    }

    /// Registers (or re-registers) a local user against the app, returning
    /// the user id the backend assigned.
    @discardableResult
    static func registerUser() async throws -> String {
        let config = try await cachedOrFreshPingConfig()
        let app = LerixDeviceInfo.collectApp()

        let body: [String: Any] = [
            "projectSlug": LerixKeys.shared.projectId,
            "projectApp": config.id ?? "",
            "version": app.version ?? "0.0.0",
        ]

        let response = try await LerixBackend.post(route: .registerUser, data: body)
        guard let userId = response?["user"] as? String else {
            throw LerixBackendError.invalidResponse
        }

        LerixKeychain.write(userIdKey, value: userId)
        LerixKeys.shared.projectUser = userId
        return userId
    }

    static func deleteUser() async throws {
        guard let userId = LerixKeys.shared.projectUser ?? existingUserId() else { return }
        _ = try await LerixBackend.delete(route: .deleteUser, headers: ["app-user": userId])
        LerixKeychain.delete(userIdKey)
        LerixKeys.shared.projectUser = nil
    }

    static func existingUserId() -> String? {
        if let cached = LerixKeys.shared.projectUser { return cached }
        let stored = LerixKeychain.read(userIdKey)
        LerixKeys.shared.projectUser = stored
        return stored
    }

    /// The app record's backend UUID, needed by `registerUser` and the
    /// notifications routes — cached in memory/Keychain, refreshed via a
    /// fresh `ping()` call if neither has it.
    static func cachedOrFreshPingConfig() async throws -> LerixPingConfig {
        if let cached = LerixKeys.shared.projectConfig { return cached }
        if let raw = LerixKeychain.read(pingConfigKey), let data = raw.data(using: .utf8),
           let stored = try? JSONDecoder().decode(LerixPingConfig.self, from: data) {
            LerixKeys.shared.projectConfig = stored
            return stored
        }
        return try await ping()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
