import Foundation

/// Registration flow — mirrors `atelerix_init.dart`: register/lookup this
/// app under the project (`ping`), then register a local user against it.
enum AtelerixInit {
    private static let userIdKey = "atelerix_user_id"
    private static let pingConfigKey = "atelerix_ping_config"

    /// Registers (or looks up) this app under the project, caching the
    /// result in `AtelerixKeys.projectConfig`.
    static func registerApp(projectId: String) async throws -> AtelerixPingConfig {
        let app = AtelerixDeviceInfo.collectApp()
        let body: [String: Any] = [
            "projectId": projectId,
            "platform": "ios",
            "package": app.package ?? "unknown",
            "appName": app.name ?? "unknown",
        ]

        let response = try await AtelerixBackend.post(route: .initApp, data: body)
        let config = try decode(AtelerixPingConfig.self, from: response)
        AtelerixKeys.shared.projectConfig = config
        if let data = try? JSONEncoder().encode(config) {
            AtelerixKeychain.write(pingConfigKey, value: String(data: data, encoding: .utf8) ?? "")
        }
        return config
    }

    /// Registers (or re-registers) a local user against the app, returning
    /// the user id the backend assigned/confirmed.
    @discardableResult
    static func registerUser() async throws -> String {
        let device = AtelerixDeviceInfo.collectDevice()
        let app = AtelerixDeviceInfo.collectApp()
        let userId = existingUserId() ?? UUID().uuidString

        var body: [String: Any] = [
            "userId": userId,
            "os": "ios",
            "version": app.version ?? "0.0.0",
        ]
        if let appId = AtelerixKeys.shared.projectConfig?.appId {
            body["appId"] = appId
        }
        if let deviceData = try? JSONEncoder().encode(device),
           let deviceJson = String(data: deviceData, encoding: .utf8) {
            body["device"] = deviceJson
        }
        if let appData = try? JSONEncoder().encode(app),
           let appJson = String(data: appData, encoding: .utf8) {
            body["app"] = appJson
        }

        _ = try await AtelerixBackend.post(route: .registerUser, data: body)

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

    static func cachedPingConfig() -> AtelerixPingConfig? {
        if let cached = AtelerixKeys.shared.projectConfig { return cached }
        guard let raw = AtelerixKeychain.read(pingConfigKey), let data = raw.data(using: .utf8) else {
            return nil
        }
        let config = try? JSONDecoder().decode(AtelerixPingConfig.self, from: data)
        AtelerixKeys.shared.projectConfig = config
        return config
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: [String: Any]?) throws -> T {
        guard let json = json else { throw AtelerixBackendError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
