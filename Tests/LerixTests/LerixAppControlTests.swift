import XCTest
@testable import Lerix

/// Replays scripted app-config responses and records each request.
final class AppConfigTransport: LerixTransport {
    struct Request {
        let path: String
        let headers: [String: String]
        let query: [String: String]
    }

    private let lock = NSLock()
    private var scripted: [LerixHTTPResponse] = []
    private var _requests: [Request] = []
    var fallback = LerixHTTPResponse.network

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }

    func enqueue(_ responses: LerixHTTPResponse...) {
        lock.lock(); scripted.append(contentsOf: responses); lock.unlock()
    }

    func send(route: LerixRoute, headers: [String: String], query: [URLQueryItem], body: Data?, contentType: String?) async -> LerixHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        var q: [String: String] = [:]
        for item in query { q[item.name] = item.value }
        _requests.append(Request(path: route.path, headers: headers, query: q))
        return scripted.isEmpty ? fallback : scripted.removeFirst()
    }
}

private let t0 = Date(timeIntervalSince1970: 1_790_000_000) // fixed "server now"

private func iso(_ date: Date) -> String { LerixTime.iso(date) }

private func updateJSON(_ state: String, latest: String = "3.4.0", allowSkip: Bool = true, remind: Int = 72) -> [String: Any] {
    [
        "state": state, "reason": state == "required" ? "below_minimum" : "outdated", "ruleId": "rule-1",
        "latestVersion": latest, "minVersion": "3.0.0", "storeUrl": "https://apps.apple.com/app/id123",
        "title": "New version", "message": "Please update", "releaseNotes": "Fixes",
        "remindAfterHours": remind, "allowSkip": allowSkip, "requiredAt": NSNull(),
    ]
}

private func maintenanceJSON(starts: Date, ends: Date) -> [String: Any] {
    ["id": "mw-1", "title": "Down", "message": "Back soon", "imageUrl": NSNull(),
     "startsAt": iso(starts), "endsAt": iso(ends), "showEndsAt": true]
}

private func body(update: [String: Any]? = nil, maintenance: [String: Any]? = nil, sdk: [String: Any]? = nil,
                  serverTime: Date = t0, ttl: Int = 3600, etag: String = "\"e1\"") -> [String: Any] {
    ["v": 1, "etag": etag, "serverTime": iso(serverTime), "ttlSeconds": ttl,
     "update": update ?? NSNull(), "maintenance": maintenance ?? NSNull(), "sdk": sdk ?? NSNull()]
}

private func cache(_ json: [String: Any], fetchedAt: Date = t0, offsetMs: Double = 0,
                   appVersion: String? = "3.0.0", build: String? = "30") -> LerixAppConfigCache {
    LerixAppConfigCache(body: LerixJSON(any: json)!, etag: json["etag"] as? String, fetchedAt: fetchedAt,
                        clockOffsetMs: offsetMs, appVersion: appVersion, build: build, sdkVersion: LerixSDK.version)
}

private func evaluate(_ cache: LerixAppConfigCache?, prefs: LerixUpdatePrefs = LerixUpdatePrefs(), now: Date,
                      appVersion: String? = "3.0.0", build: String? = "30") -> LerixAppControlState {
    LerixAppControlEvaluator.evaluate(cache: cache, prefs: prefs, appVersion: appVersion, build: build,
                                      sdkVersion: LerixSDK.version, now: now)
}

// MARK: - Parsing

final class LerixAppConfigParsingTests: XCTestCase {
    func testFullBody() {
        let config = LerixAppConfig(json: body(
            update: updateJSON("recommended"),
            maintenance: maintenanceJSON(starts: t0, ends: t0.addingTimeInterval(3600)),
            sdk: ["disabled": ["analytics", "push"], "until": iso(t0.addingTimeInterval(60))]
        ))
        XCTAssertEqual(config.ttlSeconds, 3600)
        XCTAssertEqual(config.etag, "\"e1\"")
        XCTAssertEqual(config.serverTime, t0)
        XCTAssertEqual(config.update?.state, .recommended)
        XCTAssertEqual(config.update?.reason, .outdated)
        XCTAssertEqual(config.update?.storeUrl?.absoluteString, "https://apps.apple.com/app/id123")
        XCTAssertEqual(config.update?.allowSkip, false, "recommended is never skippable")
        XCTAssertEqual(config.maintenance?.id, "mw-1")
        XCTAssertEqual(config.sdk?.disabled, ["analytics", "push"])
    }

