import Foundation

/// Public entry point for the native iOS SDK — `Lerix.initialize`,
/// `Lerix.throwError`, `Lerix.notifications` — mirroring the Flutter SDK's
/// top-level `Lerix` class feature-for-feature, for apps with no Flutter
/// involved.
public enum Lerix {
    /// Configure the SDK and register this install with the backend.
    /// Call once, e.g. from `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// Pass `enableCrashReporting: false` to skip installing the uncaught
    /// exception/signal handlers (e.g. if your app already has its own
    /// crash reporter and you only want manual `throwError` calls).
    ///
    /// Error filtering (applied to every report, including crashes reported
    /// on the next launch):
    /// - `ignoreErrors`: drop an error if any entry is a case-insensitive
    ///   substring of its message.
    /// - `ignoreErrorPatterns`: drop an error if any regex matches its message.
    /// - `beforeSend`: called after the ignore lists, right before sending;
    ///   return the (optionally modified) event to send it, or `nil` to drop it.
    public static func initialize(
        apiKey: String,
        projectId: String,
        url: String = "https://api.lerix.dev/v1",
        debugMode: Bool = false,
        enableCrashReporting: Bool = true,
        ignoreErrors: [String] = [],
        ignoreErrorPatterns: [NSRegularExpression] = [],
        beforeSend: ((LerixErrorEvent) -> LerixErrorEvent?)? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        let keys = LerixKeys.shared
        keys.apiKey = apiKey
        keys.projectId = projectId
        keys.url = url
        keys.debug = debugMode
        keys.ignoreErrors = ignoreErrors
        keys.ignoreErrorPatterns = ignoreErrorPatterns
        keys.beforeSend = beforeSend

        LerixNotifications.shared.register()
        if enableCrashReporting {
            LerixCrashReporter.install()
        }

        Task {
            do {
                _ = try await LerixInit.ping()
                // Registration only needs to happen once per install — the
                // Keychain-persisted user id survives relaunches, so this
                // avoids creating a fresh backend user on every launch.
                if LerixInit.existingUserId() == nil {
                    _ = try await LerixInit.registerUser()
                } else {
                    // Sends a `setUser` id that was queued or failed earlier.
                    await LerixInit.syncIdentityQuietly()
                }
                await LerixCrashReporter.reportPendingCrashIfAny()
            } catch {
                if debugMode { print("[Lerix] Initialization failed: \(error)") }
                onError?(error)
            }
        }
    }

    /// Manually report a caught error/crash.
    public static func throwError(
        _ issue: String,
        stack: [String] = [],
        type: BugType = .runtimeError,
        severity: BugSeverity = .medium,
        metadata: [String: Any]? = nil
    ) {
        Task {
            await ErrorsHandler.throwError(issue: issue, stack: stack, type: type, severity: severity, metadata: metadata)
        }
    }

    public static var notifications: LerixNotifications { LerixNotifications.shared }

    public static func getUserId() -> String? {
        LerixInit.existingUserId()
    }

    public static func isUserRegistered() -> Bool {
        LerixInit.existingUserId() != nil
    }

    public static func deleteUser() async throws {
        try await LerixInit.deleteUser()
    }

    /// Links this install to your app's own user id — call after login.
    ///
    /// Your backend can then target all of this user's devices with
    /// `externalUserIds` when sending notifications. If the project requires
    /// identity verification, pass `identityHash`: the hex HMAC-SHA256 of
    /// `externalId` keyed with the project's identity secret, computed on
    /// your server. Never ship the identity secret in the app.
    ///
    /// The id is stored in the Keychain and re-sent automatically whenever
    /// this install gets a new Lerix user id. Called before `initialize` has
    /// registered the install, it is queued and sent once registration
    /// completes. Throws if the backend rejects it (e.g. an invalid hash).
    public static func setUser(_ externalId: String, identityHash: String? = nil) async throws {
        try await LerixInit.setUser(externalId, identityHash: identityHash)
    }

    /// Unlinks this install from your app's user — call on logout. The
    /// install id from `getUserId()` is kept.
    public static func clearUser() async throws {
        try await LerixInit.clearUser()
    }

    public static func reRegisterUser() async throws {
        try await LerixInit.deleteUser()
        _ = try await LerixInit.registerUser()
    }
}
