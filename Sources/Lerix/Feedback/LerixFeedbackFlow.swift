#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// State of one feedback flow: message → labels → screenshots (+ drawing)
/// → email → review → sending → done. Steps the settings turn off are skipped.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
final class LerixFeedbackModel: ObservableObject {
    enum Step: Equatable {
        case message, labels, screenshots, annotate(Int), email, review, sending, done
    }

    let settings: LerixFeedbackSettings
    @Published var step: Step = .message
    @Published var message = "" { didSet { onDirtyChanged(isDirty) } }
    @Published var selectedLabels: [String] = []
    @Published var email: String
    @Published var showDetails = false
    @Published private(set) var delivered = false
    #if canImport(UIKit)
    @Published var screenshots: [UIImage] = []
    #endif

    var onClose: (LerixFeedbackResult) -> Void = { _ in }
    var onAddScreenshot: () -> Void = {}
    var onDirtyChanged: (Bool) -> Void = { _ in }
    private(set) var result: LerixFeedbackResult?

    init(settings: LerixFeedbackSettings) {
        self.settings = settings
        email = settings.prefillEmail ?? ""
    }

    var isDirty: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && step != .done }

    var steps: [Step] {
        var steps: [Step] = [.message]
        if !settings.labels.isEmpty { steps.append(.labels) }
        if settings.maxScreenshots > 0 { steps.append(.screenshots) }
        if settings.emailMode != .hidden { steps.append(.email) }
        steps.append(.review)
        return steps
    }

    var progress: Double {
        let current: Step
        if case .annotate = step { current = .screenshots } else { current = step }
        guard let index = steps.firstIndex(of: current) else { return 1 }
        return Double(index + 1) / Double(steps.count + 1)
    }

    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var emailIsValid: Bool {
        if trimmedEmail.isEmpty { return settings.emailMode != .required }
        return LerixFeedback.isValidEmail(trimmedEmail)
    }

    var canAdvance: Bool {
        switch step {
        case .message: return !trimmedMessage.isEmpty && message.count <= settings.maxMessageLength
        case .email: return emailIsValid
        case .sending, .annotate: return false
        default: return true
        }
    }

    var canGoBack: Bool {
        if case .annotate = step { return true }
        guard let index = steps.firstIndex(of: step) else { return false }
        return index > 0
    }

    func next() {
        guard canAdvance else { return }
        if step == .review {
            Task { await submit() }
            return
        }
        if let index = steps.firstIndex(of: step), index + 1 < steps.count {
            step = steps[index + 1]
        }
    }

    func back() {
        if case .annotate = step { step = .screenshots; return }
        if let index = steps.firstIndex(of: step), index > 0 { step = steps[index - 1] }
    }

    func toggle(label key: String) {
        if let index = selectedLabels.firstIndex(of: key) {
            selectedLabels.remove(at: index)
        } else {
            selectedLabels.append(key)
        }
    }

    func close() {
        onClose(result ?? .cancelled)
    }

    #if canImport(UIKit)
    var canAddScreenshot: Bool { screenshots.count < settings.maxScreenshots }

    func addScreenshot(_ image: UIImage) {
        guard canAddScreenshot else { return }
        screenshots.append(image)
        step = .annotate(screenshots.count - 1)
    }
    #endif

    func submit() async {
        step = .sending
        #if canImport(UIKit)
        let shots = screenshots.compactMap(LerixScreenshot.encode)
        #else
        let shots: [LerixScreenshotData] = []
        #endif
        let feedback = LerixFeedback.shared
        let email = trimmedEmail.isEmpty ? nil : trimmedEmail
        if let email = email { feedback.setUserEmail(email) }
        guard let item = feedback.enqueue(
            message: String(trimmedMessage.prefix(settings.maxMessageLength)),
            labels: selectedLabels,
            email: email,
            screenshots: shots,
            custom: settings.custom
        ) else {
            result = .cancelled
            step = .done
            return
        }
        let id = await feedback.outbox.deliverFeedbackNow(itemId: item.id)
        delivered = id != nil
        result = LerixFeedbackResult(submitted: true, id: id, clientId: item.payload["clientId"]?.stringValue)
        step = .done
        onDirtyChanged(false)
    }

    /// Rows for "Show details": what is sent besides the message.
    var detailRows: [(String, String)] {
        let ui = LerixUI.shared
        let app = LerixDeviceInfo.collectApp()
        let device = LerixFeedback.deviceInfo()
        var rows: [(String, String)] = [
            (ui.string("details.platform"), LerixPlatform.value),
            (ui.string("details.device"), device["model"] as? String ?? ""),
            (ui.string("details.os"), "\(LerixPlatform.osName) \(LerixPlatform.osVersion)"),
            (ui.string("details.app"), "\(app.name ?? "") \(app.version ?? "") (\(app.buildNo ?? ""))"),
            (ui.string("details.locale"), LerixPlatform.locale),
            (ui.string("details.timeZone"), TimeZone.current.identifier),
            (ui.string("details.environment"), LerixKeys.shared.environment),
        ]
        if let screen = device["screen"] as? [String: Any], let w = screen["width"], let h = screen["height"] {
            rows.append((ui.string("details.screen"), "\(w)×\(h)"))
        }
        if let session = LerixAnalytics.shared.sessionId { rows.append((ui.string("details.session"), session)) }
        if !selectedLabels.isEmpty { rows.append((ui.string("details.labels"), selectedLabels.joined(separator: ", "))) }
        if !trimmedEmail.isEmpty { rows.append((ui.string("details.email"), trimmedEmail)) }
        #if canImport(UIKit)
        rows.append((ui.string("details.screenshots"), "\(screenshots.count)"))
        #endif
        let crumbs = LerixBreadcrumbs.shared.snapshot()
        if !crumbs.isEmpty {
            let recent = crumbs.suffix(5).compactMap { $0["message"] as? String }.joined(separator: "\n")
            rows.append((ui.string("details.breadcrumbs"), recent))
        }
        if let custom = LerixFeedback.sanitizeCustom(settings.custom), !custom.isEmpty {
            rows.append((ui.string("details.custom"), custom.keys.sorted().joined(separator: ", ")))
        }
        return rows
    }
}