    func testUnknownFieldsAndEnumsAreIgnoredPartwise() {
        var update = updateJSON("available")
        update["reason"] = "brand_new_reason"
        update["futureField"] = ["x": 1]
        var json = body(update: update)
        json["banner"] = ["text": "E1 is out of scope"]
        json["flags"] = [1, 2, 3]
        let config = LerixAppConfig(json: json)
        XCTAssertEqual(config.update?.state, .available)
        XCTAssertNil(config.update?.reason, "an unknown reason is absent, the update stays")

        var unknownState = updateJSON("mandatory")
        unknownState["state"] = "mandatory"
        XCTAssertNil(LerixAppConfig(json: body(update: unknownState)).update, "unknown state → no update")
    }

    func testWrongTypesFallBack() {
        var update = updateJSON("required")
        update["title"] = 42
        update["message"] = ["en": "x"]
        update["remindAfterHours"] = "soon"
        update["storeUrl"] = "javascript:alert(1)"
        update["requiredAt"] = "not a date"
        var json = body(update: update)
        json["ttlSeconds"] = "60"
        json["serverTime"] = 123
        json["maintenance"] = "yes"
        json["sdk"] = ["disabled": "all", "until": iso(t0)]
        let config = LerixAppConfig(json: json)
        XCTAssertEqual(config.ttlSeconds, LerixAppConfig.defaultTTL)
        XCTAssertNil(config.serverTime)
        XCTAssertNil(config.maintenance)
        XCTAssertNil(config.sdk, "disabled must be an array")
        XCTAssertEqual(config.update?.title, "Update required", "built-in default copy")
        XCTAssertEqual(config.update?.message, "This version is no longer supported. Please update to continue.")
        XCTAssertEqual(config.update?.remindAfterHours, 72)
        XCTAssertNil(config.update?.storeUrl)
        XCTAssertNil(config.update?.requiredAt)
    }

    func testMaintenanceNeedsIdAndValidWindow() {
        var missingEnd = maintenanceJSON(starts: t0, ends: t0.addingTimeInterval(60))
        missingEnd["endsAt"] = NSNull()
        XCTAssertNil(LerixAppConfig(json: body(maintenance: missingEnd)).maintenance)
        let inverted = maintenanceJSON(starts: t0, ends: t0.addingTimeInterval(-60))
        XCTAssertNil(LerixAppConfig(json: body(maintenance: inverted)).maintenance)
        var noCopy = maintenanceJSON(starts: t0, ends: t0.addingTimeInterval(60))
        noCopy["title"] = ""
        noCopy["showEndsAt"] = "true"
        let parsed = LerixAppConfig(json: body(maintenance: noCopy)).maintenance
        XCTAssertEqual(parsed?.title, "We'll be right back")
        XCTAssertEqual(parsed?.showEndsAt, true)
    }

    func testSdkModulesFiltered() {
        let sdk = LerixAppConfig.parseSdk(["disabled": ["all", "core", "rockets", 7, "all"], "until": iso(t0)])
        XCTAssertEqual(sdk?.disabled, ["all"])
        XCTAssertNil(LerixAppConfig.parseSdk(["disabled": ["rockets"], "until": iso(t0)]))
        XCTAssertNil(LerixAppConfig.parseSdk(["disabled": ["all"]]), "no until → absent")
    }

    func testFractionalDatesAndClampedTTL() {
        var json = body()
        json["serverTime"] = "2026-10-23T10:00:00.250Z"
        json["ttlSeconds"] = 1
        let config = LerixAppConfig(json: json)
        XCTAssertNotNil(config.serverTime)
        XCTAssertEqual(config.ttlSeconds, 10)
    }

