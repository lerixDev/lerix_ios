import Foundation

/// A due survey for your own UI (`Lerix.surveys.dueNps()` /
/// `dueRating(_:)`). Nothing is recorded until you call `shown()`;
/// `answer` and `dismiss()` call it for you if you didn't. Each prompt is one
/// showing: ask for a new one the next time. It records exactly what the
/// built-in sheet would, so results and cadence are the same. Thread-safe.
public final class LerixSurveyPrompt: @unchecked Sendable {
    public let id: String
    public let type: LerixSurveyType
    public let key: String?
    /// The question in the UI language, or `nil` to use your own default.
    public let question: String?
    /// Rating: the choices in display order. NPS: empty (answer with 0–10).
    public let choices: [LerixSurveyChoice]
    public let appearance: LerixSurveyAppearance

    let run: LerixSurveyRun

    init(run: LerixSurveyRun) {
        let survey = run.survey
        self.run = run
        id = survey.id
        type = LerixSurveyType(rawValue: survey.type) ?? .nps
        key = survey.key
        question = LerixUI.shared.localized(survey.question)
        choices = run.choices
        appearance = survey.appearance.localized()
    }

    /// NPS: the group of a 0–10 score. Rating: the group of the choice with this value.
    /// `nil` for an answer that doesn't fit the survey.
    public func groupOf(_ answer: Int) -> LerixSurveyGroup? { run.groupOf(.value(answer)) }

    /// Rating: the group of the choice with this id (or value). `nil` for an unknown choice.
    public func groupOf(_ answer: String) -> LerixSurveyGroup? { run.groupOf(.text(answer)) }

    /// The follow-up question set in the dashboard for `group`, in the UI language.
    public func followUp(_ group: LerixSurveyGroup) -> String? {
        LerixUI.shared.localized(run.survey.followUp?[group.rawValue])
    }

    /// The thank-you text set in the dashboard for `group`, in the UI language.
    public func thanks(_ group: LerixSurveyGroup) -> String? {
        LerixUI.shared.localized(run.survey.thanks?[group.rawValue])
    }

    /// Records that the survey is on screen. Call once when you show it.
    public func shown() { run.shown() }

    /// Records an NPS score 0–10, or the rating choice with this `value`.
    /// Call again with the same answer and a `message` to add the follow-up
    /// text. Returns `false` when the answer doesn't fit the survey.
    @discardableResult
    public func answer(_ value: Int, message: String? = nil) -> Bool {
        run.answer(.value(value), message: message)
    }

    /// Records the rating choice with this `id` (or a value as text).
    /// Call again with the same answer and a `message` to add the follow-up
    /// text. Returns `false` when the answer doesn't fit the survey.
    @discardableResult
    public func answer(_ choiceId: String, message: String? = nil) -> Bool {
        run.answer(.text(choiceId), message: message)
    }

    /// Records that the survey was closed without an answer. Ignored after an answer.
    public func dismiss() { run.dismiss() }
}

/// One showing of one survey: a client id and the reports it makes
/// ("shown", then "answered" or "dismissed", plus the follow-up message), all
/// merged server-side on the client id. The built-in sheet and the headless
/// prompt both go through it, so they record exactly the same thing.
final class LerixSurveyRun: @unchecked Sendable {
    enum Answer: CustomStringConvertible {
        case value(Int)
        case text(String)

        var description: String {
            switch self {
            case .value(let value): return "\(value)"
            case .text(let text): return "\"\(text)\""
            }
        }
    }

    struct Answered: Equatable {
        var at: Date
        var score: Int
        var choice: String?
    }

    let survey: LerixSurvey
    let clientId = LerixIds.make()
    let choices: [LerixSurveyChoice]
    private let owner: LerixSurveys
    private let custom: [String: Any]?
    private let lock = NSLock()
    private var shownAt: Date
    private var isShown = false
    private var answered: Answered?
    private var dismissed = false

