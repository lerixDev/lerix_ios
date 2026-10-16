import XCTest
@testable import Lerix

/// Replays scripted responses per route path.
final class FakeTransport: LerixTransport {
    struct Request {
        let path: String
        let headers: [String: String]
        let body: Data?
        let contentType: String?

        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private let lock = NSLock()
    private var scripted: [String: [LerixHTTPResponse]] = [:]
    private var _requests: [Request] = []
    var fallback = LerixHTTPResponse(status: 200, json: [:])

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }

    func enqueue(_ path: String, _ responses: LerixHTTPResponse...) {
        lock.lock(); scripted[path, default: []].append(contentsOf: responses); lock.unlock()
    }

    func send(route: LerixRoute, headers: [String: String], query: [URLQueryItem], body: Data?, contentType: String?) async -> LerixHTTPResponse {
        record(route: route, headers: headers, body: body, contentType: contentType)
    }

    private func record(route: LerixRoute, headers: [String: String], body: Data?, contentType: String?) -> LerixHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        _requests.append(Request(path: route.path, headers: headers, body: body, contentType: contentType))
        if var queue = scripted[route.path], !queue.isEmpty {
            let next = queue.removeFirst()
            scripted[route.path] = queue
            return next
        }
        return fallback
    }
}

final class LerixRetryPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func outcome(_ status: Int?, _ code: String? = nil, retryAfter: Double? = nil) -> LerixDeliveryOutcome {
        LerixRetryPolicy.outcome(status: status, errorCode: code, retryAfterSeconds: retryAfter, now: now)
    }

    func testContractTable() {
        XCTAssertEqual(outcome(200), .success)
        XCTAssertEqual(outcome(201), .success)
        XCTAssertEqual(outcome(400), .drop)
        XCTAssertEqual(outcome(413), .drop)
        XCTAssertEqual(outcome(422), .drop)
        for status in [401, 403, 404, 429, 500, 502, 503] {
            XCTAssertEqual(outcome(status), .retry, "\(status)")
        }
        XCTAssertEqual(outcome(nil), .retry, "network error")
    }

    func test401NeverDeletes() {
        XCTAssertEqual(outcome(401, "API_KEY_NOT_VALID"), .retry)
        XCTAssertEqual(outcome(401, "anything"), .retry)
    }

    func testUserNotRegisteredReregisters() {
        XCTAssertEqual(outcome(409), .reregister)
        XCTAssertEqual(outcome(400, "USER_PROJECT_NOT_EXIST"), .reregister)
        XCTAssertEqual(outcome(403, "PROJECT_USER_MISMATCH"), .reregister)
    }

    func testSdkDisabled() {
        XCTAssertEqual(outcome(403, "SDK_DISABLED", retryAfter: 600), .disabled(until: now.addingTimeInterval(600)))
        XCTAssertEqual(outcome(403, "SDK_DISABLED"), .disabled(until: now.addingTimeInterval(3600)))
    }

    func testWrongProjectKeepsData() {
        XCTAssertEqual(outcome(400, "PROJECT_NOT_FOUND"), .retry)
    }

    func testGatewayErrorEnvelopeInA2xx() {
        let wrapped400 = LerixHTTPResponse(status: 201, json: ["error": "VALIDATION", "statusCode": 400])
        XCTAssertEqual(LerixRetryPolicy.outcome(for: wrapped400, now: now), .drop)
        let wrappedUnknown = LerixHTTPResponse(status: 200, json: ["error": "SOMETHING"])
        XCTAssertEqual(LerixRetryPolicy.outcome(for: wrappedUnknown, now: now), .retry)
        let disabled = LerixHTTPResponse(status: 403, json: ["code": "SDK_DISABLED", "retryAfterSeconds": 60])
        XCTAssertEqual(LerixRetryPolicy.outcome(for: disabled, now: now), .disabled(until: now.addingTimeInterval(60)))
    }

    func testBackoffBounds() {
        XCTAssertEqual(LerixRetryPolicy.backoff(failures: 1, jitter: 0.5), 2)
        XCTAssertEqual(LerixRetryPolicy.backoff(failures: 2, jitter: 0.5), 4)
        XCTAssertEqual(LerixRetryPolicy.backoff(failures: 50, jitter: 1), 300)
        for failures in 1...30 {
            let value = LerixRetryPolicy.backoff(failures: failures)
            XCTAssertGreaterThanOrEqual(value, 2)
            XCTAssertLessThanOrEqual(value, 300)
        }
    }
}