    func testConfigRefreshPush() {
        XCTAssertTrue(LerixAppControlPush.isConfigRefresh(["aps": ["content-available": 1], "data": ["action": "config_refresh"]]))
        XCTAssertTrue(LerixAppControlPush.isConfigRefresh(["action": "config_refresh"]))
        XCTAssertTrue(LerixAppControlPush.isConfigRefresh(["data": "{\"action\":\"config_refresh\"}"]))
        XCTAssertFalse(LerixAppControlPush.isConfigRefresh(["data": ["action": "remove", "notificationId": "n1"]]))
        XCTAssertFalse(LerixAppControlPush.isConfigRefresh(["aps": ["alert": "hi"]]))
        // The removal parser is untouched by config_refresh.
        XCTAssertNil(LerixNotifications.removalNotificationId(from: ["data": ["action": "config_refresh"]]))
    }

    func testCacheRoundTrip() {
        let original = cache(body(update: updateJSON("required")), offsetMs: -1234)
        let restored = LerixAppConfigCache(json: original.json)
        XCTAssertEqual(restored, original)
        XCTAssertNil(LerixAppConfigCache(json: .string("garbage")))
        XCTAssertNil(LerixAppConfigCache(json: .object(["body": .string("x"), "fetchedAt": .number(1)])))
    }
}

// MARK: - Offline table (§2.2) and precedence (§2.3)

final class LerixAppControlEvaluatorTests: XCTestCase {
    func testRequiredKeepsBlockingFromAnyAgeCache() {
        let c = cache(body(update: updateJSON("required")))
        XCTAssertEqual(evaluate(c, now: t0.addingTimeInterval(90 * 86_400)).update?.state, .required)
    }

    func testSoftUpdateDroppedAfterSevenDays() {
        let c = cache(body(update: updateJSON("available")))
        XCTAssertEqual(evaluate(c, now: t0.addingTimeInterval(6 * 86_400)).update?.state, .available)
        XCTAssertNil(evaluate(c, now: t0.addingTimeInterval(7 * 86_400)).update)
    }

    func testUpdateIgnoredForAnotherAppVersion() {
        let c = cache(body(update: updateJSON("required")))
        XCTAssertNil(evaluate(c, now: t0, appVersion: "3.4.0", build: "34").update, "the user updated: the cached required state is void")
        XCTAssertNil(evaluate(c, now: t0, appVersion: "3.0.0", build: "31").update)
    }

    func testMaintenanceWindowWithClockOffset() {
        // Device clock is 1 h behind the server.
        let deviceAtFetch = t0.addingTimeInterval(-3600)
        let starts = t0.addingTimeInterval(600)
        let ends = t0.addingTimeInterval(1800)
        let c = cache(body(maintenance: maintenanceJSON(starts: starts, ends: ends)), fetchedAt: deviceAtFetch, offsetMs: 3_600_000)
        XCTAssertNil(evaluate(c, now: deviceAtFetch).maintenance, "scheduled, not started")
        XCTAssertEqual(evaluate(c, now: deviceAtFetch.addingTimeInterval(600)).maintenance?.id, "mw-1", "starts at server startsAt")
        XCTAssertEqual(evaluate(c, now: deviceAtFetch.addingTimeInterval(1799)).maintenance?.id, "mw-1")
        XCTAssertNil(evaluate(c, now: deviceAtFetch.addingTimeInterval(1800)).maintenance, "lifts at endsAt with no network")
        // Without the offset the device would still block for another hour.
        let naive = cache(body(maintenance: maintenanceJSON(starts: starts, ends: ends)), fetchedAt: deviceAtFetch, offsetMs: 0)
        XCTAssertNotNil(evaluate(naive, now: deviceAtFetch.addingTimeInterval(1800 + 3000)).maintenance)

        XCTAssertEqual(
            LerixAppControlEvaluator.nextTransition(cache: c, prefs: LerixUpdatePrefs(), now: deviceAtFetch),
            deviceAtFetch.addingTimeInterval(600)
        )
        XCTAssertEqual(
            LerixAppControlEvaluator.nextTransition(cache: c, prefs: LerixUpdatePrefs(), now: deviceAtFetch.addingTimeInterval(700)),
            deviceAtFetch.addingTimeInterval(1800)
        )
    }

