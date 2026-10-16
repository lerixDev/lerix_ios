import XCTest
@testable import Lerix

final class LerixEventValidatorTests: XCTestCase {
    func testNames() {
        XCTAssertTrue(LerixEventValidator.isValidName("checkout_started", allowReserved: false))
        XCTAssertTrue(LerixEventValidator.isValidName("Checkout: step 2.b-x", allowReserved: false))
        XCTAssertFalse(LerixEventValidator.isValidName("a", allowReserved: false), "needs 2+ characters")
        XCTAssertFalse(LerixEventValidator.isValidName("1st", allowReserved: false))
        XCTAssertFalse(LerixEventValidator.isValidName("", allowReserved: false))
        XCTAssertFalse(LerixEventValidator.isValidName(String(repeating: "a", count: 65), allowReserved: false))
        XCTAssertTrue(LerixEventValidator.isValidName(String(repeating: "a", count: 64), allowReserved: false))
        XCTAssertFalse(LerixEventValidator.isValidName("emoji🙂", allowReserved: false))
    }

    func testReservedNamesOnlyForTheSdk() {
        XCTAssertFalse(LerixEventValidator.isValidName("$screen_view", allowReserved: false))
        XCTAssertTrue(LerixEventValidator.isValidName("$screen_view", allowReserved: true))
        XCTAssertFalse(LerixEventValidator.isValidName("$custom", allowReserved: true))
    }

    func testPropsSanitising() {
        let (props, dropped) = LerixEventValidator.sanitize([
            "items": 3,
            "price": 9.5,
            "coupon": "EID",
            "gift": true,
            "note": nil as String? as Any,
            "bad key": 1,
            "1bad": 1,
            "date": Date(),
            "nested": ["a": 1],
            "nan": Double.nan,
            "long": String(repeating: "x", count: 2000),
        ])
        XCTAssertEqual(props["items"], .number(3))
        XCTAssertEqual(props["price"], .number(9.5))
        XCTAssertEqual(props["coupon"], .string("EID"))
        XCTAssertEqual(props["gift"], .bool(true))
        XCTAssertEqual(props["note"], .null)
        XCTAssertEqual(props["long"]?.stringValue?.count, 1024)
        XCTAssertEqual(Set(dropped), ["bad key", "1bad", "date", "nested", "nan"])
    }

    func testAtMost25Props() {
        var input: [String: Any] = [:]
        for i in 0..<30 { input[String(format: "k%02d", i)] = i }
        let (props, dropped) = LerixEventValidator.sanitize(input)
        XCTAssertEqual(props.count, 25)
        XCTAssertEqual(dropped.count, 5)
        XCTAssertNotNil(props["k00"])
        XCTAssertNil(props["k29"])
    }

    func testBoolIsNotANumber() {
        XCTAssertEqual(LerixEventValidator.sanitizeValue(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(LerixEventValidator.sanitizeValue(NSNumber(value: 1)), .number(1))
    }
}

final class LerixSessionTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private var counter = 0

    private func tracker(_ state: LerixSessionState? = nil) -> LerixSessionTracker {
        var tracker = LerixSessionTracker(state: state)
        tracker.makeId = { [unowned self] in
            self.counter += 1
            return "session-\(self.counter)"
        }
        return tracker
    }

    func testColdStartStartsSession() {
        var t = tracker()
        let events = t.coldStart(now: t0)
        XCTAssertEqual(events.map(\.name), ["$session_start"])
        XCTAssertEqual(events[0].props["coldStart"], .bool(true))
        XCTAssertEqual(t.state?.id, "session-1")
    }

    func testBackgroundSendsEndWithForegroundDuration() {
        var t = tracker()
        _ = t.coldStart(now: t0)
        let events = t.background(now: t0.addingTimeInterval(120))
        XCTAssertEqual(events.map(\.name), ["$session_end"])
        XCTAssertEqual(events[0].props["duration"], .number(120))
        XCTAssertEqual(events[0].eventId, "end_session-1")
        XCTAssertTrue(LerixIds.isValid(events[0].eventId!))
    }

    func testShortBackgroundKeepsSession() {
        var t = tracker()
        _ = t.coldStart(now: t0)
        _ = t.background(now: t0.addingTimeInterval(60))
        XCTAssertTrue(t.foreground(now: t0.addingTimeInterval(60 + 29 * 60)).isEmpty)
        XCTAssertEqual(t.state?.id, "session-1")
        // Duration accumulates foreground time only; the repeat end reuses the id.
        let end = t.background(now: t0.addingTimeInterval(60 + 29 * 60 + 30))
        XCTAssertEqual(end.first?.props["duration"], .number(90))
        XCTAssertEqual(end.first?.eventId, "end_session-1")
    }

    func testLongBackgroundRollsOver() {
        var t = tracker()
        _ = t.coldStart(now: t0)
        _ = t.background(now: t0.addingTimeInterval(60))
        let events = t.foreground(now: t0.addingTimeInterval(60 + 30 * 60))
        XCTAssertEqual(events.map(\.name), ["$session_start"])
        XCTAssertEqual(events[0].props["coldStart"], .bool(false))
        XCTAssertEqual(t.state?.id, "session-2")
    }

    func testColdStartWithinWindowResumesAcrossProcesses() {
        var first = tracker()
        _ = first.coldStart(now: t0)
        _ = first.background(now: t0.addingTimeInterval(60))
        var second = tracker(first.state)
        XCTAssertTrue(second.coldStart(now: t0.addingTimeInterval(10 * 60)).isEmpty)
        XCTAssertEqual(second.state?.id, "session-1")
    }

    func testColdStartAfterWindowStartsNew() {
        var first = tracker()
        _ = first.coldStart(now: t0)
        _ = first.background(now: t0.addingTimeInterval(60))
        var second = tracker(first.state)
        let events = second.coldStart(now: t0.addingTimeInterval(60 + 31 * 60))
        // The end was already sent on backgrounding.
        XCTAssertEqual(events.map(\.name), ["$session_start"])
        XCTAssertEqual(second.state?.id, "session-2")
    }

    func testKilledInForegroundEndIsDetectedOnNextStart() {
        var first = tracker()
        _ = first.coldStart(now: t0)
        first.heartbeat(now: t0.addingTimeInterval(300))
        var second = tracker(first.state)
        let events = second.coldStart(now: t0.addingTimeInterval(400))
        XCTAssertEqual(events.map(\.name), ["$session_end", "$session_start"])
        XCTAssertEqual(events[0].sessionId, "session-1")
        XCTAssertEqual(events[0].props["duration"], .number(300))
        XCTAssertEqual(events[0].date, t0.addingTimeInterval(300))
        XCTAssertEqual(events[1].sessionId, "session-2")
    }
}

final class LerixEnvironmentTests: XCTestCase {
    func testResolve() {
        XCTAssertEqual(LerixEnvironment.resolve("staging"), "staging")
        XCTAssertEqual(LerixEnvironment.resolve("  QA_1 "), "qa_1")
        XCTAssertEqual(LerixEnvironment.resolve("x"), LerixEnvironment.autoDetected, "too short")
        XCTAssertEqual(LerixEnvironment.resolve(nil), LerixEnvironment.autoDetected)
        #if DEBUG
        XCTAssertEqual(LerixEnvironment.autoDetected, "dev")
        #endif
    }

