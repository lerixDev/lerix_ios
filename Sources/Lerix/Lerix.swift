import Foundation

/// Public entry point for the native iOS SDK — `Lerix.initialize`,
/// `Lerix.throwError`, `Lerix.notifications` — mirroring the Flutter SDK's
/// top-level `Atelerix` class feature-for-feature, for apps with no Flutter
/// involved.
public enum Lerix {
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
        let keys = LerixKeys.shared
        keys.apiKey = apiKey
        keys.projectId = projectId
        keys.url = url
        keys.debug = debugMode

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

    public static func reRegisterUser() async throws {
        try await LerixInit.deleteUser()
        _ = try await LerixInit.registerUser()
    }
}
