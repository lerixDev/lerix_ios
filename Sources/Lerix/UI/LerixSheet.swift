#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Applies `LerixUI`: accent colour, language and layout direction.
@available(iOS 15.0, macOS 12.0, *)
struct LerixThemed<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let ui = LerixUI.shared
        let tint = Self.resolvedTint()
        content
            .tint(tint)
            .accentColor(tint)
            .environment(\.layoutDirection, ui.isRightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.locale, Locale(identifier: ui.language))
    }

    static func resolvedTint() -> Color {
        if let tint = LerixUI.shared.tintColor { return tint }
        #if canImport(UIKit)
        // `tintColor` is declared `UIColor!` and can be nil at runtime.
        if let window = LerixScreenshot.keyWindow(), let tint = window.tintColor as UIColor? { return Color(uiColor: tint) }
        #endif
        return .accentColor
    }
}

extension Color {
    /// `#RRGGBB` / `RRGGBB` (dashboard label colours).
    init?(lerixHex hex: String?) {
        guard var value = hex?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

/// Presents one SwiftUI view as a sheet: a `UIHostingController` page sheet
/// on iOS (works from UIKit and SwiftUI apps), an `NSHostingController`
/// window sheet on macOS.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
final class LerixSheetController: NSObject {
    /// Called when the user swipes the sheet away (iOS).
    var onInteractiveDismiss: (() -> Void)?

    #if canImport(UIKit)
    private var host: UIViewController?

    /// Blocks swipe-to-dismiss (e.g. while there is unsent text).
    var blocksInteractiveDismiss: Bool = false {
        didSet { host?.isModalInPresentation = blocksInteractiveDismiss }
    }

    var isPresented: Bool { host?.presentingViewController != nil }

    func present<V: View>(_ view: V, from presenter: UIViewController?, mediumDetent: Bool) -> Bool {
        guard let presenter = presenter ?? LerixScreenshot.topViewController() else { return false }
        let host = UIHostingController(rootView: LerixThemed { view })
        host.modalPresentationStyle = .pageSheet
        if mediumDetent, let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.isModalInPresentation = blocksInteractiveDismiss
        host.presentationController?.delegate = self
        self.host = host
        // UIKit silently drops a present while another sheet is still animating closed (e.g. NPS
        // right after the feedback sheet's Close), which left callers believing a sheet was up.
        // Wait for that dismissal to finish instead.
        if let closing = presenter.presentedViewController, closing.isBeingDismissed,
           let coordinator = closing.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self, self.host === host else { return }
                presenter.present(host, animated: true)
                if host.presentingViewController == nil { self.presentationFailed(host) }
            }
            return true
        }
        presenter.present(host, animated: true)
        guard host.presentingViewController != nil else {
            self.host = nil
            return false
        }
        return true
    }

    /// A deferred present that UIKit refused: report it like a dismissal so callers reset.
    private func presentationFailed(_ failed: UIViewController) {
        guard host === failed else { return }
        host = nil
        onInteractiveDismiss?()
    }

    func dismiss(completion: (() -> Void)? = nil) {
        guard let host = host, host.presentingViewController != nil else {
            self.host = nil
            completion?()
            return
        }
        host.dismiss(animated: true) {
            completion?()
        }
        self.host = nil
    }
    #elseif canImport(AppKit)
    private var host: NSViewController?

    var blocksInteractiveDismiss: Bool = false
    var isPresented: Bool { host?.presentingViewController != nil }

    func present<V: View>(_ view: V, from presenter: NSViewController?, mediumDetent: Bool) -> Bool {
        guard let presenter = presenter ?? NSApp.keyWindow?.contentViewController ?? NSApp.mainWindow?.contentViewController else {
            return false
        }
        let host = NSHostingController(rootView: LerixThemed { view.frame(width: 440).frame(minHeight: mediumDetent ? 340 : 480) })
        self.host = host
        presenter.presentAsSheet(host)
        return true
    }

    func dismiss(completion: (() -> Void)? = nil) {
        if let host = host, host.presentingViewController != nil {
            host.dismiss(nil)
        }
        host = nil
        completion?()
    }
    #endif
}

#if canImport(UIKit)
@available(iOS 15.0, *)
extension LerixSheetController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        host = nil
        onInteractiveDismiss?()
    }
}
#endif
#endif
