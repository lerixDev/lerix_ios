#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@available(iOS 15.0, macOS 12.0, *)
@MainActor
final class LerixNpsModel: ObservableObject {
    enum Step { case score, followUp, thanks }

    let survey: LerixSurvey
    @Published var step: Step = .score
    @Published private(set) var score: Int?
    @Published var message = ""

    var onScore: (Int) -> Void = { _ in }
    var onMessage: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

    init(survey: LerixSurvey) {
        self.survey = survey
    }

    /// detractor 0–6, passive 7–8, promoter 9–10.
    var group: String {
        guard let score = score else { return "passive" }
        if score <= 6 { return "detractor" }
        return score <= 8 ? "passive" : "promoter"
    }

    var question: String {
        LerixUI.shared.localized(survey.question) ?? LerixUI.shared.string("nps.question")
    }

    var followUpText: String {
        LerixUI.shared.localized(survey.followUp?[group]) ?? LerixUI.shared.string("nps.followUp.\(group)")
    }

    var thanksText: String {
        LerixUI.shared.localized(survey.thanks?[group]) ?? LerixUI.shared.string("nps.thanks.\(group)")
    }

    func select(_ value: Int) {
        guard score == nil else { return }
        score = value
        // Recorded right away, so the score survives a dismissed follow-up.
        onScore(value)
        step = .followUp
    }

    func finishFollowUp(send: Bool) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if send, !trimmed.isEmpty { onMessage(String(trimmed.prefix(2000))) }
        step = .thanks
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.onClose()
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
struct LerixNpsView: View {
    @ObservedObject var model: LerixNpsModel
    private let ui = LerixUI.shared

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
                .accessibilityLabel(Text(ui.string("common.close")))
            }
            switch model.step {
            case .score: scoreStep
            case .followUp: followUpStep
            case .thanks: thanksStep
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var scoreStep: some View {
        VStack(spacing: 14) {
            Text(model.question)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(0...10, id: \.self) { value in
                    Button {
                        model.select(value)
                    } label: {
                        Text("\(value)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(model.score == value ? Color.accentColor : Color.secondary.opacity(0.12))
                            )
                            .foregroundColor(model.score == value ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(ui.string("nps.score", "\(value)")))
                }
            }
            HStack {
                Text(ui.string("nps.notLikely"))
                Spacer()
                Text(ui.string("nps.veryLikely"))
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var followUpStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.followUpText).font(.title3.bold())
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.message)
                    .frame(minHeight: 100)
                if model.message.isEmpty {
                    Text(ui.string("nps.followUp.placeholder"))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
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
                .foregroundColor(.accentColor)
            Text(model.thanksText)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

/// Presents the NPS sheet (medium detent on iOS) and records shown /
/// answered / dismissed.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
enum LerixNpsPresenter {
    private static var active: (sheet: LerixSheetController, model: LerixNpsModel)?

    static func present(survey: LerixSurvey, surveys: LerixSurveys, from presenter: LerixSurveys.Presenter?) -> Bool {
        guard active == nil else {
            LerixLog.debug("NPS is already showing")
            return false
        }
        let sheet = LerixSheetController()
        let model = LerixNpsModel(survey: survey)
        let clientId = LerixIds.make()
        let shownAt = surveys.now()

        model.onScore = { score in
            surveys.recordAnswer(survey: survey, clientId: clientId, shownAt: shownAt, score: score, message: nil)
        }
        model.onMessage = { [weak model] message in
            guard let score = model?.score else { return }
            surveys.recordAnswer(survey: survey, clientId: clientId, shownAt: shownAt, score: score, message: message)
        }
        model.onClose = { [weak model] in
            guard active?.model === model else { return }
            if model?.score == nil { surveys.recordDismiss(survey: survey, clientId: clientId, shownAt: shownAt) }
            sheet.dismiss()
            active = nil
        }
        sheet.onInteractiveDismiss = { [weak model] in
            guard active?.model === model else { return }
            if model?.score == nil { surveys.recordDismiss(survey: survey, clientId: clientId, shownAt: shownAt) }
            active = nil
        }

        guard sheet.present(LerixNpsView(model: model), from: presenter, mediumDetent: true) else {
            LerixLog.debug("NPS: no view controller to present from")
            return false
        }
        active = (sheet, model)
        surveys.recordShown(survey: survey, clientId: clientId, shownAt: shownAt)
        return true
    }
}
#endif
