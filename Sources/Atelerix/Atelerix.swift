import Foundation

/// Public entry point for the native iOS SDK — mirrors the top-level
/// `Atelerix` class in the Flutter SDK (`Atelerix.init`, `Atelerix.throwError`,
/// `Atelerix.notifications`), for apps with no Flutter involved.
public enum Atelerix {
    /// Configure the SDK and register this install with the backend.
    /// Call once, e.g. from `application(_:didFinishLaunchingWithOptions:)`.
    public static func initialize(
        apiKey: String,
        projectId: String,
        url: String = "https://api.atelerix.dev/v1",
        debugMode: Bool = false,
        onError: ((Error) -> Void)? = nil
    ) {
        let keys = AtelerixKeys.shared
        keys.apiKey = apiKey
        keys.projectId = projectId
        keys.url = url
        keys.debug = debugMode

        AtelerixNotifications.shared.register()

        Task {
            do {
                _ = try await AtelerixInit.ping()
                _ = try await AtelerixInit.registerUser()
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