    func testSdkKillLiftsAtUntil() {
        let c = cache(body(sdk: ["disabled": ["all"], "until": iso(t0.addingTimeInterval(300))]))
        XCTAssertEqual(evaluate(c, now: t0.addingTimeInterval(299)).sdk?.disabled, ["all"])
        XCTAssertNil(evaluate(c, now: t0.addingTimeInterval(300)).sdk)
    }

    func testRemindAndSkipFilters() {
        let available = cache(body(update: updateJSON("available")))
        let recommended = cache(body(update: updateJSON("recommended")))
        let required = cache(body(update: updateJSON("required")))
        let later = LerixUpdatePrefs(remindVersion: "3.4.0", remindUntil: t0.addingTimeInterval(3600), skippedVersion: nil)
        XCTAssertNil(evaluate(available, prefs: later, now: t0).update)
        XCTAssertNil(evaluate(recommended, prefs: later, now: t0).update)
        XCTAssertNotNil(evaluate(recommended, prefs: later, now: t0.addingTimeInterval(3600)).update, "remind expired")
        XCTAssertNotNil(evaluate(required, prefs: later, now: t0).update, "required ignores Later")

        let skipped = LerixUpdatePrefs(remindVersion: nil, remindUntil: nil, skippedVersion: "3.4.0")
        XCTAssertNil(evaluate(available, prefs: skipped, now: t0).update)
        XCTAssertNotNil(evaluate(recommended, prefs: skipped, now: t0).update, "recommended is never skippable")
        let newer = cache(body(update: updateJSON("available", latest: "3.5.0")))
        XCTAssertNotNil(evaluate(newer, prefs: skipped, now: t0).update, "a new latestVersion shows again")
    }

    func testPrecedence() {
        let both = cache(body(update: updateJSON("required"),
                              maintenance: maintenanceJSON(starts: t0, ends: t0.addingTimeInterval(60))))
        guard case .maintenance = evaluate(both, now: t0).screen else { return XCTFail("maintenance first") }
        guard case .requiredUpdate = evaluate(both, now: t0.addingTimeInterval(61)).screen else { return XCTFail("then required") }
        let soft = cache(body(update: updateJSON("recommended")))
        guard case .softUpdate = evaluate(soft, now: t0).screen else { return XCTFail("soft") }
        XCTAssertEqual(evaluate(nil, now: t0).screen, .none)
    }
}

// MARK: - LerixAppControl (fetch, 304, persistence, E6)

