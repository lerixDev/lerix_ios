import Foundation
#if canImport(UIKit)
import UIKit
#if canImport(SwiftUI)
import SwiftUI
#endif
#elseif canImport(AppKit)
import AppKit
#if canImport(SwiftUI)
import SwiftUI
#endif
#endif

/// What a full-screen Release Control screen shows.
enum LerixBlockingContent: Equatable {
    case maintenance(LerixMaintenance)
    case requiredUpdate(LerixAppUpdate)

    var title: String {
        switch self {
        case .maintenance(let m): return m.title
        case .requiredUpdate(let u): return u.title
        }
    }

    var message: String {
        switch self {
        case .maintenance(let m): return m.message
        case .requiredUpdate(let u): return u.message
        }
    }

    var notes: String? {
        if case .requiredUpdate(let u) = self { return u.releaseNotes }
        return nil
    }

    /// "Expected back at {local time}" when the window asks for it.
    var eta: String? {
        guard case .maintenance(let m) = self, m.showEndsAt else { return nil }
        return LerixUI.shared.string("appControl.expectedBack", LerixAppControlText.time(m.endsAt))
    }

    /// The button title, or `nil` to hide the button (no store link).
    var buttonTitle: String? {
        switch self {
        case .maintenance: return LerixUI.shared.string("appControl.tryAgain")
        case .requiredUpdate(let u): return u.storeUrl == nil ? nil : LerixUI.shared.string("appControl.update")
        }
    }
}

enum LerixAppControlText {
    /// Local time in the UI language; the date too when it isn't today.
    static func time(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: LerixAppControl.requestLocale())
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDate(date, inSameDayAs: now) ? .none : .medium
        return formatter.string(from: date)
    }

    static func body(message: String, notes: String?) -> String {
        guard let notes = notes, !notes.isEmpty else { return message }
        return "\(message)\n\n\(notes)"
    }

    /// For system dialogs (UIAlertController / NSAlert), whose paragraph direction follows the UI
    /// language: wraps each line in a first-strong isolate (U+2068 … U+2069) so Arabic copy on an
    /// English device (or the reverse) keeps its punctuation on the right side.
    static func isolated(_ text: String?) -> String? {
        guard let text = text, !text.isEmpty else { return text }
        return text
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? $0 : "\u{2068}\($0)\u{2069}" }
            .joined(separator: "\n")
    }
}

#if canImport(UIKit)