    init(owner: LerixSurveys, survey: LerixSurvey, custom: [String: Any]?) {
        self.owner = owner
        self.survey = survey
        self.custom = LerixFeedback.sanitizeCustom(custom)
        shownAt = owner.now()
        choices = survey.options.map { $0.localized() }
    }

    var isAnswered: Bool { lock.lock(); defer { lock.unlock() }; return answered != nil }

    func shown() {
        lock.lock()
        guard !isShown else { lock.unlock(); return }
        isShown = true
        shownAt = owner.now()
        let at = shownAt
        lock.unlock()
        owner.store.setDate(LerixStoreKey.survey(survey.id, "lastShownAt"), at)
        enqueue(answered: nil, dismissedAt: nil, message: nil)
        var data: [String: Any] = ["surveyId": survey.id]
        if let key = survey.key { data["key"] = key }
        LerixBreadcrumbs.shared.add(survey.isRating ? "Rating survey shown" : "NPS survey shown", category: .ui, data: data)
    }

    /// The score (and rating choice id) for an answer, or `nil` when it doesn't fit.
    func fields(_ answer: Answer) -> (score: Int, choice: String?)? {
        if survey.isRating {
            let choice: LerixSurveyChoice?
            switch answer {
            case .value(let value): choice = lerixFindChoice(choices, value)
            case .text(let text): choice = lerixFindChoice(choices, text)
            }
            return choice.map { ($0.value, $0.id) }
        }
        let score: Int?
        switch answer {
        case .value(let value): score = value
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            score = Double(trimmed).flatMap { $0.rounded() == $0 && abs($0) < 1e15 ? Int($0) : nil }
        }
        guard let score = score, (0...10).contains(score) else { return nil }
        return (score, nil)
    }

    func groupOf(_ answer: Answer) -> LerixSurveyGroup? {
        guard let fields = fields(answer) else { return nil }
        if survey.isRating { return choices.first { $0.id == fields.choice }?.group }
        return .nps(fields.score)
    }

    @discardableResult
    func answer(_ answer: Answer, message: String? = nil) -> Bool {
        guard let fields = fields(answer) else {
            LerixLog.debug("Survey answer \(answer) doesn't fit survey \(survey.id)")
            return false
        }
        shown()
        lock.lock()
        var first: Answered?
        if answered == nil {
            let made = Answered(at: owner.now(), score: fields.score, choice: fields.choice)
            answered = made
            first = made
        }
        lock.unlock()
        if let first = first {
            owner.store.setDate(LerixStoreKey.survey(survey.id, "lastAnsweredAt"), first.at)
            enqueue(answered: first, dismissedAt: nil, message: nil)
        }
        if let message = message { self.message(message) }
        return true
    }

    /// Adds the follow-up text to this showing (with the answer, if there is one).
    func message(_ message: String) {
        let text = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !text.isEmpty else { return }
        lock.lock()
        let current = answered
        lock.unlock()
        enqueue(answered: current, dismissedAt: nil, message: text)
    }

    func dismiss() {
        lock.lock()
        guard answered == nil, !dismissed else { lock.unlock(); return }
        dismissed = true
        lock.unlock()
        shown()
        let at = owner.now()
        owner.store.setDate(LerixStoreKey.survey(survey.id, "lastDismissedAt"), at)
        enqueue(answered: nil, dismissedAt: at, message: nil)
    }

    private func enqueue(answered: Answered?, dismissedAt: Date?, message: String?) {
        lock.lock()
        let shownAt = self.shownAt
        lock.unlock()
        let body = LerixSurveys.responseBody(
            surveyId: survey.id,
            clientId: clientId,
            shownAt: shownAt,
            answeredAt: answered?.at,
            dismissedAt: dismissedAt,
            score: answered?.score,
            message: message,
            choice: answered?.choice,
            custom: custom,
            maxScore: survey.isRating ? 100 : 10
        )
        owner.enqueue(body: body)
    }
}
