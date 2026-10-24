import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Draws the built-in Release Control screens. Always called on the main thread.
protocol LerixAppControlPresenting: AnyObject {
    func render(_ state: LerixAppControlState)
}

/// Release Control (CONTRACT-release-control §2): update prompts, forced
/// updates, the maintenance screen and the Lerix vendor kill switch.
///
/// The last `GET /plugin/app-config` answer is persisted and applied at
/// launch before any network, then refreshed: at launch, when the app comes
/// to the foreground and its `ttlSeconds` has passed, every `ttlSeconds`
/// while it is ≤ 60 s, and on a silent `config_refresh` push.
///
/// With the built-in UI off (`LerixAppControlOptions(ui: false)`), observe
/// `onChange` and call `openStore()`, `later()` and `skip()` from your own
/// screens. Nothing here throws to the app.
public final class LerixAppControl {
    public static let shared = LerixAppControl(store: .shared, transport: LerixURLSessionTransport())

    struct AppInfo: Equatable {
        var version: String?
        var build: String?
        var bundleId: String?
    }

    let store: LerixStore
    let transport: LerixTransport
    let gate: LerixSdkGate

    // Replaceable in tests.
    var now: () -> Date = { Date() }
    var appInfo: () -> AppInfo = { LerixAppControl.currentAppInfo() }
    var userIdProvider: () -> String? = { LerixInit.existingUserId() }
    var installIdProvider: () -> String? = { LerixSurveys.installId }
    var tracker: (String, [String: Any]) -> Void = { LerixAnalytics.shared.trackInternal($0, props: $1) }
    var sessionIdProvider: () -> String? = { LerixAnalytics.shared.sessionId }
    var urlOpener: (URL) -> Void = { LerixAppControl.openURL($0) }
    /// Called (main thread) with the modules the kill switch just released.
    var onGateLifted: (Set<LerixSdkModule>) -> Void = { _ in }
    /// Whether timers and lifecycle observers run (off in unit tests).
    var schedulesTimers = true
    /// Whether `start` fetches in the background (off in unit tests, which
    /// fetch with `refresh()` so scripted responses can't race the launch fetch).
    var fetchesOnStart = true

    private let lock = NSLock()
    private var options = LerixAppControlOptions()
    private var started = false
    private var cache: LerixAppConfigCache?
    private var _state: LerixAppControlState = .empty
    private var blockedModules: Set<LerixSdkModule> = []
    private var inFlight: Task<LerixAppControlState, Never>?
    private var listeners: [UUID: (LerixAppControlState) -> Void] = [:]
    private var _onChange: ((LerixAppControlState) -> Void)?
    private var maintenanceShown: [String: String] = [:]   // window id → session key
    private var softPromptSession: String?
    private var inForeground = true
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: DispatchSourceTimer?
    private var pollInterval: TimeInterval?
    private var transitionWork: DispatchWorkItem?
    private let processSession = UUID().uuidString
    var presenter: LerixAppControlPresenting?

    init(store: LerixStore, transport: LerixTransport, gate: LerixSdkGate = .shared) {
        self.store = store
        self.transport = transport
        self.gate = gate
    }

    // MARK: - Public API

