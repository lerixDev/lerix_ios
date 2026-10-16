import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One survey from `GET /plugin/surveys/config` (contract §2.1).
struct LerixSurvey: Codable, Equatable {
    var id: String
    var type: String
    var question: [String: String]
    var followUp: [String: [String: String]]?
    var thanks: [String: [String: String]]?
    var sampleRate: Double
    var frequencyDays: Double
    var initialDelayDays: Double
    var minAppStarts: Int
    var dismissCooldownDays: Double

    init(
        id: String,
        type: String = "nps",
        question: [String: String] = [:],
        followUp: [String: [String: String]]? = nil,
        thanks: [String: [String: String]]? = nil,
        sampleRate: Double = 1,
        frequencyDays: Double = 90,
        initialDelayDays: Double = 7,
        minAppStarts: Int = 3,
        dismissCooldownDays: Double = 14
    ) {
        self.id = id
        self.type = type
        self.question = question
        self.followUp = followUp
        self.thanks = thanks
        self.sampleRate = sampleRate
        self.frequencyDays = frequencyDays
        self.initialDelayDays = initialDelayDays
        self.minAppStarts = minAppStarts
        self.dismissCooldownDays = dismissCooldownDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = (try? c.decode(String.self, forKey: .type)) ?? "nps"
        question = (try? c.decode([String: String].self, forKey: .question)) ?? [:]
        followUp = try? c.decode([String: [String: String]].self, forKey: .followUp)
        thanks = try? c.decode([String: [String: String]].self, forKey: .thanks)
        sampleRate = (try? c.decode(Double.self, forKey: .sampleRate)) ?? 1
        frequencyDays = (try? c.decode(Double.self, forKey: .frequencyDays)) ?? 90
        initialDelayDays = (try? c.decode(Double.self, forKey: .initialDelayDays)) ?? 7
        minAppStarts = (try? c.decode(Int.self, forKey: .minAppStarts)) ?? 3
        dismissCooldownDays = (try? c.decode(Double.self, forKey: .dismissCooldownDays)) ?? 14
    }

    var rules: LerixSurveyRules {
        LerixSurveyRules(
            sampleRate: sampleRate,
            frequencyDays: frequencyDays,
            initialDelayDays: initialDelayDays,
            minAppStarts: minAppStarts,
            dismissCooldownDays: dismissCooldownDays
        )
    }
}

private struct LerixSurveysPayload: Decodable {
    var surveys: [LerixSurvey]
}

/// Surveys, NPS first (contract §2). Eligibility is decided on the device
/// (`LerixSurveyEligibilityRule`); responses are upserted through the
/// outbox: once when shown, again when answered or dismissed, with the same
/// `clientId`.
public final class LerixSurveys {
    public static let shared = LerixSurveys(store: .shared, outbox: .shared, transport: LerixURLSessionTransport())

    static let configTTL: TimeInterval = 24 * 3600
    private static let installIdKey = "lerix_install_id"

    let store: LerixStore
    let outbox: LerixOutbox
    let transport: LerixTransport
    var now: () -> Date = { Date() }

    init(store: LerixStore, outbox: LerixOutbox, transport: LerixTransport) {
        self.store = store
        self.outbox = outbox
        self.transport = transport
    }

    #if canImport(UIKit)
    public typealias Presenter = UIViewController
    #else
    public typealias Presenter = NSViewController
    #endif

