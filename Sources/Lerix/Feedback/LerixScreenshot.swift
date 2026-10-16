import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
import ObjectiveC

private var lerixConfidentialKey: UInt8 = 0

extension UIView {
    /// When `true`, this view (and everything inside it) is painted over
    /// with a black rectangle in feedback screenshots.
    public var lerixConfidential: Bool {
        get { (objc_getAssociatedObject(self, &lerixConfidentialKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &lerixConfidentialKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// The window that hosts the "Capture" bar while the user picks another
/// screen. Never captured, never key.
final class LerixOverlayWindow: UIWindow {}

/// Screen capture for feedback: the key window via
/// `drawHierarchy(in:afterScreenUpdates:)`, with confidential views masked.
enum LerixScreenshot {
    /// The app's key window (not one of the SDK's own windows).
    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive }
            + scenes.filter { $0.activationState != .foregroundActive }
        for scene in ordered {
            let windows = scene.windows.filter { !($0 is LerixOverlayWindow) && !$0.isHidden }
            if let key = windows.first(where: { $0.isKeyWindow }) { return key }
            if let normal = windows.first(where: { $0.windowLevel == .normal }) { return normal }
        }
        return nil
    }

    static func topViewController(from root: UIViewController? = keyWindow()?.rootViewController) -> UIViewController? {
        var current = root
        while let controller = current {
            if let presented = controller.presentedViewController, !presented.isBeingDismissed {
                current = presented
            } else if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController {
                if visible === navigation { return navigation }
                current = visible
            } else if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
                current = selected
            } else {
                return controller
            }
        }
        return nil
    }

    /// Captures the window at up to 2× scale (keeps uploads well under 5 MB).
    static func capture(_ window: UIWindow) -> UIImage? {
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(window.screen.scale, 2)
        format.opaque = true
        let masks = confidentialRects(in: window)
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        return renderer.image { context in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            UIColor.black.setFill()
            for rect in masks { context.fill(rect) }
        }
    }

    /// Frames (in window coordinates) of visible views flagged confidential.
    static func confidentialRects(in window: UIWindow) -> [CGRect] {
        var rects: [CGRect] = []
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if view.lerixConfidential {
                rects.append(view.convert(view.bounds, to: window))
                return
            }
            view.subviews.forEach(visit)
        }
        visit(window)
        return rects
    }

    /// PNG, or JPEG when the PNG would be too large for the 5 MB limit.
    static func encode(_ image: UIImage) -> LerixScreenshotData? {
        if let png = image.pngData(), png.count <= 4_500_000, let shot = LerixScreenshotData(data: png) {
            return shot
        }
        for quality in [0.85, 0.7, 0.5] as [CGFloat] {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= 4_500_000,
               let shot = LerixScreenshotData(data: jpeg) {
                return shot
            }
        }
        return nil
    }
}

#if canImport(SwiftUI)
/// A transparent marker laid over a SwiftUI view so the screenshot code can
/// find its frame.
@available(iOS 13.0, *)
private struct LerixConfidentialMarker: UIViewRepresentable {
    let enabled: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.lerixConfidential = enabled
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.lerixConfidential = enabled
    }
}
#endif
#endif

#if canImport(SwiftUI)
@available(iOS 13.0, macOS 10.15, *)
extension View {
    /// Masks this view with a black rectangle in feedback screenshots.
    public func lerixConfidential(_ enabled: Bool = true) -> some View {
        #if canImport(UIKit)
        return overlay(LerixConfidentialMarker(enabled: enabled).allowsHitTesting(false))
        #else
        return self
        #endif
    }
}
#endif
