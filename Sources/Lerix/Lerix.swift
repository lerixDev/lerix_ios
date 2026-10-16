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
        environment: String? = nil,
        analytics: LerixAnalyticsOptions = LerixAnalyticsOptions(),
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
        keys.environment = LerixEnvironment.resolve(environment)

        LerixNotifications.shared.register()
        if enableCrashReporting {
            LerixCrashReporter.install()
        }

        let outbox = LerixOutbox.shared
        outbox.userIdProvider = { try? await LerixInit.ensureUserId() }
        outbox.reregister = {
            LerixInit.forgetLocalUser()
            _ = try? await LerixInit.ensureUserId()
        }
        outbox.eventContext = { LerixAnalytics.context() }
        LerixAnalytics.shared.start(options: analytics)

        Task {
            do {
                _ = try await LerixInit.ping()
                // Registration only needs to happen once per install — the
                // Keychain-persisted user id survives relaunches, so this
                // avoids creating a fresh backend user on every launch.
                if LerixInit.existingUserId() == nil {
                    _ = try await LerixInit.ensureUserId()
                } else {
                    // Sends a `setUser` id that was queued or failed earlier.
                    await LerixInit.syncIdentityQuietly()
                }
                await LerixCrashReporter.reportPendingCrashIfAny()
                // Warm the feedback config cache so the UI opens with the
                // dashboard's labels.
                await LerixFeedback.shared.refreshConfig()
            } catch {
                if debugMode { print("[Lerix] Initialization failed: \(error)") }
                onError?(error)
            }
        }
    }

    /// Manually report a caught error/crash. The current session id and the
    /// recent breadcrumbs (as `metadata.breadcrumbs`, unless you set that key)
    /// are attached.
    public static func throwError(
        _ issue: String,
        stack: [String] = [],
        type: BugType = .runtimeError,
        severity: BugSeverity = .medium,
        metadata: [String: Any]? = nil
    ) {
        var enriched = metadata ?? [:]
        if enriched["breadcrumbs"] == nil {
            let crumbs = LerixBreadcrumbs.shared.snapshot()
            if !crumbs.isEmpty { enriched["breadcrumbs"] = crumbs }
        }
        let finalMetadata: [String: Any]? = enriched.isEmpty ? nil : enriched
        Task {
            await ErrorsHandler.throwError(issue: issue, stack: stack, type: type, severity: severity, metadata: finalMetadata)
        }
    }

    // MARK: - Analytics

    /// Records a custom event. `name` must match `^[A-Za-z][A-Za-z0-9 _.:-]{1,63}$`;
    /// props allow up to 25 keys with string, number, bool or nil values.
    /// Invalid input is dropped (logged in debug mode); this never throws.
    public static func track(_ name: String, props: [String: Any]? = nil) {
        LerixAnalytics.shared.track(name, props: props)
    }

    /// Records a `$screen_view` (also a navigation breadcrumb).
    public static func screen(_ name: String, props: [String: Any]? = nil) {
        LerixAnalytics.shared.screen(name, props: props, source: .manual)
    }

    /// `flush()`, `flushAndWait()`, `setEnabled(_:)`, `sessionId`.
    public static var analytics: LerixAnalytics { LerixAnalytics.shared }

    /// Adds a breadcrumb (last 50 kept), sent with feedback and error reports.
    public static func addBreadcrumb(
        _ message: String,
        category: LerixBreadcrumbCategory = .custom,
        data: [String: Any]? = nil
    ) {
        LerixBreadcrumbs.shared.add(message, category: category, data: data)
    }

    public static var notifications: LerixNotifications { LerixNotifications.shared }

    /// In-app feedback: `show` (built-in UI), `submit` (headless),
    /// `setUserEmail`, `enableShakeToReport` (iOS).
    public static var feedback: LerixFeedback { LerixFeedback.shared }

    /// Surveys: `maybeShowNps(force:)`.
    public static var surveys: LerixSurveys { LerixSurveys.shared }

    /// Language, strings and accent colour of the built-in UI.
    public static var ui: LerixUI { LerixUI.shared }

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