/// iOS: the maintenance and required-update screens live in the SDK's own
/// `UIWindow` at `.alert + 1` (iOS 13+, UIKit only), so they cover every
/// sheet and alert of the app. The soft update is a `UIAlertController`.
final class LerixAppControlUI: LerixAppControlPresenting {
    private weak var control: LerixAppControl?
    private var window: LerixOverlayWindow?
    private weak var previousKeyWindow: UIWindow?
    private var controller: LerixBlockingViewController?
    private var shownContent: LerixBlockingContent?
    private weak var alert: UIAlertController?
    private var alertUpdate: LerixAppUpdate?
    private var retry: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    init(control: LerixAppControl) {
        self.control = control
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, let control = self.control else { return }
            self.render(control.state)
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    func render(_ state: LerixAppControlState) {
        guard control?.usesBuiltInUI == true else { hideBlocking(); dismissAlert(); return }
        switch state.screen {
        case .maintenance(let m):
            dismissAlert()
            showBlocking(.maintenance(m))
        case .requiredUpdate(let u):
            dismissAlert()
            showBlocking(.requiredUpdate(u))
        case .softUpdate(let u):
            hideBlocking()
            showSoftPrompt(u)
        case .none:
            hideBlocking()
            dismissAlert()
        }
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.retry = nil
            if let control = self.control { self.render(control.state) }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Blocking screen

    private func showBlocking(_ content: LerixBlockingContent) {
        if let controller = controller, window != nil {
            if shownContent != content {
                controller.configure(content)
                trackShown(content, previous: shownContent)
                shownContent = content
            }
            return
        }
        guard let scene = Self.scene() else { scheduleRetry(); return }
        let controller = LerixBlockingViewController()
        controller.onButton = { [weak self, weak controller] in
            guard let self = self, let control = self.control, let content = self.shownContent else { return }
            switch content {
            case .maintenance:
                controller?.setBusy(true)
                control.refresh { _ in controller?.setBusy(false) }
            case .requiredUpdate:
                control.openStore()
            }
        }
        controller.configure(content)
        let window = LerixOverlayWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = controller
        previousKeyWindow = LerixScreenshot.keyWindow()
        window.makeKeyAndVisible()
        self.window = window
        self.controller = controller
        trackShown(content, previous: shownContent)
        shownContent = content
        UIAccessibility.post(notification: .screenChanged, argument: controller.view)
    }

    private func trackShown(_ content: LerixBlockingContent, previous: LerixBlockingContent?) {
        guard case .requiredUpdate(let update) = content else { return }
        if case .requiredUpdate(let old)? = previous, old.ruleId == update.ruleId { return }
        control?.updatePromptShown(update)
    }

    private func hideBlocking() {
        guard let window = window else { return }
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
        controller = nil
        shownContent = nil
        previousKeyWindow?.makeKey()
    }

    static func scene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }

    // MARK: Soft update dialog

    private func showSoftPrompt(_ update: LerixAppUpdate) {
        if alert != nil { return }
        guard let control = control, control.canShowSoftPrompt() else { return }
        // Not before the app's first screen is up and active.
        guard UIApplication.shared.applicationState == .active,
              let window = LerixScreenshot.keyWindow(), window.rootViewController?.viewIfLoaded?.window != nil,
              let top = LerixScreenshot.topViewController(), !top.isBeingPresented, !top.isBeingDismissed,
              top.presentedViewController == nil || top.presentedViewController?.isBeingDismissed == false else {
            scheduleRetry()
            return
        }
        let ui = LerixUI.shared
        let alert = UIAlertController(
            title: LerixAppControlText.isolated(update.title),
            message: LerixAppControlText.isolated(LerixAppControlText.body(message: update.message, notes: update.releaseNotes)),
            preferredStyle: .alert
        )
        if update.storeUrl != nil {
            let action = UIAlertAction(title: ui.string("appControl.update"), style: .default) { [weak control] _ in
                control?.openStore()
            }
            alert.addAction(action)
            alert.preferredAction = action
        }
        alert.addAction(UIAlertAction(title: ui.string("appControl.later"), style: .cancel) { [weak control] _ in
            control?.later()
        })
        if update.allowSkip && update.state == .available {
            alert.addAction(UIAlertAction(title: ui.string("appControl.skip"), style: .default) { [weak control] _ in
                control?.skip()
            })
        }
        top.present(alert, animated: true)
        guard alert.presentingViewController != nil else { scheduleRetry(); return }
        self.alert = alert
        alertUpdate = update
        control.updatePromptShown(update)
    }

    private func dismissAlert() {
        guard let alert = alert else { return }
        self.alert = nil
        alertUpdate = nil
        if alert.presentingViewController != nil { alert.dismiss(animated: false) }
    }
}

/// The full-screen maintenance / required-update screen (UIKit, iOS 13+).
final class LerixBlockingViewController: UIViewController {
    var onButton: () -> Void = {}

    private let titleLabel = UILabel()
    /// TextKit 1: TextKit 2's lazy layout can leave the last lines undrawn after the screen is
    /// re-laid out (e.g. coming back from the App Store), even though the view is tall enough.
    private let textView: UITextView = {
        if #available(iOS 16.0, *) { return UITextView(usingTextLayoutManager: false) }
        return UITextView()
    }()
    private let etaLabel = UILabel()
    private let button = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var content: LerixBlockingContent?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true

