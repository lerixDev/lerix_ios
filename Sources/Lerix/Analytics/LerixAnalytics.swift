import Foundation

/// Analytics settings for `Lerix.initialize(analytics:)` (contract §7).
public struct LerixAnalyticsOptions {
    /// Record events at all. `Lerix.analytics.setEnabled(_:)` changes it at
    /// runtime and persists the choice.
    public var enabled: Bool
    /// `$session_start` / `$session_end`. Session ids are kept either way,
    /// so feedback and crashes still carry one.
    public var autoSessions: Bool
    /// Automatic `$screen_view`s from the UIKit hook (see
    /// `uikitScreenTracking`). `.lerixScreen(_:)` and `Lerix.screen` are
    /// explicit and always record.
    public var autoScreens: Bool
    /// Opt-in: record a `$screen_view` from every `UIViewController`'s
    /// `viewDidAppear(_:)` (method swizzling; off by default). Name a screen
    /// with `viewController.lerixScreenName`.
    public var uikitScreenTracking: Bool

    public init(enabled: Bool = true, autoSessions: Bool = true, autoScreens: Bool = true, uikitScreenTracking: Bool = false) {
        self.enabled = enabled
        self.autoSessions = autoSessions
        self.autoScreens = autoScreens
        self.uikitScreenTracking = uikitScreenTracking
    }
}

/// Product analytics: custom events, screen views and automatic lifecycle
/// events, batched through the durable outbox to `POST /plugin/events`.
/// Nothing here throws to the caller: invalid input is dropped (logged in
/// debug mode).
public final class LerixAnalytics {
    public static let shared = LerixAnalytics(store: .shared, outbox: .shared)

    static let firstFlushDelay: TimeInterval = 5
    static let flushInterval: TimeInterval = 30
    static let flushThreshold = 50

    let store: LerixStore
    let outbox: LerixOutbox
    var now: () -> Date = { Date() }
    /// Whether this install was registered before the install marker existed
    /// (an upgrade from an SDK without analytics): it must not count as a
    /// new install.
    var hasPreexistingInstall: () -> Bool = { LerixInit.existingUserId() != nil }

    private let queue = DispatchQueue(label: "dev.lerix.analytics")
    private var options = LerixAnalyticsOptions()
    private var runtimeEnabled = true
    private var started = false
    private var tracker: LerixSessionTracker
    private var currentScreen: String?
    private var pendingSinceFlush = 0
    private var pendingColdStart = false
    private var lastPersistedHeartbeat = Date.distantPast

    init(store: LerixStore, outbox: LerixOutbox) {
        self.store = store
        self.outbox = outbox
        var state: LerixSessionState?
        if let raw = store.get(LerixStoreKey.session), let data = try? JSONEncoder().encode(raw) {
            state = try? JSONDecoder().decode(LerixSessionState.self, from: data)
        }
        tracker = LerixSessionTracker(state: state)
    }

    // MARK: - Public API

    /// `false` after `setEnabled(false)` or `initialize(analytics: .init(enabled: false))`.
    public var isEnabled: Bool {
        queue.sync { runtimeEnabled } && store.bool(LerixStoreKey.analyticsEnabled) != false
    }

    /// Opt-out / consent switch. Disabling stops recording and clears the
    /// queue; the choice is persisted.
    public func setEnabled(_ enabled: Bool) {
        queue.sync { runtimeEnabled = enabled }
        store.setBool(LerixStoreKey.analyticsEnabled, enabled)
        if !enabled {
            outbox.clearEvents()
            queue.sync { pendingSinceFlush = 0 }
        }
    }

    /// Sends queued events now (fire and forget).
    public func flush() {
        queue.sync { pendingSinceFlush = 0 }
        Task { await outbox.drain(.analytics) }
    }

    /// Sends queued events and waits for the attempt to finish.
    public func flushAndWait() async {
        queue.sync { pendingSinceFlush = 0 }
        await outbox.drain(.analytics)
    }

    /// The current session id (also sent with feedback and error reports).
    public var sessionId: String? { queue.sync { tracker.state?.id } }

