import XCTest
@testable import Lerix

final class LerixErrorFilterTests: XCTestCase {
    override func tearDown() {
        let keys = LerixKeys.shared
        keys.ignoreErrors = []
        keys.ignoreErrorPatterns = []
        keys.beforeSend = nil
        super.tearDown()
    }

    private func event(_ message: String) -> LerixErrorEvent {
        LerixErrorEvent(message: message, stack: ["frame0"], type: .runtimeError, severity: .medium)
    }

    func testNoFiltersSendsEventUnchanged() {
        let result = LerixErrorFilter.apply(event("boom"), ignoreErrors: [], ignoreErrorPatterns: [], beforeSend: nil)
        XCTAssertEqual(result?.message, "boom")
        XCTAssertEqual(result?.stack, ["frame0"])
    }

    func testIgnoreErrorsIsCaseInsensitiveSubstring() {
        let ignore = ["network connection was LOST"]
        XCTAssertNil(LerixErrorFilter.apply(
            event("Error: The network connection was lost."), ignoreErrors: ignore, ignoreErrorPatterns: [], beforeSend: nil))
        XCTAssertNotNil(LerixErrorFilter.apply(
            event("Timed out"), ignoreErrors: ignore, ignoreErrorPatterns: [], beforeSend: nil))
    }

    func testEmptyIgnoreEntryDoesNotDropEverything() {
        XCTAssertNotNil(LerixErrorFilter.apply(event("boom"), ignoreErrors: [""], ignoreErrorPatterns: [], beforeSend: nil))
    }

    func testIgnoreErrorPatternsMatchAnywhere() throws {
        let pattern = try NSRegularExpression(pattern: "^NSURLErrorDomain -\\d+")
        XCTAssertNil(LerixErrorFilter.apply(
            event("NSURLErrorDomain -1009 offline"), ignoreErrors: [], ignoreErrorPatterns: [pattern], beforeSend: nil))
        XCTAssertNotNil(LerixErrorFilter.apply(
            event("Other NSURLErrorDomain -1009"), ignoreErrors: [], ignoreErrorPatterns: [pattern], beforeSend: nil))
    }

    func testBeforeSendCanModify() {
        let result = LerixErrorFilter.apply(event("token=abc123"), ignoreErrors: [], ignoreErrorPatterns: []) { e in
            var e = e
            e.message = "token=[redacted]"
            e.severity = .low
            e.metadata = ["scrubbed": true]
            return e
        }
        XCTAssertEqual(result?.message, "token=[redacted]")
        XCTAssertEqual(result?.severity, .low)
        XCTAssertEqual(result?.metadata?["scrubbed"] as? Bool, true)
    }

    func testBeforeSendCanDrop() {
        XCTAssertNil(LerixErrorFilter.apply(event("boom"), ignoreErrors: [], ignoreErrorPatterns: []) { _ in nil })
    }

    func testIgnoreListsRunBeforeBeforeSend() {
        var called = false
        let result = LerixErrorFilter.apply(event("ignored thing"), ignoreErrors: ["IGNORED"], ignoreErrorPatterns: []) { e in
            called = true
            return e
        }
        XCTAssertNil(result)
        XCTAssertFalse(called, "beforeSend must not run for an error already dropped by the ignore lists")
    }

    /// The manual `Lerix.throwError` path goes through `ErrorsHandler.throwError`;
    /// a dropped event returns before any network call.
    func testErrorsHandlerAppliesFilter() async {
        var seen: [String] = []
        LerixKeys.shared.beforeSend = { e in
            seen.append(e.message)
            return nil
        }
        await ErrorsHandler.throwError(issue: "manual", stack: [], type: .runtimeError, severity: .high)
        XCTAssertEqual(seen, ["manual"])

        LerixKeys.shared.beforeSend = { _ in
            XCTFail("beforeSend should not run for ignored errors")
            return nil
        }
        LerixKeys.shared.ignoreErrors = ["manual"]
        await ErrorsHandler.throwError(issue: "MANUAL", stack: [])
    }

    /// Crashes persisted to disk and reported on the next launch must go
    /// through the same filter.
    func testPendingCrashGoesThroughFilter() async throws {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lerix_pending_crash.json")
        let payload: [String: Any] = ["issue": "NSRangeException: index 3 beyond bounds", "stack": ["a", "b"]]
        try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        var received: LerixErrorEvent?
        LerixKeys.shared.beforeSend = { e in
            received = e
            return nil
        }
        await LerixCrashReporter.reportPendingCrashIfAny()

        XCTAssertEqual(received?.message, "NSRangeException: index 3 beyond bounds")
        XCTAssertEqual(received?.stack, ["a", "b"])
        XCTAssertEqual(received?.type, .crash)
        XCTAssertEqual(received?.severity, .critical)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
