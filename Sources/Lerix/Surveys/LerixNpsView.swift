#if canImport(SwiftUI)
import SwiftUI

/// The NPS sheet: 0–10 score → follow-up question for the score's group →
/// thanks. The 0–10 scale always reads left to right, also in RTL. The
/// dashboard's appearance sets the button shape, the accent, colour by group
/// and the end labels.
@available(iOS 15.0, macOS 12.0, *)
struct LerixNpsView: View {
    @ObservedObject var model: LerixSurveyModel
    private let ui = LerixUI.shared

    var body: some View {
        LerixSurveyCard(model: model) {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(0...10, id: \.self) { value in
                        scoreButton(value)
                    }
                }
                if model.appearance.showLabels {
                    HStack {
                        Text(model.appearance.lowLabel ?? ui.string("nps.notLikely"))
                        Spacer()
                        Text(model.appearance.highLabel ?? ui.string("nps.veryLikely"))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    private var shape: LerixSurveyShape { LerixSurveyShape(model.appearance.shape) }

    /// `colorMode: "groups"`: the group's colour from the dashboard, else the default.
    private func groupColor(_ value: Int) -> String? {
        guard model.appearance.colorMode == "groups" else { return nil }
        let group = LerixSurveyGroup.nps(value)
        return model.appearance.groupColors[group] ?? LerixSurveyColors.groupDefaults[group]
    }

    private func scoreButton(_ value: Int) -> some View {
        let selected = model.score == value
        let tint = groupColor(value)
        let color = Color(lerixHex: tint) ?? model.accent
        let outline = LerixSurveyButtonShape(shape: shape)
        let fill: Color = selected ? color : (tint != nil ? color.opacity(0.14) : Color.secondary.opacity(0.12))
        let text: Color = selected ? color.lerixOnColor : (tint != nil ? color : .primary)
        return Button {
            model.select(score: value)
        } label: {
            Text("\(value)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: shape == .circle ? 0 : 40)
                .lerixSquare(shape == .circle)
                .background(outline.fill(fill))
                .overlay(outline.stroke(tint != nil && !selected ? color.opacity(0.45) : .clear, lineWidth: 1))
                .foregroundColor(text)
                .contentShape(outline)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ui.string("nps.score", "\(value)")))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
#endif