    // MARK: - Startup and lifecycle

    /// Called once from `Lerix.initialize`.
    func start(options: LerixAnalyticsOptions) {
        let launchedInBackground = LerixLifecycle.isInBackground
        let date = now()
        queue.sync {
            guard !started else { return }
            started = true
            self.options = options
            runtimeEnabled = options.enabled

            let markerMissing = store.date(LerixStoreKey.firstStartAt) == nil
            if markerMissing { store.setDate(LerixStoreKey.firstStartAt, date) }
            // A Keychain user id with no marker means an existing install
            // upgraded to this SDK: write the marker silently.
            let firstRun = markerMissing && !hasPreexistingInstall()

            let version = LerixDeviceInfo.collectApp().version ?? "0.0.0"
            let previousVersion = store.string(LerixStoreKey.lastAppVersion)
            store.setString(LerixStoreKey.lastAppVersion, version)

            // Session first, so $first_open / $app_update carry its id.
            if launchedInBackground {
                // Not an app start until the user actually opens it.
                pendingColdStart = true
            } else {
                countAppStartLocked()
                applyLocked(tracker.coldStart(now: date))
            }

            if firstRun {
                recordLocked(name: "$first_open", props: [:], date: date)
            } else if let previousVersion = previousVersion, previousVersion != version {
                recordLocked(name: "$app_update", props: ["from": .string(previousVersion), "to": .string(version)], date: date)
            }
        }

        #if canImport(UIKit)
        if options.uikitScreenTracking && options.autoScreens {
            LerixScreenTracking.installUIKitHook()
        }
        #endif

        let lifecycle = LerixLifecycle.shared
        lifecycle.onForeground = { [weak self] in self?.handleForeground() }
        lifecycle.onBackground = { [weak self] in self?.handleBackground() }
        lifecycle.start()

        outbox.scheduleDrain(after: Self.firstFlushDelay)
    }

    func handleForeground() {
        let date = now()
        queue.sync {
            if pendingColdStart {
                pendingColdStart = false
                countAppStartLocked()
                applyLocked(tracker.coldStart(now: date))
            } else {
                applyLocked(tracker.foreground(now: date))
            }
        }
        outbox.scheduleDrain(after: 2)
    }

    func handleBackground() {
        let date = now()
        queue.sync {
            applyLocked(tracker.background(now: date))
            pendingSinceFlush = 0
        }
        let outbox = self.outbox
        LerixLifecycle.withBackgroundTime {
            await outbox.drainAll()
        }
    }

    private func countAppStartLocked() {
        store.setInt(LerixStoreKey.appStarts, (store.int(LerixStoreKey.appStarts) ?? 0) + 1)
    }

    /// Persists the session and records the events it produced.
    private func applyLocked(_ events: [LerixAutoEvent]) {
        persistSessionLocked()
        guard options.autoSessions else { return }
        for event in events {
            recordLocked(name: event.name, props: event.props, eventId: event.eventId, sessionId: event.sessionId, date: event.date)
        }
    }

    private func persistSessionLocked() {
        lastPersistedHeartbeat = now()
        LerixCrashReporter.currentSessionId = tracker.state?.id
        guard let state = tracker.state,
              let data = try? JSONEncoder().encode(state),
              let json = try? JSONDecoder().decode(LerixJSON.self, from: data) else {
            store.set(LerixStoreKey.session, nil)
            return
        }
        store.set(LerixStoreKey.session, json)
    }

    // MARK: - Recording

    func track(_ name: String, props: [String: Any]?) {
        guard LerixEventValidator.isValidName(name, allowReserved: false) else {
            LerixLog.debug("Event \"\(name)\" dropped: invalid name (^[A-Za-z][A-Za-z0-9 _.:-]{1,63}$, $ is reserved)")
            return
        }
        let (clean, dropped) = LerixEventValidator.sanitize(props)
        if !dropped.isEmpty { LerixLog.debug("Event \"\(name)\": dropped props \(dropped)") }
        let date = now()
        queue.sync { recordLocked(name: name, props: clean, date: date) }
    }

