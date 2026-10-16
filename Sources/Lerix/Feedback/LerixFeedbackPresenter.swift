#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
import ObjectiveC
#elseif canImport(AppKit)
import AppKit
#endif

/// Runs one feedback flow: captures the screen first (iOS), presents the
/// sheet, handles "add another screenshot" (dismiss, let the user navigate,
/// capture, re-present) and reports the result once.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
final class LerixFeedbackPresenter {
    private(set) static var current: LerixFeedbackPresenter?

    private let model: LerixFeedbackModel
    private let sheet = LerixSheetController()
    private var completion: ((LerixFeedbackResult) -> Void)?
    #if canImport(UIKit)
    private var overlay: UIWindow?
    #endif

    private init(model: LerixFeedbackModel, completion: ((LerixFeedbackResult) -> Void)?) {
        self.model = model
        self.completion = completion
    }

    #if canImport(UIKit)
    typealias Presenter = UIViewController
    #else
    typealias Presenter = NSViewController
    #endif

    static func start(from presenter: Presenter?, options: LerixFeedbackOptions, completion: ((LerixFeedbackResult) -> Void)?) async {
        guard current == nil else {
            LerixLog.debug("Feedback is already showing")
            completion?(.cancelled)
            return
        }
        let feedback = LerixFeedback.shared
        let config = await feedback.config()
        guard config.enabled else {
            LerixLog.debug("Feedback is disabled in the dashboard")
            completion?(.cancelled)
            return
        }
        var settings = LerixFeedbackSettings(config: config, options: options, storedEmail: feedback.userEmail)
        #if !canImport(UIKit)
        settings.maxScreenshots = 0 // no screen capture on macOS
        #endif
        let model = LerixFeedbackModel(settings: settings)
        #if canImport(UIKit)
        // Capture what the user is looking at *before* the sheet covers it.
        if settings.maxScreenshots > 0, let window = LerixScreenshot.keyWindow(), let image = LerixScreenshot.capture(window) {
            model.screenshots = [image]
        }
        #endif

        let flow = LerixFeedbackPresenter(model: model, completion: completion)
        current = flow
        flow.wire()
        if !flow.present(from: presenter) {
            LerixLog.debug("Feedback: no view controller to present from")
            flow.finish(.cancelled)
        }
    }

    private func wire() {
        model.onClose = { [weak self] result in self?.close(result) }
        model.onDirtyChanged = { [weak self] dirty in self?.sheet.blocksInteractiveDismiss = dirty }
        sheet.onInteractiveDismiss = { [weak self] in
            guard let self = self else { return }
            self.finish(self.model.result ?? .cancelled)
        }
        #if canImport(UIKit)
        model.onAddScreenshot = { [weak self] in self?.pickAnotherScreen() }
        #endif
    }

    private func present(from presenter: Presenter?) -> Bool {
        sheet.present(LerixFeedbackFlowView(model: model), from: presenter, mediumDetent: false)
    }

    private func close(_ result: LerixFeedbackResult) {
        sheet.dismiss { [weak self] in self?.finish(result) }
    }

    private func finish(_ result: LerixFeedbackResult) {
        #if canImport(UIKit)
        overlay?.isHidden = true
        overlay = nil
        #endif
        guard Self.current === self else { return }
        Self.current = nil
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    #if canImport(UIKit)
    // MARK: "Add another screenshot"

    private func pickAnotherScreen() {
        sheet.dismiss { [weak self] in self?.showCaptureBar() }
    }

    private func showCaptureBar() {
        guard let appWindow = LerixScreenshot.keyWindow(), let scene = appWindow.windowScene else {
            _ = present(from: nil)
            return
        }
        let window = LerixOverlayWindow(windowScene: scene)
        let bounds = appWindow.bounds
        let bottom = max(appWindow.safeAreaInsets.bottom, 12)
        window.frame = CGRect(x: 12, y: bounds.height - bottom - 76, width: bounds.width - 24, height: 76)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let bar = LerixThemed {
            LerixCaptureBar(
                onCapture: { [weak self] in self?.captureFromBar() },
                onCancel: { [weak self] in self?.cancelCapture() }
            )
        }
        let host = UIHostingController(rootView: bar)
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        overlay = window
    }

    private func captureFromBar() {
        overlay?.isHidden = true
        overlay = nil
        // Let the bar disappear from the screen before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            if let window = LerixScreenshot.keyWindow(), let image = LerixScreenshot.capture(window) {
                self.model.addScreenshot(image)
            }
            if !self.present(from: nil) { self.finish(.cancelled) }
        }
    }

    private func cancelCapture() {
        overlay?.isHidden = true
        overlay = nil
        if !present(from: nil) { finish(.cancelled) }
    }
    #endif
}

