#if canImport(SwiftUI)
import SwiftUI

/// Rating (CSAT) sheet: the choices in the dashboard's style → follow-up
/// question for the choice's group → thanks. Unlike the NPS scale, the row
/// follows the layout direction (mirrored in RTL).
@available(iOS 15.0, macOS 12.0, *)
struct LerixRatingView: View {
    enum Style: String { case stars, hearts, emoji, thumbs, numbers }

    @ObservedObject var model: LerixSurveyModel
    private let ui = LerixUI.shared

    var body: some View {
        LerixSurveyCard(model: model) {
            VStack(spacing: 6) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(model.choices.enumerated()), id: \.element.id) { index, choice in
                        cell(choice, index: index)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.12), value: model.choiceId)
                if let labels = scaleLabels {
                    HStack {
                        Text(labels.low ?? "")
                        Spacer()
                        Text(labels.high ?? "")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - Rules (lerix_core rating-ui.ts)

    /// `thumbs` needs exactly two choices; anything unknown falls back to `stars`.
    var style: Style {
        let requested = Style(rawValue: model.appearance.style ?? "") ?? .stars
        return requested == .thumbs && model.choices.count != 2 ? .stars : requested
    }

    private var shape: LerixSurveyShape { LerixSurveyShape(model.appearance.shape) }
    private var byOption: Bool { model.appearance.colorMode == "options" }
    private var isIcon: Bool { style == .stars || style == .hearts }
    private var pickedIndex: Int { model.choices.firstIndex { $0.id == model.choiceId } ?? -1 }

    private var spacing: CGFloat {
        switch style {
        case .stars, .hearts: return 2
        case .numbers: return 4
        case .emoji, .thumbs: return 8
        }
    }

    /// The colour for a choice: its own (colour by option), else the accent,
    /// else the style's default (stars / hearts); `nil` = the app tint.
    private func colorHex(_ choice: LerixSurveyChoice?) -> String? {
        if byOption, let own = choice?.color { return own }
        if let accent = model.appearance.accent { return accent }
        switch style {
        case .stars: return LerixSurveyColors.starFill
        case .hearts: return LerixSurveyColors.heartFill
        default: return nil
        }
    }

    private func color(_ choice: LerixSurveyChoice?) -> Color {
        Color(lerixHex: colorHex(choice)) ?? model.accent
    }

    /// Stars, hearts and numbers get a low / high line: the appearance's labels, else the end choices' labels.
    private var scaleLabels: (low: String?, high: String?)? {
        guard model.appearance.showLabels, isIcon || style == .numbers else { return nil }
        let low = model.appearance.lowLabel ?? model.choices.first?.label
        let high = model.appearance.highLabel ?? model.choices.last?.label
        return low == nil && high == nil ? nil : (low, high)
    }

    private func accessibilityName(_ choice: LerixSurveyChoice, index: Int) -> String {
        if isIcon {
            let position = ui.string("rating.icon", "\(index + 1)", "\(model.choices.count)")
            return [position, choice.label].compactMap { $0 }.joined(separator: ", ")
        }
        return choice.label ?? ui.string("rating.choice", "\(choice.value)")
    }

    // MARK: - Cells

    @ViewBuilder
    private func cell(_ choice: LerixSurveyChoice, index: Int) -> some View {
        let showLabel = model.appearance.showLabels && (style == .emoji || style == .thumbs) && choice.label != nil
        if showLabel {
            VStack(spacing: 4) {
                button(choice, index: index)
                Text(choice.label ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: 76)
        } else {
            button(choice, index: index)
        }
    }

    private func button(_ choice: LerixSurveyChoice, index: Int) -> some View {
        let selected = model.choiceId == choice.id
        return Button {
            model.select(choice: choice)
        } label: {
            content(choice, index: index, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityName(choice, index: index)))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func content(_ choice: LerixSurveyChoice, index: Int, selected: Bool) -> some View {
        switch style {
        case .stars, .hearts:
            // Fill up to the picked one, in that one's colour.
            let on = pickedIndex >= 0 && index <= pickedIndex
            let fill = color(pickedIndex >= 0 ? model.choices[pickedIndex] : nil)
            let symbol = style == .stars ? "star" : "heart"
            Image(systemName: on ? "\(symbol).fill" : symbol)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 30, maxHeight: 30)
                .foregroundColor(on ? fill : .secondary)
                .frame(maxWidth: 40, minHeight: 40)
                .contentShape(Rectangle())
                .scaleEffect(selected ? 1.08 : 1)
        case .emoji:
            let outline = LerixSurveyButtonShape(shape: shape, radius: 10)
            Text(choice.emoji ?? "\(choice.value)")
                .font(.system(size: 28))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: 48, maxHeight: 48)
                .aspectRatio(1, contentMode: .fit)
                .background(outline.fill(Color.secondary.opacity(0.12)))
                .overlay(outline.stroke(selected ? color(choice) : .clear, lineWidth: 2).padding(-2))
                .opacity(selected ? 1 : 0.6)
                .scaleEffect(selected ? 1.12 : 1)
                .contentShape(outline)
        case .thumbs:
            let outline = LerixSurveyButtonShape(shape: shape, radius: 10)
            let tint = color(choice)
            Image(systemName: choice.group == .negative ? "hand.thumbsdown.fill" : "hand.thumbsup.fill")
                .font(.system(size: 22))
                .foregroundColor(selected ? tint.lerixOnColor : .secondary)
                .frame(width: 56, height: 44)
                .background(outline.fill(selected ? tint : .clear))
                .overlay(outline.stroke(selected ? tint : Color.secondary.opacity(0.35), lineWidth: 1))
                .contentShape(outline)
        case .numbers:
            let outline = LerixSurveyButtonShape(shape: shape)
            let tinted = byOption && choice.color != nil
            let tint = color(choice)
            let fill: Color = selected ? tint : (tinted ? tint.opacity(0.14) : Color.secondary.opacity(0.12))
            Text("\(choice.value)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: shape == .circle ? 40 : .infinity, minHeight: shape == .circle ? 0 : 40)
                .lerixSquare(shape == .circle)
                .background(outline.fill(fill))
                .overlay(outline.stroke(tinted && !selected ? tint.opacity(0.45) : .clear, lineWidth: 1))
                .foregroundColor(selected ? tint.lerixOnColor : (tinted ? tint : .primary))
                .contentShape(outline)
        }
    }
}
#endif