        titleLabel.font = UIFont.preferredFont(forTextStyle: .title2).withWeight(.bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true

        etaLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        etaLabel.adjustsFontForContentSizeCategory = true
        etaLabel.textColor = .secondaryLabel
        etaLabel.numberOfLines = 0
        etaLabel.textAlignment = .center

        let tint = Self.tint()
        button.backgroundColor = tint
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(UIColor.white.withAlphaComponent(0.6), for: .disabled)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.layer.cornerRadius = 12
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        spinner.color = .white
        spinner.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, textView, etaLabel, button])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(24, after: etaLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(spinner)

        let guide = view.safeAreaLayoutGuide
        let width = stack.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -48)
        width.priority = .defaultHigh
        let textHeight = textView.heightAnchor.constraint(equalToConstant: 80)
        textHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            stack.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, constant: -48),
            width,
            stack.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -24),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            textHeight,
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
        ])
        if let content = content { apply(content) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Grow the text with its content, scroll when it doesn't fit.
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        if let constraint = textView.constraints.first(where: { $0.firstAttribute == .height && $0.priority == .defaultLow }),
           abs(constraint.constant - fitting) > 1 {
            constraint.constant = fitting
            // Decide scrolling after the new height is laid out, not against the old bounds.
            view.setNeedsLayout()
            return
        }
        let scroll = fitting > textView.bounds.height + 1
        if textView.isScrollEnabled != scroll { textView.isScrollEnabled = scroll }
        // A layout pass that briefly made the text scroll can leave it offset once it fits again.
        if !scroll, textView.contentOffset != .zero { textView.setContentOffset(.zero, animated: false) }
    }

    func configure(_ content: LerixBlockingContent) {
        self.content = content
        if isViewLoaded { apply(content) }
    }

    func setBusy(_ busy: Bool) {
        button.isEnabled = !busy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func apply(_ content: LerixBlockingContent) {
        let ui = LerixUI.shared
        let rtl = ui.isRightToLeft
        let direction: UISemanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        view.semanticContentAttribute = direction
        for sub in [titleLabel, textView, etaLabel, button] as [UIView] { sub.semanticContentAttribute = direction }

        titleLabel.text = content.title

        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.baseWritingDirection = .natural // server copy: direction from its own text
        let text = NSMutableAttributedString(string: content.message, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label,
            .paragraphStyle: centered,
        ])
        if let notes = content.notes, !notes.isEmpty {
            let natural = NSMutableParagraphStyle()
            natural.alignment = .natural
            natural.baseWritingDirection = .natural
            text.append(NSAttributedString(string: "\n\n" + notes, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .callout),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: natural,
            ]))
        }
        textView.attributedText = text

        etaLabel.text = content.eta
        etaLabel.isHidden = content.eta == nil
        if let title = content.buttonTitle {
            button.setTitle(title, for: .normal)
            button.isHidden = false
        } else {
            button.isHidden = true
        }
        view.setNeedsLayout()
    }

    @objc private func tapped() { onButton() }

    static func tint() -> UIColor {
        #if canImport(SwiftUI)
        if #available(iOS 14.0, *), let tint = LerixUI.shared.tintColor { return UIColor(tint) }
        #endif
        if let window = LerixScreenshot.keyWindow(), let tint = window.tintColor as UIColor? { return tint }
        return .systemBlue
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

#elseif canImport(AppKit)

/// macOS: the maintenance and required-update screens are an opaque overlay
/// view on top of every visible app window that swallows mouse and key
/// events (AppKit, macOS 11+). The menu bar stays usable (e.g. Quit). The
/// soft update is an `NSAlert` sheet on the key window.
final class LerixAppControlUI: LerixAppControlPresenting {
    private weak var control: LerixAppControl?
    private var overlays: [ObjectIdentifier: (window: NSWindow, view: LerixBlockingOverlayView)] = [:]
    private var content: LerixBlockingContent?
    private var alertWindow: NSWindow?
    private var retry: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(control: LerixAppControl) {
        self.control = control
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self = self, let control = self.control else { return }
                self.render(control.state)
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func render(_ state: LerixAppControlState) {
        guard control?.usesBuiltInUI == true else { hideBlocking(); return }
        switch state.screen {
        case .maintenance(let m): dismissAlert(); showBlocking(.maintenance(m))
        case .requiredUpdate(let u): dismissAlert(); showBlocking(.requiredUpdate(u))
        case .softUpdate(let u): hideBlocking(); showSoftPrompt(u)
        case .none: hideBlocking(); dismissAlert()
        }
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.retry = nil
            if let control = self.control { self.render(control.state) }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private static func coverableWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil && $0.level == .normal }
    }

    private func showBlocking(_ newContent: LerixBlockingContent) {
        let previous = content
        content = newContent
        // Drop overlays of closed windows.
        overlays = overlays.filter { $0.value.window.isVisible }
        let windows = Self.coverableWindows()
        if windows.isEmpty { scheduleRetry() }
        for window in windows {
            let id = ObjectIdentifier(window)
            if let existing = overlays[id] {
                if previous != newContent { existing.view.configure(newContent) }
                continue
            }
            guard let host = window.contentView else { continue }
            let overlay = LerixBlockingOverlayView(frame: host.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.onButton = { [weak self, weak overlay] in self?.buttonTapped(overlay) }
            overlay.configure(newContent)
            host.addSubview(overlay, positioned: .above, relativeTo: nil)
            window.makeFirstResponder(overlay)
            overlays[id] = (window, overlay)
        }
        if case .requiredUpdate(let update) = newContent {
            var isNew = true
            if case .requiredUpdate(let old)? = previous, old.ruleId == update.ruleId { isNew = false }
            if isNew && !windows.isEmpty { control?.updatePromptShown(update) }
        }
    }

    private func buttonTapped(_ overlay: LerixBlockingOverlayView?) {
        guard let control = control, let content = content else { return }
        switch content {
        case .maintenance:
            overlays.values.forEach { $0.view.setBusy(true) }
            control.refresh { [weak self] _ in self?.overlays.values.forEach { $0.view.setBusy(false) } }
        case .requiredUpdate:
            control.openStore()
        }
    }

    private func hideBlocking() {
        for entry in overlays.values { entry.view.removeFromSuperview() }
        overlays = [:]
        content = nil
    }

    private func showSoftPrompt(_ update: LerixAppUpdate) {
        guard alertWindow == nil, let control = control, control.canShowSoftPrompt() else { return }
        guard NSApp.isActive, let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil else {
            scheduleRetry()
            return
        }
        let ui = LerixUI.shared
        let alert = NSAlert()
        alert.messageText = LerixAppControlText.isolated(update.title) ?? ""
        alert.informativeText = LerixAppControlText.isolated(LerixAppControlText.body(message: update.message, notes: update.releaseNotes)) ?? ""
        var actions: [() -> Void] = []
        if update.storeUrl != nil {
            alert.addButton(withTitle: ui.string("appControl.update"))
            actions.append { [weak control] in control?.openStore() }
        }
        alert.addButton(withTitle: ui.string("appControl.later"))
        actions.append { [weak control] in control?.later() }
        if update.allowSkip && update.state == .available {
            alert.addButton(withTitle: ui.string("appControl.skip"))
            actions.append { [weak control] in control?.skip() }
        }
        alertWindow = alert.window
        control.updatePromptShown(update)
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.alertWindow = nil
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if index >= 0, index < actions.count { actions[index]() }
        }
    }

    private func dismissAlert() {
        guard let sheet = alertWindow else { return }
        alertWindow = nil
        sheet.sheetParent?.endSheet(sheet, returnCode: .abort)
    }
}

/// Opaque full-size view that takes every click and key press of its window.
final class LerixBlockingOverlayView: NSView {
    var onButton: () -> Void = {}

    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let etaField = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityRole(.group)
        setAccessibilityModal(true)

        titleField.font = .boldSystemFont(ofSize: 22)
        titleField.alignment = .center
        titleField.isSelectable = false

        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        etaField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        etaField.textColor = .secondaryLabelColor
        etaField.alignment = .center

        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.controlSize = .large
        button.target = self
        button.action = #selector(tapped)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let buttonRow = NSStackView(views: [spinner, button])
        buttonRow.orientation = .horizontal
        let stack = NSStackView(views: [titleField, scrollView, etaField, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 440),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 32),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -32),
            titleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            etaField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ content: LerixBlockingContent) {
        let ui = LerixUI.shared
        let rtl = ui.isRightToLeft
        userInterfaceLayoutDirection = rtl ? .rightToLeft : .leftToRight
        titleField.stringValue = content.title

        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.baseWritingDirection = .natural // server copy: direction from its own text
        let text = NSMutableAttributedString(string: content.message, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ])
        if let notes = content.notes, !notes.isEmpty {
            let natural = NSMutableParagraphStyle()
            natural.alignment = .natural
            natural.baseWritingDirection = .natural
            text.append(NSAttributedString(string: "\n\n" + notes, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: natural,
            ]))
        }
        textView.textStorage?.setAttributedString(text)
        if let container = textView.textContainer, let manager = textView.layoutManager {
            manager.ensureLayout(for: container)
            let height = manager.usedRect(for: container).height
            scrollView.constraints.filter { $0.identifier == "lerix.height" }.forEach { $0.isActive = false }
            let constraint = scrollView.heightAnchor.constraint(equalToConstant: min(max(height, 60), 320))
            constraint.identifier = "lerix.height"
            constraint.priority = .defaultHigh
            constraint.isActive = true
        }

        etaField.stringValue = content.eta ?? ""
        etaField.isHidden = content.eta == nil
        if let title = content.buttonTitle {
            button.title = title
            button.isHidden = false
        } else {
            button.isHidden = true
        }
    }

    func setBusy(_ busy: Bool) {
        button.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func tapped() { onButton() }

    // Swallow everything that would reach the app underneath.
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) ?? self }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, !button.isHidden { button.performClick(nil) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

#endif
