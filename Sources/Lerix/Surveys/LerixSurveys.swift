import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// In-app surveys (contract §2, PLAN-survey-customization §4): NPS, shown
/// automatically when an install is due, and rating (CSAT) surveys, shown
/// when the app asks for one by key. Eligibility is decided on the device
/// (`LerixSurveyEligibilityRule`); responses are upserted through the outbox:
/// once when shown, again when answered or dismissed, with the same
/// `clientId`. `dueNps` / `dueRating` return the survey for your own UI.
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
    /// `force: true` skips every check (for testing). `custom` is stored with
    /// the response. Returns whether the survey was shown. Needs iOS 15 /
    /// macOS 12 for the UI.
    @discardableResult
    public func maybeShowNps(force: Bool = false, custom: [String: Any]? = nil, from viewController: Presenter? = nil) async -> Bool {
        await present(.nps, key: nil, force: force, custom: custom, from: viewController)
    }

    /// Shows the rating survey with `key` (set in the dashboard) when it is
    /// active, matches this app and is due: at most once per `frequencyDays`
    /// per install (0 = no limit), and not for `dismissCooldownDays` after a
    /// dismiss. `force: true` skips those checks. `custom` is stored with the
    /// response. Returns whether the survey was shown; in debug mode the
    /// console says why not. Needs iOS 15 / macOS 12 for the UI.
    @discardableResult
    public func showRating(_ key: String, force: Bool = false, custom: [String: Any]? = nil, from viewController: Presenter? = nil) async -> Bool {
        guard !key.isEmpty else {
            LerixLog.debug("showRating needs the survey key set in the dashboard")
            return false
        }
        return await present(.rating, key: key, force: force, custom: custom, from: viewController)
    }

    /// The NPS survey as a prompt for your own UI when this install is due
    /// (or always with `force: true`), else `nil`. Nothing is recorded until
    /// you call the prompt's methods. Works on every OS version.
    public func dueNps(force: Bool = false, custom: [String: Any]? = nil) async -> LerixSurveyPrompt? {
        await due(.nps, key: nil, force: force).map { LerixSurveyPrompt(run: LerixSurveyRun(owner: self, survey: $0, custom: custom)) }
    }

    /// The rating survey with `key` as a prompt for your own UI when it is due
    /// (or always with `force: true`), else `nil`.
    public func dueRating(_ key: String, force: Bool = false, custom: [String: Any]? = nil) async -> LerixSurveyPrompt? {
        guard !key.isEmpty else { return nil }
        return await due(.rating, key: key, force: force).map { LerixSurveyPrompt(run: LerixSurveyRun(owner: self, survey: $0, custom: custom)) }
    }

    private func present(_ type: LerixSurveyType, key: String?, force: Bool, custom: [String: Any]?, from viewController: Presenter?) async -> Bool {
        guard #available(iOS 15.0, macOS 12.0, *) else {
            LerixLog.debug("Surveys: the survey UI needs iOS 15 / macOS 12; use dueNps / dueRating for your own UI")
            return false
        }
        guard let survey = await due(type, key: key, force: force) else { return false }
        let run = LerixSurveyRun(owner: self, survey: survey, custom: custom)
        return await MainActor.run {
            LerixSurveyPresenter.present(run: run, from: viewController)
        }
    }

    /// The survey to show, or `nil` with the reason logged in debug mode: the
    /// active NPS survey, or the active rating with `key`, if this install is
    /// due. `force` skips every rule.
    func due(_ type: LerixSurveyType, key: String?, force: Bool) async -> LerixSurvey? {
        let label = type == .nps ? "NPS" : "Rating \"\(key ?? "")\""
        if !force, outbox.isDisabled(.surveys) {
            LerixLog.debug("\(label) skipped: surveys are paused by the server (SDK_DISABLED)")
            return nil
        }
        let match = await surveys().first { $0.type == type.rawValue && (type == .nps || $0.key == key) }
        guard let survey = match else {
            LerixLog.debug("\(label): no active survey for this platform/version/environment")
            return nil
        }
        if force { return survey }
        let result = eligibility(for: survey)
        guard result.eligible else {
            LerixLog.debug("\(label) not shown: \(result.failures.joined(separator: "; ")). Next due \(LerixTime.iso(result.nextDue))")
            return nil
        }
        return survey
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
            now: date,
            spread: !survey.isRating
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
        guard let raw = store.get(LerixStoreKey.surveysConfig) else { return nil }
        return LerixSurveyParser.surveys(from: raw)
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
            guard let payload = response.payload, let json = LerixJSON(any: payload), json.objectValue != nil else { return nil }
            store.set(LerixStoreKey.surveysConfig, json)
            store.setDate(LerixStoreKey.surveysConfigAt, now())
            return LerixSurveyParser.surveys(from: json)
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

    func enqueue(body: [String: Any]) {
        guard let payload = LerixJSON(any: body) else { return }
        outbox.enqueue(LerixOutboxItem(kind: .survey, createdAt: now(), payload: payload))
        outbox.scheduleDrain(after: 0)
    }

    /// `POST /plugin/surveys/responses` body (contract §2.3, plan §4.3).
    /// Nulls never clear a field on the server, so every upsert can send the
    /// full shape. A rating answer carries its `choice` id and value as `score`.
    static func responseBody(
        surveyId: String,
        clientId: String,
        shownAt: Date,
        answeredAt: Date?,
        dismissedAt: Date?,
        score: Int?,
        message: String?,
        choice: String? = nil,
        custom: [String: Any]? = nil,
        maxScore: Int = 10
    ) -> [String: Any] {
        var body: [String: Any] = [
            "clientId": clientId,
            "surveyId": surveyId,
            "shownAt": LerixTime.iso(shownAt),
            "answeredAt": answeredAt.map(LerixTime.iso) ?? NSNull(),
            "dismissedAt": dismissedAt.map(LerixTime.iso) ?? NSNull(),
            "score": score.map { min(max($0, 0), maxScore) } ?? NSNull(),
            "platform": LerixPlatform.value,
            "appVersion": LerixDeviceInfo.collectApp().version ?? "0.0.0",
            "environment": LerixKeys.shared.environment,
            "locale": LerixPlatform.locale,
            "custom": custom ?? [String: Any](),
        ]
        if let choice = choice { body["choice"] = choice }
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            body["message"] = String(message.prefix(2000))
        }
        return body
    }
}
