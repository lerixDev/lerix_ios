import XCTest
@testable import Lerix

final class LerixFeedbackTests: XCTestCase {
    func testConfigDecodingFallsBackToDefaults() throws {
        let json = #"{"enabled":true,"email":"required","maxScreenshots":9,"labels":[{"key":"bug","title":{"en":"Bug","ar":"خطأ"}}]}"#
        let config = try JSONDecoder().decode(LerixFeedbackConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.email, "required")
        XCTAssertEqual(config.screenshot, "optional")
        XCTAssertEqual(config.maxScreenshots, 5, "clamped to 0...5")
        XCTAssertEqual(config.maxMessageLength, 4000)
        XCTAssertEqual(config.labels.first?.hidden, false)
    }

    func testSettingsMergeOptions() {
        var config = LerixFeedbackConfig.defaults
        config.labels[1].hidden = true
        let settings = LerixFeedbackSettings(config: config, options: LerixFeedbackOptions(), storedEmail: "a@b.co")
        XCTAssertEqual(settings.labels.map(\.key), ["bug", "praise"], "hidden labels are not offered")
        XCTAssertEqual(settings.prefillEmail, "a@b.co")

        let overridden = LerixFeedbackSettings(
            config: config,
            options: LerixFeedbackOptions(labels: ["praise", "bug"], email: .hidden, screenshot: .hidden, prefillEmail: "x@y.io"),
            storedEmail: "a@b.co"
        )
        XCTAssertEqual(overridden.labels.map(\.key), ["praise", "bug"])
        XCTAssertEqual(overridden.emailMode, .hidden)
        XCTAssertEqual(overridden.maxScreenshots, 0)
        XCTAssertEqual(overridden.prefillEmail, "x@y.io")
    }

    func testScreenshotSniffing() {
        XCTAssertEqual(LerixScreenshotData(data: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]))?.mime, "image/png")
        XCTAssertEqual(LerixScreenshotData(data: Data([0xFF, 0xD8, 0xFF, 0xE0]))?.mime, "image/jpeg")
        XCTAssertEqual(LerixScreenshotData(data: Data(Array("RIFF\u{0}\u{0}\u{0}\u{0}WEBP".utf8)))?.mime, "image/webp")
        XCTAssertNil(LerixScreenshotData(data: Data("GIF89a".utf8)))
    }

    func testBodyShape() {
        let body = LerixFeedback.body(message: "Checkout button does nothing", labels: ["bug"], email: "u@x.io", custom: ["plan": "pro", "bad": Date()])
        XCTAssertTrue(LerixIds.isValid(body["clientId"] as! String))
        XCTAssertEqual(body["platform"] as? String, LerixPlatform.value)
        XCTAssertEqual(body["labels"] as? [String], ["bug"])
        XCTAssertEqual(body["email"] as? String, "u@x.io")
        XCTAssertEqual(body["custom"] as? [String: String], ["plan": "pro"])
        XCTAssertNotNil(body["device"] as? [String: Any])
        XCTAssertNotNil(body["app"] as? [String: Any])
        XCTAssertNotNil(body["breadcrumbs"] as? [[String: Any]])
        XCTAssertNil(body["attachmentIds"], "added at delivery time")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    func testCustomLimits() {
        var many: [String: Any] = [:]
        for i in 0..<60 { many[String(format: "k%02d", i)] = i }
        XCTAssertEqual(LerixFeedback.sanitizeCustom(many)?.count, 50)
        XCTAssertNil(LerixFeedback.sanitizeCustom(["big": String(repeating: "x", count: 20_000)]))
    }

    func testEmailValidation() {
        XCTAssertTrue(LerixFeedback.isValidEmail("user@example.com"))
        XCTAssertFalse(LerixFeedback.isValidEmail("user@"))
        XCTAssertFalse(LerixFeedback.isValidEmail("no at.com"))
    }

    func testSurveyResponseBody() {
        let shown = Date(timeIntervalSince1970: 1_760_342_400)
        let body = LerixSurveys.responseBody(
            surveyId: "s1", clientId: "client-1234", shownAt: shown,
            answeredAt: nil, dismissedAt: nil, score: 12, message: "  "
        )
        XCTAssertEqual(body["shownAt"] as? String, "2025-10-13T08:00:00.000Z")
        XCTAssertTrue(body["answeredAt"] is NSNull)
        XCTAssertEqual(body["score"] as? Int, 10, "clamped")
        XCTAssertNil(body["message"], "blank message omitted")
    }
}

final class LerixLocalizationTests: XCTestCase {
    override func tearDown() {
        LerixUI.shared.locale = nil
        super.tearDown()
    }

    func testBundledEnglishAndArabic() {
        let ui = LerixUI.shared
        ui.locale = "en"
        XCTAssertEqual(ui.string("feedback.title"), "Send feedback")
        XCTAssertFalse(ui.isRightToLeft)
        ui.locale = "ar-OM"
        XCTAssertEqual(ui.string("feedback.title"), "إرسال ملاحظات")
        XCTAssertTrue(ui.isRightToLeft)
        ui.locale = "fr"
        XCTAssertEqual(ui.string("feedback.title"), "Send feedback", "unknown languages fall back to English")
    }

    func testEveryEnglishKeyHasAnArabicTranslation() throws {
        let bundle = try XCTUnwrap(LerixUI.resourceBundle)
        let en = try XCTUnwrap(bundle.path(forResource: "Lerix", ofType: "strings", inDirectory: nil, forLocalization: "en"))
        let ar = try XCTUnwrap(bundle.path(forResource: "Lerix", ofType: "strings", inDirectory: nil, forLocalization: "ar"))
        let enKeys = Set((NSDictionary(contentsOfFile: en) as? [String: String] ?? [:]).keys)
        let arKeys = Set((NSDictionary(contentsOfFile: ar) as? [String: String] ?? [:]).keys)
        XCTAssertFalse(enKeys.isEmpty)
        XCTAssertEqual(enKeys, arKeys)
    }

    func testOverridesAndServerText() {
        let ui = LerixUI.shared
        ui.locale = "en"
        ui.setStrings(["common.send": "Submit"], locale: "en")
        XCTAssertEqual(ui.string("common.send"), "Submit")
        ui.locale = "ar"
        XCTAssertEqual(ui.string("common.send"), "إرسال")
        XCTAssertEqual(ui.localized(["en": "Bug", "ar": "خطأ"]), "خطأ")
        XCTAssertEqual(ui.localized(["en": "Bug"]), "Bug")
        XCTAssertNil(ui.localized([:]))
        ui.setStrings(["common.send": "Send"], locale: "en")
    }
}