    /// The current state, already filtered by time, "Later" and "Skip".
    public var state: LerixAppControlState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Called on the main thread whenever `state` changes.
    public var onChange: ((LerixAppControlState) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChange }
        set { lock.lock(); _onChange = newValue; lock.unlock() }
    }

    /// Adds a change listener (main thread) besides `onChange`. Returns a
    /// token for `removeListener(_:)`.
    @discardableResult
    public func addListener(_ listener: @escaping (LerixAppControlState) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); listeners[id] = listener; lock.unlock()
        return id
    }

    public func removeListener(_ id: UUID) {
        lock.lock(); listeners[id] = nil; lock.unlock()
    }

    /// Fetches the config now (ignoring `ttlSeconds`) and returns the new
    /// state. Offline, it returns the state from the cache.
    @discardableResult
    public func refresh() async -> LerixAppControlState {
        await fetch()
    }

    /// `refresh()` with a completion on the main thread.
    public func refresh(completion: ((LerixAppControlState) -> Void)?) {
        Task {
            let state = await fetch()
            DispatchQueue.main.async { completion?(state) }
        }
    }

    /// Opens the store page of the current update. Returns `false` when there
    /// is no update or no store link.
    @discardableResult
    public func openStore() -> Bool {
        guard let update = state.update else { return false }
        trackAction("update", update)
        guard let url = update.storeUrl else { return false }
        DispatchQueue.main.async { [urlOpener] in urlOpener(url) }
        return true
    }

    /// Hides an available/recommended update for its `remindAfterHours`
    /// (persisted for its `latestVersion`). No effect on a required update.
    public func later() {
        guard let update = state.update, update.state != .required else { return }
        trackAction("later", update)
        store.update { values in
            values[LerixStoreKey.appControlRemindVersion] = .string(LerixAppControlEvaluator.versionKey(update))
            values[LerixStoreKey.appControlRemindUntil] = .number(
                now().addingTimeInterval(TimeInterval(update.remindAfterHours) * 3600).timeIntervalSince1970
            )
        }
        reevaluate()
    }

    /// Hides an available update until `latestVersion` changes. Only when
    /// `allowSkip` (recommended and required updates are never skippable).
    public func skip() {
        guard let update = state.update, update.state == .available, update.allowSkip else { return }
        trackAction("skip", update)
        store.setString(LerixStoreKey.appControlSkippedVersion, LerixAppControlEvaluator.versionKey(update))
        reevaluate()
    }

    // MARK: - Startup

    /// Called once from `Lerix.initialize`, before any other network: applies
    /// the persisted config (and kill switch), then fetches.
    func start(options: LerixAppControlOptions) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        self.options = options
        cache = LerixAppConfigCache(json: store.get(LerixStoreKey.appControlCache))
        lock.unlock()

        if options.enabled && options.ui && schedulesTimers {
            onMain { [weak self] in
                guard let self = self, self.presenter == nil else { return }
                self.presenter = LerixAppControlUI(control: self)
                self.presenter?.render(self.state)
            }
        }
        reevaluate()
        guard options.enabled else { return }
        if schedulesTimers {
            onMain { [weak self] in self?.observeLifecycle() }
        }
        guard fetchesOnStart else { return }
        Task { [weak self] in _ = await self?.fetch() }
    }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return options.enabled
    }

    var usesBuiltInUI: Bool {
        lock.lock(); defer { lock.unlock() }
        return options.enabled && options.ui
    }

    // MARK: - Silent push

    /// Handles a silent `config_refresh` push. Returns whether it was one.
    @discardableResult
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard LerixAppControlPush.isConfigRefresh(userInfo) else { return false }
        LerixLog.debug("config_refresh push: fetching app config")
        LerixLifecycle.withBackgroundTime { [weak self] in
            _ = await self?.fetch()
        }
        return true
    }

    // MARK: - Fetch

    /// One fetch at a time; concurrent callers share it.
    func fetch() async -> LerixAppControlState {
        guard isEnabled else { return state }
        let task: Task<LerixAppControlState, Never> = {
            lock.lock(); defer { lock.unlock() }
            if let running = inFlight { return running }
            let task = Task { [weak self] () -> LerixAppControlState in
                guard let self = self else { return .empty }
                return await self.performFetch()
            }
            inFlight = task
            return task
        }()
        let result = await task.value
        clearInFlight(task)
        return result
    }

    private func clearInFlight(_ task: Task<LerixAppControlState, Never>) {
        lock.lock(); defer { lock.unlock() }
        if inFlight == task { inFlight = nil }
    }

    private func performFetch() async -> LerixAppControlState {
        let app = appInfo()
        let previous: LerixAppConfigCache? = { lock.lock(); defer { lock.unlock() }; return cache }()
        var headers: [String: String] = [:]
        if let user = userIdProvider(), !user.isEmpty { headers["app-user"] = user }
        // A cached body for another app/SDK version must not be confirmed by a 304.
        if let previous = previous, let etag = previous.etag,
           previous.appVersion == app.version, previous.build == app.build, previous.sdkVersion == LerixSDK.version {
            headers["If-None-Match"] = etag
        }

        let response = await transport.get(route: .appConfig, headers: headers, query: query(app: app))
        let date = now()
        let status = response.effectiveStatus

        if status == 304, var confirmed = previous, headers["If-None-Match"] != nil {
            confirmed.fetchedAt = date
            save(confirmed)
        } else if let status = status, (200..<300).contains(status), let payload = response.payload,
                  let body = LerixJSON(any: payload), body.objectValue != nil {
            let config = LerixAppConfig(json: payload)
            let offsetMs = config.serverTime.map { $0.timeIntervalSince(date) * 1000 } ?? 0
            let etag = response.etag ?? config.etag
            let fresh = LerixAppConfigCache(
                body: body,
                etag: etag,
                fetchedAt: date,
                clockOffsetMs: offsetMs.isFinite ? offsetMs : 0,
                appVersion: app.version,
                build: app.build,
                sdkVersion: LerixSDK.version
            )
            save(fresh)
            if let etag = etag, etag != previous?.etag {
                track("$config_applied", ["etag": etag])
            }
        } else {
            LerixLog.debug("App config not refreshed (status \(status.map(String.init) ?? "offline")); keeping the cache")
        }
        return reevaluate()
    }

    private func save(_ newCache: LerixAppConfigCache) {
        lock.lock(); cache = newCache; lock.unlock()
        store.set(LerixStoreKey.appControlCache, newCache.json)
    }

    func query(app: AppInfo) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "platform", value: Self.platform),
            URLQueryItem(name: "environment", value: LerixKeys.shared.environment),
            URLQueryItem(name: "locale", value: Self.requestLocale()),
            URLQueryItem(name: "sdk", value: LerixSDK.name),
            URLQueryItem(name: "sdkVersion", value: LerixSDK.version),
        ]
        if let version = app.version { items.append(URLQueryItem(name: "appVersion", value: version)) }
        if let build = app.build { items.append(URLQueryItem(name: "build", value: build)) }
        if let bundleId = app.bundleId { items.append(URLQueryItem(name: "appId", value: bundleId)) }
        if let installId = installIdProvider(), !installId.isEmpty {
            items.append(URLQueryItem(name: "installId", value: installId))
        }
        return items
    }

    /// Contract §0: iPadOS = `ios`, Mac Catalyst = `macos`.
    static var platform: String {
        #if targetEnvironment(macCatalyst)
        return "macos"
        #else
        return LerixPlatform.value
        #endif
    }

    /// The language the built-in UI uses, as BCP-47, so server copy and
    /// buttons match: the device locale (`ar-OM`) when its language is the
    /// UI language, else the UI language alone.
    static func requestLocale() -> String {
        let ui = LerixUI.shared
        if let explicit = ui.locale?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return explicit.replacingOccurrences(of: "_", with: "-")
        }
        let device = LerixPlatform.locale.split(separator: "@").first.map(String.init) ?? "en"
        return LerixUI.baseLanguage(device) == ui.language ? device : ui.language
    }

    static func currentAppInfo() -> AppInfo {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces)
        let build = (info?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces)
        return AppInfo(
            version: (version?.isEmpty == false) ? version : nil,
            // Contract §1.1: a non-integer build is ignored.
            build: build.flatMap { UInt64($0) != nil ? $0 : nil },
            bundleId: Bundle.main.bundleIdentifier
        )
    }

    // MARK: - Evaluation

    var prefs: LerixUpdatePrefs {
        LerixUpdatePrefs(
            remindVersion: store.string(LerixStoreKey.appControlRemindVersion),
            remindUntil: store.date(LerixStoreKey.appControlRemindUntil),
            skippedVersion: store.string(LerixStoreKey.appControlSkippedVersion)
        )
    }

    /// Recomputes the state from the cache and the clock, applies the kill
    /// switch, notifies listeners and the built-in UI. Never throws.
    @discardableResult
    func reevaluate() -> LerixAppControlState {
        let date = now()
        let app = appInfo()
        let prefs = self.prefs
        lock.lock()
        let cache = self.cache
        let enabled = options.enabled
        lock.unlock()

        let evaluated = LerixAppControlEvaluator.evaluate(
            cache: cache, prefs: prefs, appVersion: app.version, build: app.build,
            sdkVersion: LerixSDK.version, now: date
        )
        // `enabled: false`: no update/maintenance, but a cached kill switch still applies.
        let newState = enabled ? evaluated : LerixAppControlState(update: nil, maintenance: nil, sdk: evaluated.sdk)

        // Kill switch, in device time.
        let offset = (cache?.clockOffsetMs ?? 0) / 1000
        gate.set(modules: newState.sdk?.disabled ?? [], until: newState.sdk.map { $0.until.addingTimeInterval(-offset) })
        let nowBlocked = Set(LerixSdkModule.allCases.filter { gate.isBlocked($0) })

        lock.lock()
        let oldState = _state
        _state = newState
        let lifted = blockedModules.subtracting(nowBlocked)
        blockedModules = nowBlocked
        let changeHandlers = oldState != newState ? [_onChange].compactMap { $0 } + Array(listeners.values) : []
        lock.unlock()

        if let maintenance = newState.maintenance { trackMaintenanceShown(maintenance) }
        if let next = LerixAppControlEvaluator.nextTransition(cache: cache, prefs: prefs, now: date) {
            scheduleTransition(at: next, now: date)
        }
        updatePolling(ttl: cache?.config.ttlSeconds)

        if !lifted.isEmpty || !changeHandlers.isEmpty || usesBuiltInUI {
            onMain { [weak self] in
                guard let self = self else { return }
                if !lifted.isEmpty { self.onGateLifted(lifted) }
                for handler in changeHandlers { handler(newState) }
                self.presenter?.render(self.state)
            }
        }
        return newState
    }

    // MARK: - Session-scoped prompts and events

    private var sessionKey: String { sessionIdProvider() ?? processSession }

    /// Whether the soft update dialog may be shown now (once per app session).
    func canShowSoftPrompt() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return softPromptSession != sessionKey
    }

    /// Records that an update UI was shown (`$update_prompt_shown`).
    func updatePromptShown(_ update: LerixAppUpdate) {
        if update.state != .required {
            lock.lock(); softPromptSession = sessionKey; lock.unlock()
        }
        var props: [String: Any] = ["state": update.state.rawValue]
        props["reason"] = update.reason?.rawValue ?? NSNull()
        props["ruleId"] = update.ruleId ?? NSNull()
        props["latestVersion"] = update.latestVersion ?? NSNull()
        track("$update_prompt_shown", props)
    }

    private func trackMaintenanceShown(_ maintenance: LerixMaintenance) {
        let key = sessionKey
        lock.lock()
        let already = maintenanceShown[maintenance.id] == key
        maintenanceShown[maintenance.id] = key
        lock.unlock()
        if !already { track("$maintenance_shown", ["maintenanceId": maintenance.id]) }
    }

    private func trackAction(_ action: String, _ update: LerixAppUpdate) {
        track("$update_prompt_action", [
            "action": action,
            "state": update.state.rawValue,
            "ruleId": update.ruleId ?? NSNull(),
        ])
    }

    private func track(_ name: String, _ props: [String: Any]) {
        guard isEnabled else { return }
        tracker(name, props)
    }

    // MARK: - Timers and lifecycle

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Re-evaluates at the next time-based change (maintenance start/end,
    /// kill-switch expiry), with no network needed.
    private func scheduleTransition(at date: Date, now: Date) {
        guard schedulesTimers else { return }
        let delay = min(max(date.timeIntervalSince(now) + 0.5, 0.5), 86_400)
        let work = DispatchWorkItem { [weak self] in self?.reevaluate() }
        lock.lock()
        transitionWork?.cancel()
        transitionWork = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// While in the foreground with `ttlSeconds ≤ 60`, fetch every `ttlSeconds`.
    private func updatePolling(ttl: TimeInterval?) {
        guard schedulesTimers else { return }
        lock.lock()
        let wanted: TimeInterval? = (options.enabled && inForeground && (ttl ?? .infinity) <= 60) ? ttl : nil
        guard wanted != pollInterval else { lock.unlock(); return }
        pollTimer?.cancel()
        pollTimer = nil
        pollInterval = wanted
        if let interval = wanted {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in
                Task { [weak self] in _ = await self?.fetch() }
            }
            pollTimer = timer
            timer.resume()
        }
        lock.unlock()
    }

    func handleForeground() {
        lock.lock()
        inForeground = true
        let last = cache?.fetchedAt
        let ttl = cache?.config.ttlSeconds ?? LerixAppConfig.defaultTTL
        lock.unlock()
        reevaluate()
        if last.map({ now().timeIntervalSince($0) >= ttl }) ?? true {
            Task { [weak self] in _ = await self?.fetch() }
        }
    }

    func handleBackground() {
        lock.lock()
        inForeground = false
        pollTimer?.cancel()
        pollTimer = nil
        pollInterval = nil
        lock.unlock()
    }

    private func observeLifecycle() {
        guard observers.isEmpty else { return }
        inForeground = !LerixLifecycle.isInBackground
        let center = NotificationCenter.default
        #if canImport(UIKit)
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleForeground()
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleBackground()
        })
        #elseif canImport(AppKit)
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleForeground()
        })
        observers.append(center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleBackground()
        })
        observers.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleForeground()
        })
        #endif
    }

    static func openURL(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

/// The silent `config_refresh` push (contract §2.1): APNs
/// `{aps:{content-available:1}, data:{action:"config_refresh"}}`; a top-level
/// `action` is accepted too.
enum LerixAppControlPush {
    static let action = "config_refresh"

    static func isConfigRefresh(_ userInfo: [AnyHashable: Any]) -> Bool {
        if let data = userInfo["data"] as? [AnyHashable: Any], data["action"] as? String == action { return true }
        if let raw = userInfo["data"] as? String, let bytes = raw.data(using: .utf8),
           let data = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
           data["action"] as? String == action { return true }
        return userInfo["action"] as? String == action
    }
}