    /// The SDK's own reserved `$` events (e.g. Release Control's). Skipped
    /// when analytics is disabled, like every other event.
    func trackInternal(_ name: String, props: [String: Any]) {
        guard LerixEventValidator.isValidName(name, allowReserved: true) else { return }
        let (clean, _) = LerixEventValidator.sanitize(props)
        let date = now()
        queue.sync { recordLocked(name: name, props: clean, date: date) }
    }

    enum ScreenSource {
        /// `Lerix.screen`: always recorded.
        case manual
        /// `.lerixScreen(_:)`: a repeat of the current screen is skipped.
        case modifier
        /// The UIKit hook: also gated by `autoScreens`.
        case uikit
    }

    func screen(_ name: String, props: [String: Any]?, source: ScreenSource) {
        let screen = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(LerixEventValidator.maxStringLength))
        guard !screen.isEmpty else { return }
        let date = now()
        let previous: String?? = queue.sync {
            if source == .uikit && !options.autoScreens { return .none }
            if source != .manual && currentScreen == screen { return .none }
            let previous = currentScreen
            currentScreen = screen
            return .some(previous)
        }
        guard case .some(let previousScreen) = previous else { return }

        LerixBreadcrumbs.shared.add(
            previousScreen.map { "\($0) → \(screen)" } ?? screen,
            category: .navigation,
            at: date
        )

        var (clean, dropped) = LerixEventValidator.sanitize(props)
        if !dropped.isEmpty { LerixLog.debug("Screen \"\(screen)\": dropped props \(dropped)") }
        clean["screen"] = .string(screen)
        if let previousScreen = previousScreen { clean["previous"] = .string(previousScreen) }
        while clean.count > LerixEventValidator.maxProps, let key = clean.keys.sorted().last(where: { $0 != "screen" && $0 != "previous" }) {
            clean.removeValue(forKey: key)
        }
        queue.sync { recordLocked(name: "$screen_view", props: clean, date: date) }
    }

    private func recordLocked(
        name: String,
        props: [String: LerixJSON],
        eventId: String? = nil,
        sessionId: String? = nil,
        date: Date
    ) {
        guard runtimeEnabled, store.bool(LerixStoreKey.analyticsEnabled) != false else { return }
        tracker.heartbeat(now: date)
        if date.timeIntervalSince(lastPersistedHeartbeat) > 15 { persistSessionLocked() }

        let id = eventId ?? LerixIds.make()
        var event: [String: LerixJSON] = [
            "eventId": .string(id),
            "name": .string(name),
            "ts": .number(Double(LerixTime.millis(date))),
        ]
        if let session = sessionId ?? tracker.state?.id { event["sessionId"] = .string(session) }
        if !props.isEmpty { event["props"] = .object(props) }
        if let screen = (name == "$screen_view" ? props["screen"]?.stringValue : currentScreen) {
            event["screen"] = .string(screen)
        }
        outbox.enqueue(LerixOutboxItem(id: id, kind: .event, createdAt: date, payload: .object(event)))

        pendingSinceFlush += 1
        if pendingSinceFlush >= Self.flushThreshold {
            pendingSinceFlush = 0
            outbox.scheduleDrain(after: 0)
        } else {
            outbox.scheduleDrain(after: Self.flushInterval)
        }
    }

    /// `context` of `POST /plugin/events`.
    static func context() -> [String: Any] {
        let app = LerixDeviceInfo.collectApp()
        var context: [String: Any] = [
            "platform": LerixPlatform.value,
            "os": LerixPlatform.osName,
            "osVersion": LerixPlatform.osVersion,
            "appVersion": app.version ?? "0.0.0",
            "build": app.buildNo ?? "0",
            "locale": LerixPlatform.locale,
            "environment": LerixKeys.shared.environment,
            "sdk": LerixSDK.name,
            "sdkVersion": LerixSDK.version,
            "deviceModel": LerixPlatform.deviceModel,
        ]
        if let country = LerixPlatform.countryCode { context["country"] = country }
        return context
    }
}