    /// Shows the NPS survey if this install is eligible (contract §2.2):
    /// enough app starts, past the initial delay, inside the sample, and due.
    /// `force: true` skips every check (for testing). Returns whether the
    /// survey was shown. Needs iOS 15 / macOS 12 for the UI.
    @discardableResult
    public func maybeShowNps(force: Bool = false, from viewController: Presenter? = nil) async -> Bool {
        guard #available(iOS 15.0, macOS 12.0, *) else {
            LerixLog.debug("NPS: the survey UI needs iOS 15 / macOS 12")
            return false
        }
        if !force, outbox.isDisabled(.surveys) {
            LerixLog.debug("NPS: surveys are disabled by the server (SDK_DISABLED)")
            return false
        }
        guard let survey = await surveys().first(where: { $0.type == "nps" }) else {
            LerixLog.debug("NPS: no active NPS survey for this platform/version/environment")
            return false
        }
        if !force {
            let result = eligibility(for: survey)
            guard result.eligible else {
                LerixLog.debug("NPS not shown: \(result.failures.joined(separator: "; ")). Next due \(LerixTime.iso(result.nextDue))")
                return false
            }
        }
        return await MainActor.run {
            LerixNpsPresenter.present(survey: survey, surveys: self, from: viewController)
        }
    }

    // MARK: - Eligibility

    func eligibility(for survey: LerixSurvey) -> LerixSurveyEligibility {
        let date = now()
        return LerixSurveyEligibilityRule.evaluate(
            rules: survey.rules,
            surveyId: survey.id,
            installId: Self.installId,
            appStarts: store.int(LerixStoreKey.appStarts) ?? 0,
            firstStartAt: store.date(LerixStoreKey.firstStartAt) ?? date,
            history: history(for: survey.id),
            now: date
        )
    }

    func history(for surveyId: String) -> LerixSurveyHistory {
        LerixSurveyHistory(
            lastShownAt: store.date(LerixStoreKey.survey(surveyId, "lastShownAt")),
            lastAnsweredAt: store.date(LerixStoreKey.survey(surveyId, "lastAnsweredAt")),
            lastDismissedAt: store.date(LerixStoreKey.survey(surveyId, "lastDismissedAt"))
        )
    }

    /// Stable per device (Keychain), used only for the sample bucket and
    /// the first-survey spread.
    static let installId: String = {
        if let existing = LerixKeychain.read(installIdKey), !existing.isEmpty { return existing }
        let id = LerixIds.make()
        LerixKeychain.write(installIdKey, value: id)
        return id
    }()

    // MARK: - Config

    /// Fresh cache (24 h), else the network, else a stale cache.
    func surveys() async -> [LerixSurvey] {
        if let cached = cachedSurveys(), let at = store.date(LerixStoreKey.surveysConfigAt), now().timeIntervalSince(at) < Self.configTTL {
            return cached
        }
        return await fetchSurveys() ?? cachedSurveys() ?? []
    }

    func cachedSurveys() -> [LerixSurvey]? {
        guard let raw = store.get(LerixStoreKey.surveysConfig), let data = try? JSONEncoder().encode(raw) else { return nil }
        return try? JSONDecoder().decode(LerixSurveysPayload.self, from: data).surveys
    }

    private func fetchSurveys() async -> [LerixSurvey]? {
        guard !outbox.isDisabled(.surveys), let userId = await outbox.userIdProvider() else { return nil }
        let query = [
            URLQueryItem(name: "platform", value: LerixPlatform.value),
            URLQueryItem(name: "appVersion", value: LerixDeviceInfo.collectApp().version ?? "0.0.0"),
            URLQueryItem(name: "environment", value: LerixKeys.shared.environment),
        ]
        let response = await transport.get(route: .surveysConfig, headers: ["app-user": userId], query: query)
        switch LerixRetryPolicy.outcome(for: response, now: now()) {
        case .success:
            guard let payload = response.payload,
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let decoded = try? JSONDecoder().decode(LerixSurveysPayload.self, from: data),
                  let json = try? JSONDecoder().decode(LerixJSON.self, from: data) else { return nil }
            store.set(LerixStoreKey.surveysConfig, json)
            store.setDate(LerixStoreKey.surveysConfigAt, now())
            return decoded.surveys
        case .disabled(let until):
            store.setDate(LerixStoreKey.disabledUntil(.surveys), until)
            return nil
        case .reregister:
            await outbox.reregister()
            return nil
        default:
            return nil
        }
    }

    // MARK: - Responses

    func recordShown(survey: LerixSurvey, clientId: String, shownAt: Date) {
        store.setDate(LerixStoreKey.survey(survey.id, "lastShownAt"), shownAt)
        enqueueResponse(survey: survey, clientId: clientId, shownAt: shownAt)
    }

    func recordAnswer(survey: LerixSurvey, clientId: String, shownAt: Date, score: Int, message: String?) {
        let date = now()
        store.setDate(LerixStoreKey.survey(survey.id, "lastAnsweredAt"), date)
        enqueueResponse(survey: survey, clientId: clientId, shownAt: shownAt, answeredAt: date, score: score, message: message)
    }

    func recordDismiss(survey: LerixSurvey, clientId: String, shownAt: Date) {
        let date = now()
        store.setDate(LerixStoreKey.survey(survey.id, "lastDismissedAt"), date)
        enqueueResponse(survey: survey, clientId: clientId, shownAt: shownAt, dismissedAt: date)
    }

    private func enqueueResponse(
        survey: LerixSurvey,
        clientId: String,
        shownAt: Date,
        answeredAt: Date? = nil,
        dismissedAt: Date? = nil,
        score: Int? = nil,
        message: String? = nil
    ) {
        let body = Self.responseBody(
            surveyId: survey.id,
            clientId: clientId,
            shownAt: shownAt,
            answeredAt: answeredAt,
            dismissedAt: dismissedAt,
            score: score,
            message: message
        )
        guard let payload = LerixJSON(any: body) else { return }
        outbox.enqueue(LerixOutboxItem(kind: .survey, createdAt: now(), payload: payload))
        outbox.scheduleDrain(after: 0)
    }

    /// `POST /plugin/surveys/responses` body (contract §2.3). Nulls never
    /// clear a field on the server, so every upsert can send the full shape.
    static func responseBody(
        surveyId: String,
        clientId: String,
        shownAt: Date,
        answeredAt: Date?,
        dismissedAt: Date?,
        score: Int?,
        message: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "clientId": clientId,
            "surveyId": surveyId,
            "shownAt": LerixTime.iso(shownAt),
            "answeredAt": answeredAt.map(LerixTime.iso) ?? NSNull(),
            "dismissedAt": dismissedAt.map(LerixTime.iso) ?? NSNull(),
            "score": score.map { min(max($0, 0), 10) } ?? NSNull(),
            "platform": LerixPlatform.value,
            "appVersion": LerixDeviceInfo.collectApp().version ?? "0.0.0",
            "environment": LerixKeys.shared.environment,
            "locale": LerixPlatform.locale,
            "custom": [String: Any](),
        ]
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            body["message"] = String(message.prefix(2000))
        }
        return body
    }
}