@available(iOS 15.0, macOS 12.0, *)
struct LerixFeedbackFlowView: View {
    @ObservedObject var model: LerixFeedbackModel
    private let ui = LerixUI.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.step != .done {
                ProgressView(value: model.progress)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            content
            footer
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            if model.canGoBack && model.step != .sending && model.step != .done {
                Button {
                    model.back()
                } label: {
                    Image(systemName: ui.isRightToLeft ? "chevron.right" : "chevron.left")
                }
                .accessibilityLabel(Text(ui.string("common.back")))
            }
            Spacer()
            Text(ui.string("feedback.title")).font(.headline)
            Spacer()
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark").foregroundColor(.secondary)
            }
            .accessibilityLabel(Text(ui.string("common.close")))
            .disabled(model.step == .sending)
        }
        .padding()
    }

    @ViewBuilder
    private var footer: some View {
        switch model.step {
        case .annotate, .sending:
            EmptyView()
        case .done:
            primaryButton(ui.string("common.close")) { model.close() }
        case .review:
            primaryButton(ui.string("common.send")) { model.next() }
        default:
            primaryButton(ui.string("common.next")) { model.next() }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canAdvance && model.step != .done)
        .padding()
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .annotate(let index):
            annotate(index)
        case .sending:
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text(ui.string("feedback.sending")).foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .done:
            done
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch model.step {
                    case .message: message
                    case .labels: labels
                    case .screenshots: screenshots
                    case .email: email
                    default: review
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
        }
    }

    private var message: some View {
        Group {
            Text(ui.string("feedback.message.title")).font(.title3.bold())
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.message)
                    .frame(minHeight: 160)
                if model.message.isEmpty {
                    Text(ui.string("feedback.message.placeholder"))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.35)))
            HStack {
                Spacer()
                Text("\(model.message.count)/\(model.settings.maxMessageLength)")
                    .font(.caption)
                    .foregroundColor(model.message.count > model.settings.maxMessageLength ? .red : .secondary)
            }
        }
    }

    private var labels: some View {
        Group {
            Text(ui.string("feedback.labels.title")).font(.title3.bold())
            Text(ui.string("feedback.labels.subtitle")).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(model.settings.labels, id: \.key) { label in
                    let selected = model.selectedLabels.contains(label.key)
                    let color = Color(lerixHex: label.color) ?? LerixThemed<EmptyView>.resolvedTint()
                    Button {
                        model.toggle(label: label.key)
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text(ui.localized(label.title) ?? label.key).lineLimit(1)
                            if selected { Image(systemName: "checkmark").font(.caption.bold()) }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(selected ? color.opacity(0.18) : Color.secondary.opacity(0.08))
                        )
                        .overlay(Capsule().stroke(selected ? color : Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private var screenshots: some View {
        Text(ui.string("feedback.screenshots.title")).font(.title3.bold())
        Text(ui.string("feedback.screenshots.subtitle")).foregroundColor(.secondary)
        #if canImport(UIKit)
        if model.screenshots.isEmpty {
            Text(ui.string("feedback.screenshots.empty")).foregroundColor(.secondary).padding(.vertical)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.screenshots.indices, id: \.self) { index in
                        Button {
                            model.step = .annotate(index)
                        } label: {
                            Image(uiImage: model.screenshots[index])
                                .resizable()
                                .scaledToFit()
                                .frame(height: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                model.screenshots.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .accessibilityLabel(Text(ui.string("feedback.screenshots.remove")))
                            .padding(6)
                        }
                    }
                }
            }
        }
        if model.canAddScreenshot {
            Button {
                model.onAddScreenshot()
            } label: {
                Label(ui.string("feedback.screenshots.add"), systemImage: "camera.viewfinder")
            }
            .buttonStyle(.bordered)
        }
        #endif
    }

    @ViewBuilder
    private func annotate(_ index: Int) -> some View {
        #if canImport(UIKit)
        if model.screenshots.indices.contains(index) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ui.string("feedback.annotate.title")).font(.title3.bold())
                LerixAnnotationEditor(image: model.screenshots[index]) { flattened in
                    model.screenshots[index] = flattened
                    model.step = .screenshots
                }
            }
            .padding([.horizontal, .bottom])
        }
        #else
        EmptyView()
        #endif
    }

    private var email: some View {
        Group {
            Text(ui.string("feedback.email.title")).font(.title3.bold())
            Text(ui.string(model.settings.emailMode == .required ? "feedback.email.required" : "feedback.email.optional"))
                .foregroundColor(.secondary)
            emailField
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.35)))
            if !model.trimmedEmail.isEmpty && !model.emailIsValid {
                Text(ui.string("feedback.email.invalid")).font(.caption).foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private var emailField: some View {
        #if canImport(UIKit)
        TextField(ui.string("feedback.email.placeholder"), text: $model.email)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .environment(\.layoutDirection, .leftToRight)
        #else
        TextField(ui.string("feedback.email.placeholder"), text: $model.email)
            .textFieldStyle(.plain)
            .disableAutocorrection(true)
        #endif
    }

    private var review: some View {
        Group {
            Text(ui.string("feedback.review.title")).font(.title3.bold())
            Text(ui.string("feedback.review.subtitle")).foregroundColor(.secondary)
            Text(model.trimmedMessage)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            Button {
                withAnimation { model.showDetails.toggle() }
            } label: {
                Label(
                    ui.string(model.showDetails ? "feedback.review.hideDetails" : "feedback.review.showDetails"),
                    systemImage: model.showDetails ? "chevron.up" : "chevron.down"
                )
            }
            if model.showDetails {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.detailRows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0).font(.caption).foregroundColor(.secondary)
                            Text(row.1).font(.footnote).textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    private var done: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text(ui.string("feedback.success.title")).font(.title2.bold())
            Text(ui.string(model.delivered ? "feedback.success.sent" : "feedback.success.queued"))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

/// The floating bar shown while the user navigates to another screen.
@available(iOS 15.0, macOS 12.0, *)
struct LerixCaptureBar: View {
    let onCapture: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let ui = LerixUI.shared
        HStack(spacing: 10) {
            Text(ui.string("feedback.capture.hint"))
                .font(.footnote)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button(ui.string("common.cancel"), action: onCancel)
            Button(action: onCapture) {
                Label(ui.string("feedback.capture.button"), systemImage: "camera")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 8)
    }
}
#endif