final class LerixOutboxTests: XCTestCase {
    private var root: URL!
    private var transport: FakeTransport!
    private var store: LerixStore!
    private var outbox: LerixOutbox!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lerix-tests-\(UUID().uuidString)")
        transport = FakeTransport()
        store = LerixStore(url: root.appendingPathComponent("state.json"))
        outbox = LerixOutbox(
            directory: root.appendingPathComponent("outbox"),
            attachmentsDirectory: root.appendingPathComponent("attachments"),
            store: store,
            transport: transport
        )
        outbox.userIdProvider = { "user-1" }
        outbox.eventContext = { ["platform": "ios"] }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func event(_ name: String, at date: Date = Date()) -> LerixOutboxItem {
        let id = LerixIds.make()
        return LerixOutboxItem(id: id, kind: .event, createdAt: date, payload: .object([
            "eventId": .string(id), "name": .string(name), "ts": .number(Double(LerixTime.millis(date))),
        ]))
    }

    private func survey() -> LerixOutboxItem {
        LerixOutboxItem(kind: .survey, payload: .object(["clientId": .string("client-12345"), "surveyId": .string("s")]))
    }

    func testItemsPersistAsOneFilePerItemOldestFirst() {
        let base = Date()
        outbox.enqueue(event("second", at: base.addingTimeInterval(1)))
        outbox.enqueue(event("first", at: base))
        let files = try! FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("outbox").path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count, 2)
        XCTAssertFalse(files.contains { $0.hasSuffix(".tmp") })
        // A new instance reads them back.
        let reopened = LerixOutbox(
            directory: root.appendingPathComponent("outbox"),
            attachmentsDirectory: root.appendingPathComponent("attachments"),
            store: store,
            transport: transport
        )
        XCTAssertEqual(reopened.items(of: .event).map { $0.payload["name"]?.stringValue }, ["first", "second"])
    }

    func testEventBatchSuccessDeletes() async {
        for i in 0..<3 { outbox.enqueue(event("e\(i)")) }
        transport.enqueue("plugin/events", LerixHTTPResponse(status: 200, json: ["accepted": 2, "rejected": [["index": 1, "reason": "invalid_name"]]]))
        await outbox.drain(.analytics)
        XCTAssertEqual(outbox.count(of: .event), 0, "rejected events are dropped, not retried")
        let request = transport.requests.first { $0.path == "plugin/events" }
        XCTAssertEqual(request?.headers["app-user"], "user-1")
        XCTAssertEqual((request?.json?["events"] as? [Any])?.count, 3)
        XCTAssertEqual((request?.json?["context"] as? [String: Any])?["platform"] as? String, "ios")
    }

    func testBatchesAreAtMost100() async {
        for i in 0..<150 { outbox.enqueue(event("e\(i)")) }
        await outbox.drain(.analytics)
        let sizes = transport.requests.filter { $0.path == "plugin/events" }.map { ($0.json?["events"] as? [Any])?.count ?? 0 }
        XCTAssertEqual(sizes, [100, 50])
    }

    func test401KeepsItemsAndBacksOff() async {
        outbox.enqueue(survey())
        transport.enqueue("plugin/surveys/responses", LerixHTTPResponse(status: 401, json: ["message": "nope"]))
        await outbox.drain(.surveys)
        XCTAssertEqual(outbox.count(of: .survey), 1)
        XCTAssertNotNil(outbox.backoffRemaining(.surveys))
        // Backing off: a second drain sends nothing.
        await outbox.drain(.surveys)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func test400Deletes() async {
        outbox.enqueue(survey())
        transport.enqueue("plugin/surveys/responses", LerixHTTPResponse(status: 400, json: ["error": "BAD"]))
        await outbox.drain(.surveys)
        XCTAssertEqual(outbox.count(of: .survey), 0)
    }

    func testNetworkErrorKeeps() async {
        outbox.enqueue(survey())
        transport.enqueue("plugin/surveys/responses", .network)
        await outbox.drain(.surveys)
        XCTAssertEqual(outbox.count(of: .survey), 1)
    }

    func testSdkDisabledStopsThatFeatureOnly() async {
        outbox.enqueue(survey())
        outbox.enqueue(event("e"))
        transport.enqueue("plugin/surveys/responses", LerixHTTPResponse(status: 403, json: ["code": "SDK_DISABLED", "retryAfterSeconds": 3600]))
        await outbox.drainAll()
        XCTAssertTrue(outbox.isDisabled(.surveys))
        XCTAssertFalse(outbox.isDisabled(.analytics))
        XCTAssertEqual(outbox.count(of: .survey), 1)
        XCTAssertEqual(outbox.count(of: .event), 0)
        // Persisted: a new outbox on the same store stays disabled.
        let reopened = LerixOutbox(directory: root.appendingPathComponent("outbox"), attachmentsDirectory: root, store: store, transport: transport)
        XCTAssertTrue(reopened.isDisabled(.surveys))
    }

    func testUserNotRegisteredReregistersAndKeeps() async {
        var reregistered = 0
        outbox.reregister = { reregistered += 1 }
        outbox.enqueue(survey())
        transport.enqueue("plugin/surveys/responses", LerixHTTPResponse(status: 400, json: ["error": "USER_PROJECT_NOT_EXIST", "statusCode": 400]))
        await outbox.drain(.surveys)
        XCTAssertEqual(reregistered, 1)
        XCTAssertEqual(outbox.count(of: .survey), 1)
    }

    func testNoUserKeepsEverything() async {
        outbox.userIdProvider = { nil }
        outbox.enqueue(survey())
        await outbox.drain(.surveys)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(outbox.count(of: .survey), 1)
    }

    func testEventCapDropsOldAndOversized() {
        outbox.enqueue(event("old", at: Date().addingTimeInterval(-8 * 86_400)))
        outbox.enqueue(event("new"))
        outbox.pruneEvents()
        XCTAssertEqual(outbox.items(of: .event).map { $0.payload["name"]?.stringValue }, ["new"])
    }

    // MARK: Feedback

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 32))

    private func feedbackItem() -> LerixOutboxItem {
        let file = outbox.storeAttachment(png, fileExtension: "png")!
        return LerixOutboxItem(
            kind: .feedback,
            payload: .object(["clientId": .string("client-abcdef"), "message": .string("hi")]),
            attachments: [LerixOutboxAttachment(file: file, mime: "image/png", width: 10, height: 20)]
        )
    }

    func testFeedbackUploadsAttachmentThenPosts() async {
        let item = feedbackItem()
        outbox.enqueue(item)
        transport.enqueue("plugin/feedback/attachments", LerixHTTPResponse(status: 201, json: ["id": "att-1"]))
        transport.enqueue("plugin/feedback", LerixHTTPResponse(status: 201, json: ["id": "fb-1", "status": "created"]))
        let id = await outbox.deliverFeedbackNow(itemId: item.id)
        XCTAssertEqual(id, "fb-1")
        XCTAssertEqual(outbox.count(of: .feedback), 0)
        let upload = transport.requests[0]
        XCTAssertTrue(upload.contentType?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertEqual(transport.requests[1].json?["attachmentIds"] as? [String], ["att-1"])
        let leftovers = try! FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("attachments").path)
        XCTAssertTrue(leftovers.isEmpty, "local screenshot deleted once the feedback is accepted")
    }

    func testFeedbackCheckpointsUploadedAttachment() async {
        let item = feedbackItem()
        outbox.enqueue(item)
        transport.enqueue("plugin/feedback/attachments", LerixHTTPResponse(status: 201, json: ["id": "att-1"]))
        transport.enqueue("plugin/feedback", LerixHTTPResponse(status: 401, json: [:]))
        await outbox.drain(.feedback)
        let saved = outbox.item(id: item.id, kind: .feedback)
        XCTAssertEqual(saved?.attachments?.first?.uploadedId, "att-1")
        XCTAssertEqual(saved?.attachments?.first?.uploadedBy, "user-1")

        // Next attempt (after the backoff) skips the upload.
        let retry = LerixOutbox(
            directory: root.appendingPathComponent("outbox"),
            attachmentsDirectory: root.appendingPathComponent("attachments"),
            store: store,
            transport: transport
        )
        retry.userIdProvider = { "user-1" }
        transport.enqueue("plugin/feedback", LerixHTTPResponse(status: 201, json: ["id": "fb-2"]))
        await retry.drain(.feedback)
        XCTAssertEqual(transport.requests.filter { $0.path == "plugin/feedback/attachments" }.count, 1)
        XCTAssertEqual(retry.count(of: .feedback), 0)
    }

    func testRejectedAttachmentIsDroppedButFeedbackSent() async {
        let item = feedbackItem()
        outbox.enqueue(item)
        transport.enqueue("plugin/feedback/attachments", LerixHTTPResponse(status: 400, json: ["error": "INVALID_FILE"]))
        transport.enqueue("plugin/feedback", LerixHTTPResponse(status: 201, json: ["id": "fb-3"]))
        let id = await outbox.deliverFeedbackNow(itemId: item.id)
        XCTAssertEqual(id, "fb-3")
        XCTAssertEqual(transport.requests.last?.json?["attachmentIds"] as? [String], [])
    }

    func testNewAppUserReuploads() async {
        var item = feedbackItem()
        item.attachments![0].uploadedId = "att-old"
        item.attachments![0].uploadedAt = Date()
        item.attachments![0].uploadedBy = "someone-else"
        outbox.enqueue(item)
        transport.enqueue("plugin/feedback/attachments", LerixHTTPResponse(status: 201, json: ["id": "att-new"]))
        transport.enqueue("plugin/feedback", LerixHTTPResponse(status: 201, json: ["id": "fb-4"]))
        _ = await outbox.deliverFeedbackNow(itemId: item.id)
        XCTAssertEqual(transport.requests.last?.json?["attachmentIds"] as? [String], ["att-new"])
    }
}