    func testClientIds() {
        XCTAssertTrue(LerixIds.isValid(LerixIds.make()))
        XCTAssertTrue(LerixIds.isValid("V1StGXR8_Z5jdHi6B-myT"))
        XCTAssertFalse(LerixIds.isValid("short"))
        XCTAssertFalse(LerixIds.isValid("has space in it"))
    }
}

final class LerixBreadcrumbTests: XCTestCase {
    func testRingBufferKeepsNewest50() {
        let crumbs = LerixBreadcrumbs()
        for i in 0..<60 { crumbs.add("crumb \(i)", category: .log) }
        let snapshot = crumbs.snapshot()
        XCTAssertEqual(snapshot.count, 50)
        XCTAssertEqual(snapshot.first?["message"] as? String, "crumb 10")
        XCTAssertEqual(snapshot.last?["message"] as? String, "crumb 59")
        XCTAssertEqual(snapshot.last?["category"] as? String, "log")
    }

    func testNonJsonDataIsDropped() {
        let crumbs = LerixBreadcrumbs()
        crumbs.add("ok", data: ["a": 1])
        crumbs.add("bad", data: ["d": Date()])
        let snapshot = crumbs.snapshot()
        XCTAssertNotNil(snapshot[0]["data"])
        XCTAssertNil(snapshot[1]["data"])
    }
}

final class LerixFirstOpenTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lerix-first-open-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func startAnalytics(preexisting: Bool) -> (LerixAnalytics, LerixOutbox, LerixStore) {
        let store = LerixStore(url: root.appendingPathComponent("state.json"))
        let outbox = LerixOutbox(
            directory: root.appendingPathComponent("outbox"),
            attachmentsDirectory: root.appendingPathComponent("attachments"),
            store: store,
            transport: FakeTransport()
        )
        let analytics = LerixAnalytics(store: store, outbox: outbox)
        analytics.hasPreexistingInstall = { preexisting }
        analytics.start(options: LerixAnalyticsOptions())
        return (analytics, outbox, store)
    }

    private func names(_ outbox: LerixOutbox) -> [String] {
        outbox.items(of: .event).compactMap { $0.payload["name"]?.stringValue }
    }

    func testNewInstallSendsFirstOpen() {
        let (_, outbox, store) = startAnalytics(preexisting: false)
        XCTAssertTrue(names(outbox).contains("$first_open"))
        XCTAssertNotNil(store.date(LerixStoreKey.firstStartAt))
    }

    func testUpgradedInstallWritesMarkerSilently() {
        let (_, outbox, store) = startAnalytics(preexisting: true)
        XCTAssertFalse(names(outbox).contains("$first_open"))
        XCTAssertTrue(names(outbox).contains("$session_start"))
        XCTAssertNotNil(store.date(LerixStoreKey.firstStartAt), "marker written so it never fires later")
    }
}
