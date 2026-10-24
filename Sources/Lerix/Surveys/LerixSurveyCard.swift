#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// State of one built-in survey sheet (NPS or rating): choose → follow-up
/// question for the answer's group → thanks (closes itself). Every report
/// goes through the showing's `LerixSurveyRun`, like the headless prompt.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
final class LerixSurveyModel: ObservableObject {
    enum Step { case choose, followUp, thanks }

    let run: LerixSurveyRun
    let appearance: LerixSurveyAppearance
    @Published var step: Step = .choose
    @Published private(set) var group: LerixSurveyGroup?
    /// NPS: the picked score.
    @Published private(set) var score: Int?
    /// Rating: the picked choice id.
    @Published private(set) var choiceId: String?
    @Published var message = ""

    var onClose: () -> Void = {}
    private let ui = LerixUI.shared

    init(run: LerixSurveyRun) {
        self.run = run
        appearance = run.survey.appearance.localized()
    }

    var survey: LerixSurvey { run.survey }
    var choices: [LerixSurveyChoice] { run.choices }
    private var prefix: String { survey.isRating ? "rating" : "nps" }

    /// The survey accent (`#RRGGBB`) beats `LerixUI.tintColor` / the app tint.
    var accent: Color { Color(lerixHex: appearance.accent) ?? LerixThemed<EmptyView>.resolvedTint() }

    var question: String {
        ui.localized(survey.question) ?? ui.string("\(prefix).question")
    }

    var dismissLabel: String { ui.string("\(prefix).dismiss") }

    var followUpText: String {
        let group = self.group ?? (survey.isRating ? .neutral : .passive)
        if let text = ui.localized(survey.followUp?[group.rawValue]) { return text }
        return survey.isRating ? ui.string("rating.followUp") : ui.string("nps.followUp.\(group.rawValue)")
    }

    var thanksText: String {
        let group = self.group ?? (survey.isRating ? .neutral : .passive)
        if let text = ui.localized(survey.thanks?[group.rawValue]) { return text }
        return survey.isRating ? ui.string("rating.thanks") : ui.string("nps.thanks.\(group.rawValue)")
    }

    func select(score value: Int) {
        guard group == nil, run.answer(.value(value)) else { return }
        // Recorded right away, so the answer survives a dismissed follow-up.
        score = value
        group = .nps(value)
        advanceAfterPick()
    }

    func select(choice: LerixSurveyChoice) {
        guard group == nil, run.answer(.text(choice.id)) else { return }
        choiceId = choice.id
        group = choice.group
        advanceAfterPick()
    }

    /// Leaves the picked choice on screen for a moment (there is no hover
    /// feedback on touch), then moves on to the follow-up.
    private func advanceAfterPick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.step == .choose else { return }
            self.step = .followUp
        }
    }

    func finishFollowUp(send: Bool) {
        if send { run.message(message) }
        step = .thanks
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.onClose()
        }
    }
}

/// The sheet layout shared by NPS and rating: a close button, then the
/// step. `choices` is the answer step under the question.
@available(iOS 15.0, macOS 12.0, *)
struct LerixSurveyCard<Choices: View>: View {
    @ObservedObject var model: LerixSurveyModel
    let choices: Choices
    private let ui = LerixUI.shared

    init(model: LerixSurveyModel, @ViewBuilder choices: () -> Choices) {
        self.model = model
        self.choices = choices()
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button {
                    model.onClose()
                } label: {
                    Image(systemName: "xmark").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(model.step == .thanks ? ui.string("common.close") : model.dismissLabel))
            }
            switch model.step {
            case .choose: chooseStep
            case .followUp: followUpStep
            case .thanks: thanksStep
            }
            Spacer(minLength: 0)
        }
        .padding()
        .tint(model.accent)
        .accentColor(model.accent)
    }

    private var chooseStep: some View {
        VStack(spacing: 14) {
            Text(model.question)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            choices
        }
    }

    private var followUpStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.followUpText).font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.message)
                    .frame(minHeight: 100)
                    .accessibilityLabel(Text(model.followUpText))
                if model.message.isEmpty {
                    Text(ui.string("nps.followUp.placeholder"))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.35)))
            HStack {
                Button(ui.string("common.skip")) { model.finishFollowUp(send: false) }
                Spacer()
                Button(ui.string("common.send")) { model.finishFollowUp(send: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var thanksStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(model.accent)
                .accessibilityHidden(true)
            Text(model.thanksText)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

/// Presents the NPS or rating sheet (medium detent on iOS), one at a time,
/// and records shown / dismissed through the showing's run.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
enum LerixSurveyPresenter {
    private static var active: (sheet: LerixSheetController, model: LerixSurveyModel)?

    static func present(run: LerixSurveyRun, from presenter: LerixSurveys.Presenter?) -> Bool {
        guard active == nil else {
            LerixLog.debug("A survey is already showing")
            return false
        }
        let sheet = LerixSheetController()
        let model = LerixSurveyModel(run: run)

        // `dismiss()` is ignored once the survey is answered.
        model.onClose = { [weak model] in
            guard let model = model, active?.model === model else { return }
            run.dismiss()
            sheet.dismiss()
            active = nil
        }
        sheet.onInteractiveDismiss = { [weak model] in
            guard let model = model, active?.model === model else { return }
            run.dismiss()
            active = nil
        }

        let view: AnyView = run.survey.isRating ? AnyView(LerixRatingView(model: model)) : AnyView(LerixNpsView(model: model))
        guard sheet.present(view, from: presenter, mediumDetent: true) else {
            LerixLog.debug("Surveys: no view controller to present from")
            return false
        }
        active = (sheet, model)
        run.shown()
        return true
    }
}
#endif
