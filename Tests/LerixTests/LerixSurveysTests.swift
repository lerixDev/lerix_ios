import XCTest
@testable import Lerix

private let config = #"""
{
  "surveys": [
    { "id": "nps-1", "type": "nps", "key": null, "question": { "en": "Recommend us?" },
      "appearance": { "shape": "pill", "accent": "#30a46c", "colorMode": "groups", "groupColors": { "detractor": "#111111", "passive": "red" } } },
    { "id": "rate-1", "type": "rating", "key": "checkout",
      "question": { "en": "How was checkout?", "ar": "كيف كانت تجربة الدفع؟" },
      "options": [
        { "id": "o1", "value": 1, "group": "negative", "emoji": "😞", "label": { "en": "Bad", "ar": "سيئ" } },
        { "id": "o2", "value": 2, "group": "neutral", "emoji": "😐" },
        { "id": "o3", "value": 3, "group": "positive", "emoji": "😍", "color": "#30A46C" }
      ],
      "followUp": { "negative": { "en": "What went wrong?" } },
      "thanks": { "positive": { "en": "Glad to hear it!" } },
      "appearance": { "style": "emoji", "lowLabel": { "en": "Bad", "ar": "سيئ" }, "accent": "green", "showLabels": false },
      "frequencyDays": 0 }
  ]
}
"""#

private func parse(_ json: String) -> [LerixSurvey] {
    let data = Data(json.utf8)
    let decoded = try! JSONDecoder().decode(LerixJSON.self, from: data)
    return LerixSurveyParser.surveys(from: decoded)
}

final class LerixSurveyParsingTests: XCTestCase {
    override func tearDown() {
        LerixUI.shared.locale = nil
        super.tearDown()
    }

    func testReadsBothTypesWithRatingDefaultsAndOptionsInOrder() {
        let surveys = parse(config)
        XCTAssertEqual(surveys.map(\.id), ["nps-1", "rate-1"])
        let nps = surveys[0], rating = surveys[1]
        XCTAssertEqual(nps.type, "nps")
        XCTAssertNil(nps.key)
        XCTAssertEqual(nps.options, [])
        XCTAssertEqual(nps.frequencyDays, 90)
        XCTAssertEqual(nps.minAppStarts, 3)
        XCTAssertEqual(nps.appearance.shape, "pill")
        XCTAssertEqual(nps.appearance.accent, "#30a46c")
        XCTAssertEqual(nps.appearance.colorMode, "groups")
        XCTAssertEqual(nps.appearance.groupColors, [.detractor: "#111111"], "a bad colour is dropped")

        XCTAssertEqual(rating.key, "checkout")
        XCTAssertEqual(rating.frequencyDays, 0)
        XCTAssertEqual(rating.initialDelayDays, 0)
        XCTAssertEqual(rating.minAppStarts, 0)
        XCTAssertEqual(rating.dismissCooldownDays, 7)
        XCTAssertEqual(rating.options.map(\.id), ["o1", "o2", "o3"])
        XCTAssertEqual(rating.options[2].color, "#30A46C")
        XCTAssertEqual(rating.options[0].group, .negative)
    }

    func testRatingCadenceFallbacks() {
        let surveys = parse(#"{"surveys":[{"id":"r","type":"rating","options":[{"id":"a","value":1,"group":"negative"},{"id":"b","value":5,"group":"positive"}]}]}"#)
        XCTAssertEqual(surveys.first?.rules, LerixSurveyRules(sampleRate: 1, frequencyDays: 30, initialDelayDays: 0, minAppStarts: 0, dismissCooldownDays: 7))
    }

    func testDropsABadValueInsteadOfTheSurvey() {
        let rating = parse(config)[1]
        XCTAssertNil(rating.appearance.accent)
        XCTAssertEqual(rating.appearance.style, "emoji")
        XCTAssertEqual(rating.appearance.showLabels, false)
        let odd = parse(#"{"surveys":[{"id":"n","frequencyDays":"x","sampleRate":true,"question":"nope","appearance":[1]}]}"#)
        XCTAssertEqual(odd.first?.type, "nps", "a missing type is nps")
        XCTAssertEqual(odd.first?.frequencyDays, 90)
        XCTAssertEqual(odd.first?.sampleRate, 1)
        XCTAssertEqual(odd.first?.question, [:])
        XCTAssertEqual(odd.first?.appearance, LerixSurveyRawAppearance())
    }

    func testSkipsUnreadableEntriesAndShortRatingsKeepsTheRest() {
        let surveys = parse(#"""
        { "surveys": [
          null,
          { "type": "nps" },
          { "id": 7 },
          { "id": "r", "type": "rating", "options": [{ "id": "a", "value": 1, "group": "positive" }, { "id": "b", "value": "x", "group": "positive" }] },
          { "id": "r2", "type": "rating", "options": [{ "id": "a", "value": 1, "group": "positive" }, { "id": "a", "value": 2, "group": "positive" }, { "id": "c", "value": 2.5, "group": "neutral" }, { "id": "d", "value": 3, "group": "promoter" }] },
          { "id": "future", "type": "poll" },
          { "id": "nps-1", "type": "nps" }
        ] }
        """#)
        XCTAssertEqual(surveys.map(\.id), ["future", "nps-1"])
        XCTAssertTrue(parse(#"{"surveys":{"id":"x"}}"#).isEmpty)
        XCTAssertTrue(parse(#"[]"#).isEmpty)
    }

    func testLocalizesAppearanceAndChoices() {
        LerixUI.shared.locale = "ar-OM"
        let rating = parse(config)[1]
        let appearance = rating.appearance.localized()
        XCTAssertEqual(appearance.style, "emoji")
        XCTAssertEqual(appearance.lowLabel, "سيئ")
        XCTAssertNil(appearance.highLabel)
        XCTAssertNil(appearance.accent)
        XCTAssertFalse(appearance.showLabels)
        XCTAssertEqual(rating.options[0].localized().label, "سيئ")
        XCTAssertNil(rating.options[1].localized().label)
        XCTAssertTrue(parse(config)[0].appearance.localized().showLabels, "showLabels defaults to true")
    }

    func testFindChoiceMatchesIdThenValue() {
        let choices = [
            LerixSurveyChoice(id: "o1", value: 1, group: .negative, label: nil, emoji: nil, color: nil),
            LerixSurveyChoice(id: "5", value: 3, group: .positive, label: nil, emoji: nil, color: nil),
        ]
        XCTAssertEqual(lerixFindChoice(choices, "o1")?.id, "o1")
        XCTAssertEqual(lerixFindChoice(choices, "5")?.id, "5")
        XCTAssertEqual(lerixFindChoice(choices, 3)?.id, "5")
        XCTAssertEqual(lerixFindChoice(choices, "1")?.id, "o1")
        XCTAssertNil(lerixFindChoice(choices, "nope"))
        XCTAssertNil(lerixFindChoice(choices, " "))
        XCTAssertNil(lerixFindChoice(choices, 9))
    }
}

final class LerixRatingEligibilityTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let first = Date(timeIntervalSince1970: 1_767_225_600)
    private let rules = LerixSurveyRules(sampleRate: 1, frequencyDays: 30, initialDelayDays: 0, minAppStarts: 0, dismissCooldownDays: 7)

    private func nextDue(_ rules: LerixSurveyRules? = nil, _ history: LerixSurveyHistory = LerixSurveyHistory()) -> Date {
        LerixSurveyEligibilityRule.nextDue(rules: rules ?? self.rules, surveyId: "rate-1", installId: "install-1", firstStartAt: first, history: history, spread: false)
    }

    private func eligible(_ rules: LerixSurveyRules? = nil, appStarts: Int = 0, _ history: LerixSurveyHistory = LerixSurveyHistory(), now: Date) -> Bool {
        LerixSurveyEligibilityRule.evaluate(
            rules: rules ?? self.rules, surveyId: "rate-1", installId: "install-1", appStarts: appStarts,
            firstStartAt: first, history: history, now: now, spread: false
        ).eligible
    }

    func testNoFirstShowingSpread() {
        XCTAssertEqual(nextDue(), first)
        XCTAssertTrue(eligible(now: first))
    }

    func testWaitsFrequencyAfterAnswerAndCooldownAfterDismiss() {
        let answered = first.addingTimeInterval(day)
        XCTAssertEqual(nextDue(nil, LerixSurveyHistory(lastAnsweredAt: answered)), answered.addingTimeInterval(30 * day))
        XCTAssertEqual(nextDue(nil, LerixSurveyHistory(lastDismissedAt: answered)), answered.addingTimeInterval(7 * day))
        let history = LerixSurveyHistory(lastAnsweredAt: answered)
        XCTAssertFalse(eligible(appStarts: 1, history, now: answered.addingTimeInterval(29 * day)))
        XCTAssertTrue(eligible(appStarts: 1, history, now: answered.addingTimeInterval(30 * day)))
    }

    func testZeroFrequencyMeansNoGapAfterAnAnswer() {
        var zero = rules
        zero.frequencyDays = 0
        let now = first.addingTimeInterval(day)
        XCTAssertTrue(eligible(zero, appStarts: 1, LerixSurveyHistory(lastAnsweredAt: now), now: now))
    }

    func testKeepsSamplingAndInitialDelay() {
        var none = rules
        none.sampleRate = 0
        XCTAssertFalse(eligible(none, now: first))
        var delayed = rules
        delayed.initialDelayDays = 2
        XCTAssertFalse(eligible(delayed, now: first.addingTimeInterval(day)))
    }

    func testNpsStillSpreads() {
        let nps = LerixSurveyRules(sampleRate: 1, frequencyDays: 90, initialDelayDays: 7, minAppStarts: 3, dismissCooldownDays: 14)
        let due = LerixSurveyEligibilityRule.nextDue(rules: nps, surveyId: "s1", installId: "install", firstStartAt: first, history: LerixSurveyHistory())
        let offset = TimeInterval(UInt64(LerixFNV.hash32("installs1spread")) % UInt64(90 * 86_400))
        XCTAssertEqual(due, first.addingTimeInterval(offset))
    }
}

final class LerixSurveyPromptTests: XCTestCase {
    private var root: URL!
    private var store: LerixStore!
    private var outbox: LerixOutbox!
    private var surveys: LerixSurveys!
    private var clock = Date(timeIntervalSince1970: 1_767_225_600)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lerix-survey-tests-\(UUID().uuidString)")
        store = LerixStore(url: root.appendingPathComponent("state.json"))
        // No app user: the outbox keeps every item, so the tests can read them back.
        outbox = LerixOutbox(
            directory: root.appendingPathComponent("outbox"),
            attachmentsDirectory: root.appendingPathComponent("attachments"),
            store: store,
            transport: FakeTransport()
        )
        surveys = LerixSurveys(store: store, outbox: outbox, transport: FakeTransport())
        // Each report one second apart, so the outbox lists them in order.
        surveys.now = { [unowned self] in
            self.clock = self.clock.addingTimeInterval(1)
            return self.clock
        }
        store.set(LerixStoreKey.surveysConfig, try! JSONDecoder().decode(LerixJSON.self, from: Data(config.utf8)))
        store.setDate(LerixStoreKey.surveysConfigAt, clock)
        LerixUI.shared.locale = "en"
    }

    override func tearDown() {
        LerixUI.shared.locale = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var bodies: [[String: Any]] {
        outbox.items(of: .survey).compactMap { $0.payload.anyValue as? [String: Any] }
    }

    private func answerKeys(_ body: [String: Any]) -> String {
        ["shownAt", "answeredAt", "choice", "score", "message", "dismissedAt"]
            .filter { body[$0] != nil && !(body[$0] is NSNull) }
            .sorted()
            .joined(separator: ",")
    }

    func testDueRatingRecordsShownTheChoiceWithItsValueThenTheMessage() async throws {
        let prompt = try XCTUnwrapAsync(await surveys.dueRating("checkout", force: true, custom: ["orderId": "A-1"]))
        XCTAssertEqual(prompt.id, "rate-1")
        XCTAssertEqual(prompt.type, .rating)
        XCTAssertEqual(prompt.key, "checkout")
        XCTAssertEqual(prompt.question, "How was checkout?")
        XCTAssertEqual(prompt.choices.map(\.emoji), ["😞", "😐", "😍"])
        XCTAssertEqual(prompt.appearance.style, "emoji")
        XCTAssertEqual(prompt.groupOf("o1"), .negative)
        XCTAssertEqual(prompt.groupOf(3), .positive)
        XCTAssertNil(prompt.groupOf("nope"))
        XCTAssertEqual(prompt.followUp(.negative), "What went wrong?")
        XCTAssertNil(prompt.followUp(.positive))
        XCTAssertEqual(prompt.thanks(.positive), "Glad to hear it!")
        XCTAssertTrue(bodies.isEmpty, "nothing until shown()")

        prompt.shown()
        prompt.shown()
        XCTAssertFalse(prompt.answer("nope"))
        XCTAssertFalse(prompt.answer(42))
        XCTAssertTrue(prompt.answer("o3"))
        XCTAssertTrue(prompt.answer("o3", message: "  Fast!  "))
        prompt.dismiss() // ignored after an answer

        let sent = bodies
        XCTAssertEqual(sent.map(answerKeys), [
            "shownAt",
            "answeredAt,choice,score,shownAt",
            "answeredAt,choice,message,score,shownAt",
        ])
        XCTAssertEqual(Set(sent.compactMap { $0["clientId"] as? String }).count, 1)
        XCTAssertEqual(sent[1]["surveyId"] as? String, "rate-1")
        XCTAssertEqual(sent[1]["choice"] as? String, "o3")
        XCTAssertEqual(int(sent[1]["score"]), 3)
        XCTAssertEqual(sent[1]["platform"] as? String, LerixPlatform.value)
        XCTAssertEqual((sent[1]["custom"] as? [String: Any])?["orderId"] as? String, "A-1")
        XCTAssertEqual(sent[2]["message"] as? String, "Fast!")
        XCTAssertEqual(sent[2]["answeredAt"] as? String, sent[1]["answeredAt"] as? String, "the message keeps the first answer time")
        XCTAssertEqual(sent[0]["shownAt"] as? String, sent[2]["shownAt"] as? String)

        XCTAssertNotNil(store.date(LerixStoreKey.survey("rate-1", "lastShownAt")))
        XCTAssertNotNil(store.date(LerixStoreKey.survey("rate-1", "lastAnsweredAt")))
        XCTAssertNil(store.date(LerixStoreKey.survey("rate-1", "lastDismissedAt")))
    }

    func testAnsweringByValueSendsTheChoiceId() async throws {
        let prompt = try XCTUnwrapAsync(await surveys.dueRating("checkout", force: true))
        XCTAssertTrue(prompt.answer(2))
        XCTAssertEqual(bodies.last?["choice"] as? String, "o2")
        XCTAssertEqual(int(bodies.last?["score"]), 2)
        let count = bodies.count
        XCTAssertTrue(prompt.answer("o1"), "a later answer still fits the survey")
        XCTAssertEqual(bodies.count, count, "but the first answer stands")
    }

    func testDueNpsTakesZeroToTenAndMapsTheGroup() async throws {
        let prompt = try XCTUnwrapAsync(await surveys.dueNps(force: true))
        XCTAssertEqual(prompt.type, .nps)
        XCTAssertTrue(prompt.choices.isEmpty)
        XCTAssertEqual(prompt.appearance.shape, "pill")
        XCTAssertEqual(prompt.groupOf(6), .detractor)
        XCTAssertEqual(prompt.groupOf(8), .passive)
        XCTAssertEqual(prompt.groupOf(10), .promoter)
        XCTAssertNil(prompt.groupOf(11))
        XCTAssertFalse(prompt.answer(11))
        XCTAssertFalse(prompt.answer(-1))
        XCTAssertTrue(prompt.answer(9))
        let last = try XCTUnwrap(bodies.last)
        XCTAssertEqual(int(last["score"]), 9)
        XCTAssertNil(last["choice"])
    }

    func testDismissWithoutAnswerRecordsDismissedAtWithShownImplied() async throws {
        let prompt = try XCTUnwrapAsync(await surveys.dueRating("checkout", force: true))
        prompt.dismiss()
        prompt.dismiss()
        let sent = bodies
        XCTAssertEqual(sent.map(answerKeys), ["shownAt", "dismissedAt,shownAt"])
        XCTAssertNotNil(store.date(LerixStoreKey.survey("rate-1", "lastDismissedAt")))
        XCTAssertNil(store.date(LerixStoreKey.survey("rate-1", "lastAnsweredAt")))
    }

    func testUnknownKeyOrEmptyKeyIsNil() async {
        let unknown = await surveys.dueRating("nope", force: true)
        XCTAssertNil(unknown)
        let empty = await surveys.dueRating("")
        XCTAssertNil(empty)
    }

    func testRatingIsDueWithoutSpreadAndThenWaitsAfterAnAnswer() async throws {
        store.setDate(LerixStoreKey.firstStartAt, clock)
        store.setInt(LerixStoreKey.appStarts, 1)
        // frequencyDays 0 in the config: due again right after an answer.
        let first = try XCTUnwrapAsync(await surveys.dueRating("checkout"))
        XCTAssertTrue(first.answer("o1"))
        let again = await surveys.dueRating("checkout")
        XCTAssertNotNil(again)
        // NPS: 3 app starts and a 7-day delay by default.
        let nps = await surveys.dueNps()
        XCTAssertNil(nps)
    }

    func testResponseBodyCarriesChoiceAndClampsPerType() {
        let shown = Date(timeIntervalSince1970: 1_760_342_400)
        let rating = LerixSurveys.responseBody(
            surveyId: "s1", clientId: "client-1234", shownAt: shown, answeredAt: shown, dismissedAt: nil,
            score: 80, message: nil, choice: "o4", custom: ["k": 1], maxScore: 100
        )
        XCTAssertEqual(rating["choice"] as? String, "o4")
        XCTAssertEqual(rating["score"] as? Int, 80)
        XCTAssertEqual(rating["custom"] as? [String: Int], ["k": 1])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(rating))
        let nps = LerixSurveys.responseBody(
            surveyId: "s1", clientId: "client-1234", shownAt: shown, answeredAt: shown, dismissedAt: nil, score: 80, message: nil
        )
        XCTAssertEqual(nps["score"] as? Int, 10)
        XCTAssertNil(nps["choice"])
    }
}

/// Outbox payloads come back with whole numbers as `Int64`.
private func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

/// `XCTUnwrap` for an async expression's result.
private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// Calls `onSend` before answering 200, so a test can queue more items mid-drain.
private final class HookTransport: LerixTransport {
    var onSend: () -> Void = {}
    private(set) var sent = 0

    func send(route: LerixRoute, headers: [String: String], query: [URLQueryItem], body: Data?, contentType: String?) async -> LerixHTTPResponse {
        sent += 1
        onSend()
        return LerixHTTPResponse(status: 200, json: ["id": "r"])
    }
}

final class LerixSurveyDrainTests: XCTestCase {
    func testResponsesQueuedDuringADrainAreSentByIt() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lerix-drain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = HookTransport()
        let outbox = LerixOutbox(
            directory: root.appendingPathComponent("outbox"),
            attachmentsDirectory: root.appendingPathComponent("attachments"),
            store: LerixStore(url: root.appendingPathComponent("state.json")),
            transport: transport
        )
        outbox.userIdProvider = { "user-1" }
        func item(_ n: Int) -> LerixOutboxItem {
            LerixOutboxItem(kind: .survey, payload: .object(["clientId": .string("client-12345"), "surveyId": .string("s"), "n": .number(Double(n))]))
        }
        outbox.enqueue(item(1))
        var queued = false
        transport.onSend = {
            guard !queued else { return }
            queued = true
            outbox.enqueue(item(2)) // e.g. the answer, right after "shown"
        }
        await outbox.drain(.surveys)
        XCTAssertEqual(transport.sent, 2)
        XCTAssertTrue(outbox.items(of: .survey).isEmpty)
    }
}
