import Foundation

/// Registration flow — mirrors `atelerix_init.dart`. `ping` is a get-or-create
/// call: it registers this app under the project the first time it's called
/// for a given bundle id + OS, and just looks it up on every call after.
/// `registerUser` then creates a local user scoped to that app record.
enum LerixInit {
    private static let userIdKey = "lerix_user_id"
    private static let pingConfigKey = "lerix_ping_config"
    private static let externalIdKey = "lerix_external_id"
    private static let identityHashKey = "lerix_identity_hash"
    /// The install user id the stored external id was last confirmed for.
    /// When it differs from the current user (fresh `registerUser`, a
    /// replaced stale user, or an identify that failed earlier), the external
    /// id is sent again by `syncIdentity`.
    private static let identifiedUserKey = "lerix_identified_user"
    private static let userNotRegisteredCode = "USER_PROJECT_NOT_EXIST"

    /// The backend's `Platform` enum has no `macos` value, so a macOS build
    /// registers as `desktop`; the `os` field is what routes pushes (APNs for
    /// both "ios" and "macos").
    #if os(macOS)
    static let platform = "desktop"
    static let os = "macos"
    #else
    static let platform = "ios"
    static let os = "ios"
    #endif

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
            "platform": platform,
            // Despite the name, the backend's dispatch logic (`deliverToDevice`)
            // checks this field against the literal strings "ios"/"macos" to
            // decide which push service to use — it's a platform discriminator,
            // not an OS version. Sending the real OS version here (e.g. "17.0")
            // silently breaks push delivery: no branch matches, so nothing
            // ever gets sent and no error is ever recorded.
            "os": os,
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
        // A fresh install user has no external id on the backend yet.
        await syncIdentityQuietly()
        return userId
    }

    // MARK: - External user identity

    /// Persists the host app's user id and sends it to the backend. With no
    /// install user id yet (init still running, or offline) it stays queued
    /// and `registerUser`/`initialize` send it once registration completes.
    static func setUser(_ externalId: String, identityHash: String?) async throws {
        let id = externalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw LerixApiError.server(code: "EXTERNAL_ID_EMPTY", message: "externalId must not be empty")
        }
        LerixKeychain.write(externalIdKey, value: id)
        if let hash = identityHash, !hash.isEmpty {
            LerixKeychain.write(identityHashKey, value: hash)
        } else {
            LerixKeychain.delete(identityHashKey)
        }
        LerixKeychain.delete(identifiedUserKey)

        guard let userId = existingUserId() else {
            if LerixKeys.shared.debug {
                print("[Lerix] setUser queued until this install is registered")
            }
            return
        }
        try await identify(userId: userId, externalId: id, identityHash: identityHash, recoverStaleUser: true)
    }

    /// Forgets the stored external id and unlinks the install on the backend.
    static func clearUser() async throws {
        LerixKeychain.delete(externalIdKey)
        LerixKeychain.delete(identityHashKey)
        LerixKeychain.delete(identifiedUserKey)

        guard let userId = existingUserId() else { return }
        _ = try await LerixBackend.post(route: .logout, headers: ["app-user": userId])
    }

    /// Re-sends the stored external id if it hasn't been confirmed for the
    /// current install user. Never throws: a failure is retried on the next
    /// registration or launch.
    static func syncIdentityQuietly() async {
        guard let userId = existingUserId(),
              let externalId = LerixKeychain.read(externalIdKey), !externalId.isEmpty,
              LerixKeychain.read(identifiedUserKey) != userId else { return }
        do {
            try await identify(
                userId: userId,
                externalId: externalId,
                identityHash: LerixKeychain.read(identityHashKey),
                recoverStaleUser: false
            )
        } catch {
            if LerixKeys.shared.debug { print("[Lerix] identify failed: \(error)") }
        }
    }

    private static func identify(
        userId: String,
        externalId: String,
        identityHash: String?,
        recoverStaleUser: Bool
    ) async throws {
        var body: [String: Any] = ["externalId": externalId]
        if let hash = identityHash, !hash.isEmpty { body["identityHash"] = hash }

        do {
            _ = try await LerixBackend.post(route: .identify, data: body, headers: ["app-user": userId])
            LerixKeychain.write(identifiedUserKey, value: userId)
        } catch let LerixApiError.server(code, message) where code == userNotRegisteredCode && recoverStaleUser {
            // The stored install user no longer exists on the backend. Drop it
            // locally (a backend delete would fail the same way) and register
            // a new one; `registerUser` re-sends the stored external id.
            LerixKeychain.delete(userIdKey)
            LerixKeys.shared.projectUser = nil
            let newUserId = try await registerUser()
            guard LerixKeychain.read(identifiedUserKey) == newUserId else {
                throw LerixApiError.server(code: code, message: message)
            }
        }
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
