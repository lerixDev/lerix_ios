import Foundation

/// Public entry point for the native iOS SDK — mirrors the top-level
/// `Atelerix` class in the Flutter SDK (`Atelerix.init`, `Atelerix.throwError`,
/// `Atelerix.notifications`), for apps with no Flutter involved.
public enum Atelerix {
    /// Configure the SDK and register this install with the backend.
    /// Call once, e.g. from `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// Pass `enableCrashReporting: false` to skip installing the uncaught
    /// exception/signal handlers (e.g. if your app already has its own
    /// crash reporter and you only want manual `throwError` calls).
    public static func initialize(
        apiKey: String,
        projectId: String,
        url: String = "https://api.atelerix.dev/v1",
        debugMode: Bool = false,
        enableCrashReporting: Bool = true,
        onError: ((Error) -> Void)? = nil
    ) {
        let keys = AtelerixKeys.shared
        keys.apiKey = apiKey
        keys.projectId = projectId
        keys.url = url
        keys.debug = debugMode

        AtelerixNotifications.shared.register()
        if enableCrashReporting {
            AtelerixCrashReporter.install()
        }

        Task {
            do {
                _ = try await AtelerixInit.ping()
                // Registration only needs to happen once per install — the
                // Keychain-persisted user id survives relaunches, so this
                // avoids creating a fresh backend user on every launch.
                if AtelerixInit.existingUserId() == nil {
                    _ = try await AtelerixInit.registerUser()
                }
                await AtelerixCrashReporter.reportPendingCrashIfAny()
            } catch {
                if debugMode { print("[Atelerix] Initialization failed: \(error)") }
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

    public static var notifications: AtelerixNotifications { AtelerixNotifications.shared }

    public static func getUserId() -> String? {
        AtelerixInit.existingUserId()
    }

    public static func isUserRegistered() -> Bool {
        AtelerixInit.existingUserId() != nil
    }

    public static func deleteUser() async throws {
        try await AtelerixInit.deleteUser()
    }

    public static func reRegisterUser() async throws {
        try await AtelerixInit.deleteUser()
        _ = try await AtelerixInit.registerUser()
    }
}
