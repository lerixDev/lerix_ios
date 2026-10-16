import XCTest
@testable import Lerix

final class LerixSurveyEligibilityTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private let rules = LerixSurveyRules(
        sampleRate: 1.0,
        frequencyDays: 90,
        initialDelayDays: 7,
        minAppStarts: 3,
        dismissCooldownDays: 14
    )

    // MARK: FNV-1a

    func testFnvVectors() {
        XCTAssertEqual(LerixFNV.hash32(""), 0x811c9dc5)
        XCTAssertEqual(LerixFNV.hash32("a"), 0xe40c292c)
        XCTAssertEqual(LerixFNV.hash32("foobar"), 0xbf9cf968)
    }

    func testFnvHashesUtf8Bytes() {
        // "é" is two UTF-8 bytes (0xC3 0xA9); hashing must use them, not the
        // UTF-16 unit or the scalar value.
        var expected: UInt32 = 0x811c9dc5
        for byte: UInt8 in [0xC3, 0xA9] {
            expected ^= UInt32(byte)
            expected = expected &* 0x01000193
        }
        XCTAssertEqual(LerixFNV.hash32("é"), expected)
    }

    func testBucketIsHashModTenThousand() {
        XCTAssertEqual(LerixFNV.bucket("foobar"), Double(0xbf9cf968 % 10_000) / 10_000)
        XCTAssertEqual(LerixFNV.bucket(""), Double(0x811c9dc5 % 10_000) / 10_000)
    }

    // MARK: Spread

    func testFirstSurveyIsSpreadDeterministically() {
        let due = LerixSurveyEligibilityRule.nextDue(
            rules: rules, surveyId: "s1", installId: "install", firstStartAt: start, history: LerixSurveyHistory()
        )
        let offset = TimeInterval(UInt64(LerixFNV.hash32("installs1spread")) % UInt64(90 * 86_400))
        XCTAssertEqual(due, start.addingTimeInterval(offset))
        XCTAssertLessThan(due.timeIntervalSince(start), 90 * day)
    }

    func testZeroFrequencyHasNoSpread() {
        var zero = rules
        zero.frequencyDays = 0
        let due = LerixSurveyEligibilityRule.nextDue(
            rules: zero, surveyId: "s1", installId: "install", firstStartAt: start, history: LerixSurveyHistory()
        )
        XCTAssertEqual(due, start)
    }

    // MARK: Eligibility

    private func evaluate(
        rules: LerixSurveyRules? = nil,
        appStarts: Int = 5,
        history: LerixSurveyHistory = LerixSurveyHistory(),
        now: Date
    ) -> LerixSurveyEligibility {
        LerixSurveyEligibilityRule.evaluate(
            rules: rules ?? self.rules,
            surveyId: "s1",
            installId: "install",
            appStarts: appStarts,
            firstStartAt: start,
            history: history,
            now: now
        )
    }

    func testEligibleAfterEverything() {
        let result = evaluate(now: start.addingTimeInterval(91 * day))
        XCTAssertTrue(result.eligible, result.failures.joined(separator: "; "))
    }

    func testTooFewAppStarts() {
        let result = evaluate(appStarts: 2, now: start.addingTimeInterval(91 * day))
        XCTAssertFalse(result.eligible)
        XCTAssertTrue(result.failures.contains { $0.contains("appStarts") })
    }

    func testInitialDelay() {
        let result = evaluate(now: start.addingTimeInterval(6 * day))
        XCTAssertFalse(result.eligible)
        XCTAssertTrue(result.failures.contains { $0.contains("initial delay") })
    }

    func testSampleRateZeroExcludesEveryone() {
        var none = rules
        none.sampleRate = 0
        XCTAssertFalse(evaluate(rules: none, now: start.addingTimeInterval(200 * day)).eligible)
    }

    func testSampleRateComparesBucket() {
        let bucket = LerixFNV.bucket("installs1")
        var justAbove = rules
        justAbove.sampleRate = bucket + 0.0001
        var exactly = rules
        exactly.sampleRate = bucket
        XCTAssertTrue(evaluate(rules: justAbove, now: start.addingTimeInterval(200 * day)).eligible)
        XCTAssertFalse(evaluate(rules: exactly, now: start.addingTimeInterval(200 * day)).eligible)
    }

    func testAnsweredWaitsFrequency() {
        let answered = start.addingTimeInterval(100 * day)
        let history = LerixSurveyHistory(lastShownAt: answered, lastAnsweredAt: answered, lastDismissedAt: nil)
        XCTAssertFalse(evaluate(history: history, now: answered.addingTimeInterval(89 * day)).eligible)
        let later = evaluate(history: history, now: answered.addingTimeInterval(90 * day))
        XCTAssertTrue(later.eligible)
        XCTAssertEqual(later.nextDue, answered.addingTimeInterval(90 * day))
    }

    func testDismissedWaitsCooldownOnly() {
        let dismissed = start.addingTimeInterval(100 * day)
        let history = LerixSurveyHistory(lastShownAt: dismissed, lastAnsweredAt: nil, lastDismissedAt: dismissed)
        XCTAssertFalse(evaluate(history: history, now: dismissed.addingTimeInterval(13 * day)).eligible)
        XCTAssertTrue(evaluate(history: history, now: dismissed.addingTimeInterval(14 * day)).eligible)
    }

    func testLaterOfAnswerAndDismissDecides() {
        let answered = start.addingTimeInterval(10 * day)
        let dismissedAfter = start.addingTimeInterval(110 * day)
        let dismissThenAnswer = LerixSurveyHistory(lastShownAt: nil, lastAnsweredAt: dismissedAfter, lastDismissedAt: answered)
        XCTAssertEqual(
            LerixSurveyEligibilityRule.nextDue(rules: rules, surveyId: "s1", installId: "install", firstStartAt: start, history: dismissThenAnswer),
            dismissedAfter.addingTimeInterval(90 * day)
        )
        let answerThenDismiss = LerixSurveyHistory(lastShownAt: nil, lastAnsweredAt: answered, lastDismissedAt: dismissedAfter)
        XCTAssertEqual(
            LerixSurveyEligibilityRule.nextDue(rules: rules, surveyId: "s1", installId: "install", firstStartAt: start, history: answerThenDismiss),
            dismissedAfter.addingTimeInterval(14 * day)
        )
    }
}