#if canImport(UIKit)
/// Opt-in shake-to-report: swizzles `UIWindow.motionEnded(_:with:)` once.
/// A view controller that handles shakes itself without calling `super`
/// keeps them from reaching the window.
enum LerixShake {
    static var enabled = false
    static var options = LerixFeedbackOptions()
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UIWindow.self
        let originalSelector = #selector(UIResponder.motionEnded(_:with:))
        let swizzledSelector = #selector(UIWindow.lerix_motionEnded(_:with:))
        guard let original = class_getInstanceMethod(cls, originalSelector),
              let swizzled = class_getInstanceMethod(cls, swizzledSelector) else { return }
        // UIWindow may only inherit motionEnded from UIResponder: add it to
        // UIWindow first so UIResponder itself is left untouched.
        if class_addMethod(cls, originalSelector, method_getImplementation(swizzled), method_getTypeEncoding(swizzled)) {
            class_replaceMethod(cls, swizzledSelector, method_getImplementation(original), method_getTypeEncoding(original))
        } else {
            method_exchangeImplementations(original, swizzled)
        }
    }
}

extension UIWindow {
    @objc func lerix_motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        lerix_motionEnded(motion, with: event) // the original implementation (swizzled)
        guard motion == .motionShake, LerixShake.enabled, !(self is LerixOverlayWindow) else { return }
        Lerix.feedback.show(options: LerixShake.options)
    }
}
#endif

// MARK: - Public API

extension LerixFeedback {
    #if canImport(UIKit)
    /// Shows the feedback flow (iOS 15+): message → labels → screenshots
    /// (with drawing) → email → review. The current screen is captured
    /// before the sheet appears. Presents from `viewController`, or from the
    /// top-most view controller of the key window (works for SwiftUI apps).
    /// `completion` runs once, on the main thread. On iOS 13–14 it reports
    /// `submitted: false` right away; use `submit` there.
    public func show(
        from viewController: UIViewController? = nil,
        options: LerixFeedbackOptions = LerixFeedbackOptions(),
        completion: ((LerixFeedbackResult) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            guard #available(iOS 15.0, *) else {
                LerixLog.debug("The feedback UI needs iOS 15; use Lerix.feedback.submit")
                completion?(.cancelled)
                return
            }
            Task { @MainActor in
                await LerixFeedbackPresenter.start(from: viewController, options: options, completion: completion)
            }
        }
    }

    /// Opens the feedback flow when the user shakes the device. Off until
    /// called; `disableShakeToReport()` turns it off again.
    public func enableShakeToReport(options: LerixFeedbackOptions = LerixFeedbackOptions()) {
        LerixShake.options = options
        LerixShake.enabled = true
        if Thread.isMainThread { LerixShake.install() } else { DispatchQueue.main.async { LerixShake.install() } }
    }

    public func disableShakeToReport() {
        LerixShake.enabled = false
    }
    #elseif canImport(AppKit)
    /// Shows a feedback sheet on the key window (macOS 12+): message,
    /// labels, email, review. No screenshots on macOS.
    public func show(
        from viewController: NSViewController? = nil,
        options: LerixFeedbackOptions = LerixFeedbackOptions(),
        completion: ((LerixFeedbackResult) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            guard #available(macOS 12.0, *) else {
                completion?(.cancelled)
                return
            }
            Task { @MainActor in
                await LerixFeedbackPresenter.start(from: viewController, options: options, completion: completion)
            }
        }
    }
    #endif
}
#endif