final class LerixAppControlTests: XCTestCase {
    private var dir: URL!
    private var transport: AppConfigTransport!
    private var events: [(String, [String: Any])] = []
    private var clock = t0

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lerix-appcontrol-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        transport = AppConfigTransport()
        events = []
        clock = t0
        LerixSdkGate.shared.clear()
        LerixSdkGate.shared.now = { [unowned self] in self.clock }
    }

    override func tearDown() {
        LerixSdkGate.shared.clear()
        LerixSdkGate.shared.now = { Date() }
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeControl(store: LerixStore? = nil, options: LerixAppControlOptions = LerixAppControlOptions(ui: false),
                             start: Bool = true) -> LerixAppControl {
        let control = LerixAppControl(store: store ?? LerixStore(url: dir.appendingPathComponent("state.json")), transport: transport)
        control.schedulesTimers = false
        control.fetchesOnStart = false
        control.now = { [unowned self] in self.clock }
        control.appInfo = { .init(version: "3.0.0", build: "30", bundleId: "dev.lerix.test") }
        control.userIdProvider = { nil }
        control.installIdProvider = { "install-1" }
        control.sessionIdProvider = { "session-1" }
        control.tracker = { [unowned self] name, props in self.events.append((name, props)) }
        control.urlOpener = { _ in }
        if start { control.start(options: options) }
        return control
    }

    private func ok(_ json: [String: Any], etag: String? = "\"e1\"") -> LerixHTTPResponse {
        LerixHTTPResponse(status: 200, json: json, etag: etag)
    }

    func testFetchSendsQueryAndAppliesState() async {
        transport.enqueue(ok(body(update: updateJSON("required"))))
        let control = makeControl(start: false)
        control.userIdProvider = { "user-9" }
        control.start(options: LerixAppControlOptions(ui: false))
        let state = await control.refresh()
        XCTAssertEqual(state.update?.state, .required)
        let request = transport.requests.first
        XCTAssertEqual(request?.path, "plugin/app-config")
        XCTAssertEqual(request?.headers["app-user"], "user-9")
        XCTAssertNil(request?.headers["If-None-Match"])
        XCTAssertEqual(request?.query["platform"], LerixAppControl.platform)
        XCTAssertEqual(request?.query["appVersion"], "3.0.0")
        XCTAssertEqual(request?.query["build"], "30")
        XCTAssertEqual(request?.query["appId"], "dev.lerix.test")
        XCTAssertEqual(request?.query["sdk"], LerixSDK.name)
        XCTAssertEqual(request?.query["sdkVersion"], LerixSDK.version)
        XCTAssertEqual(request?.query["installId"], "install-1")
        XCTAssertNotNil(request?.query["locale"])
        XCTAssertNotNil(request?.query["environment"])
        XCTAssertEqual(events.filter { $0.0 == "$config_applied" }.count, 1)
    }

    func testNotModifiedKeepsCacheAndRefreshesFetchedAt() async {
        transport.enqueue(ok(body(update: updateJSON("available"))))
        let control = makeControl()
        _ = await control.refresh()

        clock = t0.addingTimeInterval(6 * 86_400)
        transport.enqueue(LerixHTTPResponse(status: 304, json: nil, etag: "\"e1\""))
        let state = await control.refresh()
        XCTAssertEqual(transport.requests.last?.headers["If-None-Match"], "\"e1\"")
        XCTAssertEqual(state.update?.state, .available, "cache kept on 304")
        XCTAssertEqual(events.filter { $0.0 == "$config_applied" }.count, 1, "not on 304")

        // fetchedAt moved to the 304, so the 7-day soft expiry counts from it.
        clock = t0.addingTimeInterval(8 * 86_400)
        XCTAssertNotNil(control.reevaluate().update)
    }

    func testOfflineKeepsCacheAcrossLaunches() async {
        let store = LerixStore(url: dir.appendingPathComponent("state.json"))
        transport.enqueue(ok(body(update: updateJSON("required"),
                                  maintenance: maintenanceJSON(starts: t0, ends: t0.addingTimeInterval(600)))))
        let first = makeControl(store: store)
        _ = await first.refresh()

        // Next launch, offline: the persisted state applies before (and without) the network.
        clock = t0.addingTimeInterval(60)
        let second = makeControl(store: LerixStore(url: dir.appendingPathComponent("state.json")), start: false)
        second.start(options: LerixAppControlOptions(ui: false))
        XCTAssertEqual(second.state.maintenance?.id, "mw-1")
        let afterFailedFetch = await second.refresh()
        XCTAssertEqual(afterFailedFetch.maintenance?.id, "mw-1")
        XCTAssertEqual(afterFailedFetch.update?.state, .required)

        clock = t0.addingTimeInterval(600)
        let lifted = second.reevaluate()
        XCTAssertNil(lifted.maintenance, "lifts at endsAt offline")
        XCTAssertEqual(lifted.update?.state, .required, "required stays until a fetch says otherwise")

        transport.enqueue(ok(body(), etag: "\"e2\""))
        let cleared = await second.refresh()
        XCTAssertNil(cleared.update)
    }

    func testLaterAndSkipPersist() async {
        transport.enqueue(ok(body(update: updateJSON("available", remind: 24))))
        let control = makeControl()
        _ = await control.refresh()
        control.later()
        XCTAssertNil(control.state.update)
        XCTAssertEqual(events.last?.0, "$update_prompt_action")
        XCTAssertEqual(events.last?.1["action"] as? String, "later")

        // A new launch still respects "Later"…
        let relaunch = makeControl()
        XCTAssertNil(relaunch.state.update)
        // …until remindAfterHours has passed.
        clock = t0.addingTimeInterval(24 * 3600)
        XCTAssertNotNil(relaunch.reevaluate().update)

        relaunch.skip()
        XCTAssertNil(relaunch.state.update)
        clock = t0.addingTimeInterval(5 * 86_400)
        XCTAssertNil(makeControl().state.update, "skipped version stays hidden")

        transport.enqueue(ok(body(update: updateJSON("available", latest: "3.5.0")), etag: "\"e3\""))
        let newer = await relaunch.refresh()
        XCTAssertEqual(newer.update?.latestVersion, "3.5.0")
    }

    func testSkipAndLaterIgnoredWhenNotAllowed() async {
        transport.enqueue(ok(body(update: updateJSON("required"))))
        let control = makeControl()
        _ = await control.refresh()
        control.later()
        control.skip()
        XCTAssertEqual(control.state.update?.state, .required)
        XCTAssertTrue(control.openStore())
        XCTAssertEqual(events.last?.1["action"] as? String, "update")
    }

    func testOnChangeAndListeners() async {
        let control = makeControl()
        let changed = expectation(description: "onChange")
        let listened = expectation(description: "listener")
        control.onChange = { state in if state.update != nil { changed.fulfill() } }
        let token = control.addListener { state in if state.update != nil { listened.fulfill() } }
        transport.enqueue(ok(body(update: updateJSON("recommended"))))
        _ = await control.refresh()
        await fulfillment(of: [changed, listened], timeout: 2)
        control.removeListener(token)
    }

    func testDisabledOptionDoesNotFetchButKeepsKillSwitch() async {
        let store = LerixStore(url: dir.appendingPathComponent("state.json"))
        transport.enqueue(ok(body(update: updateJSON("required"),
                                  sdk: ["disabled": ["analytics"], "until": iso(t0.addingTimeInterval(600))])))
        _ = await makeControl(store: store).refresh()
        LerixSdkGate.shared.clear()
        let before = transport.requests.count

        let disabled = makeControl(store: LerixStore(url: dir.appendingPathComponent("state.json")),
                                   options: LerixAppControlOptions(enabled: false))
        let state = await disabled.refresh()
        XCTAssertEqual(transport.requests.count, before, "no fetch")
        XCTAssertNil(state.update)
        XCTAssertEqual(state.sdk?.disabled, ["analytics"])
        XCTAssertTrue(LerixSdkGate.shared.isBlocked(.analytics))
    }

    // MARK: E6

    func testKillAllBlocksEveryPathExceptAppConfig() async throws {
        transport.enqueue(ok(body(sdk: ["disabled": ["all"], "until": iso(t0.addingTimeInterval(600))])))
        let control = makeControl()
        var lifted: Set<LerixSdkModule> = []
        let liftedExpectation = expectation(description: "lifted")
        control.onGateLifted = { lifted = $0; liftedExpectation.fulfill() }
        _ = await control.refresh()

        let gate = LerixSdkGate.shared
        for path in ["plugin/init/ping", "plugin/init/register-user", "plugin/init/identify", "plugin/init/logout",
                     "plugin/bugs/create", "plugin/events", "plugin/feedback", "plugin/feedback/attachments",
                     "plugin/feedback/config", "plugin/surveys/config", "plugin/surveys/responses",
                     "plugin/notifications/register-token", "plugin/notifications/subscribe-topic"] {
            XCTAssertNotNil(gate.blockedUntil(path: path), path)
        }
        XCTAssertNil(gate.blockedUntil(path: LerixRoute.appConfig.path), "app-config is never blocked")

        // The throwing client stops before the network.
        do {
            _ = try await LerixBackend.post(route: .registerUser, data: [:])
            XCTFail("should throw")
        } catch LerixApiError.server(let code, _) {
            XCTAssertEqual(code, "SDK_DISABLED")
        }
        // The outbox keeps its items and sends nothing.
        let outboxTransport = FakeTransport()
        let outbox = LerixOutbox(directory: dir.appendingPathComponent("outbox"),
                                 attachmentsDirectory: dir.appendingPathComponent("att"),
                                 store: LerixStore(url: dir.appendingPathComponent("outbox-state.json")),
                                 transport: outboxTransport)
        outbox.now = { [unowned self] in self.clock }
        outbox.userIdProvider = { "user-1" }
        outbox.enqueue(LerixOutboxItem(kind: .event, payload: .object(["name": .string("x")])))
        await outbox.drain(.analytics)
        XCTAssertTrue(outboxTransport.requests.isEmpty)
        XCTAssertEqual(outbox.count(of: .event), 1, "queued items stay")
        XCTAssertNotNil(outbox.disabledUntil(.analytics))

        // Lifts at `until` with no network…
        clock = t0.addingTimeInterval(600)
        control.reevaluate()
        await fulfillment(of: [liftedExpectation], timeout: 2)
        XCTAssertTrue(lifted.contains(.core) && lifted.contains(.analytics))
        XCTAssertNil(gate.blockedUntil(path: "plugin/init/ping"))
        // …and the queue is delivered.
        await outbox.drain(.analytics)
        XCTAssertEqual(outboxTransport.requests.map(\.path), ["plugin/events"])
        XCTAssertEqual(outbox.count(of: .event), 0)
    }

    func testKillPerModule() async {
        transport.enqueue(ok(body(sdk: ["disabled": ["errors", "push", "tracing"], "until": iso(t0.addingTimeInterval(600))])))
        let control = makeControl()
        _ = await control.refresh()
        let gate = LerixSdkGate.shared
        XCTAssertTrue(gate.isBlocked(.errors))
        XCTAssertTrue(gate.isBlocked(.push))
        XCTAssertFalse(gate.isBlocked(.core))
        XCTAssertFalse(gate.isBlocked(.analytics))
        XCTAssertNil(gate.blockedUntil(path: "plugin/init/register-user"))
        XCTAssertNotNil(gate.blockedUntil(path: "plugin/bugs/create"))
        XCTAssertNotNil(gate.blockedUntil(path: "plugin/notifications/register-token"))

        // A later fetch without `sdk` lifts it early.
        transport.enqueue(ok(body(), etag: "\"e9\""))
        _ = await control.refresh()
        XCTAssertFalse(gate.isBlocked(.errors))
    }

    func testMaintenanceShownTrackedOncePerSession() async {
        transport.enqueue(ok(body(maintenance: maintenanceJSON(starts: t0, ends: t0.addingTimeInterval(600)), ttl: 60)))
        let control = makeControl()
        _ = await control.refresh()
        control.reevaluate()
        control.reevaluate()
        XCTAssertEqual(events.filter { $0.0 == "$maintenance_shown" }.count, 1)
        XCTAssertEqual(events.first { $0.0 == "$maintenance_shown" }?.1["maintenanceId"] as? String, "mw-1")
    }

    func testSoftPromptOncePerSession() async {
        transport.enqueue(ok(body(update: updateJSON("available"))))
        let control = makeControl()
        _ = await control.refresh()
        XCTAssertTrue(control.canShowSoftPrompt())
        control.updatePromptShown(control.state.update!)
        XCTAssertFalse(control.canShowSoftPrompt())
        XCTAssertEqual(events.last?.0, "$update_prompt_shown")
        XCTAssertEqual(events.last?.1["state"] as? String, "available")
        control.sessionIdProvider = { "session-2" }
        XCTAssertTrue(control.canShowSoftPrompt(), "a new app session may show it again")
    }

    func testGatewayErrorEnvelopeKeepsCache() async {
        transport.enqueue(ok(body(update: updateJSON("required"))))
        let control = makeControl()
        _ = await control.refresh()
        transport.enqueue(LerixHTTPResponse(status: 200, json: ["error": "PROJECT_NOT_FOUND", "statusCode": 400]))
        let state = await control.refresh()
        XCTAssertEqual(state.update?.state, .required)
    }
}
