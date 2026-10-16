import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
import ObjectiveC
#endif

enum LerixScreenTracking {
    #if canImport(UIKit)
    private static var installed = false

    /// Swizzles `UIViewController.viewDidAppear(_:)` once. Opt-in through
    /// `LerixAnalyticsOptions.uikitScreenTracking`.
    static func installUIKitHook() {
        let install = {
            guard !installed else { return }
            installed = true
            let cls: AnyClass = UIViewController.self
            guard let original = class_getInstanceMethod(cls, #selector(UIViewController.viewDidAppear(_:))),
                  let swizzled = class_getInstanceMethod(cls, #selector(UIViewController.lerix_viewDidAppear(_:))) else { return }
            method_exchangeImplementations(original, swizzled)
        }
        if Thread.isMainThread { install() } else { DispatchQueue.main.sync(execute: install) }
    }

    /// Containers, system and SwiftUI-hosting controllers aren't screens.
    static func screenName(for controller: UIViewController) -> String? {
        if let explicit = controller.lerixScreenName { return explicit.isEmpty ? nil : explicit }
        if controller is UINavigationController || controller is UITabBarController
            || controller is UIPageViewController || controller is UISplitViewController
            || controller is UIAlertController {
            return nil
        }
        if let parent = controller.parent,
           !(parent is UINavigationController || parent is UITabBarController
             || parent is UIPageViewController || parent is UISplitViewController) {
            // An embedded child; its container is the screen.
            return nil
        }
        let fullName = NSStringFromClass(type(of: controller))
        let name = fullName.split(separator: ".").last.map(String.init) ?? fullName
        if name.hasPrefix("UI") || name.hasPrefix("_") || name.hasPrefix("Lerix")
            || fullName.contains("HostingController") || fullName.hasPrefix("SwiftUI") {
            return nil
        }
        return name
    }
    #endif
}

#if canImport(UIKit)
private var lerixScreenNameKey: UInt8 = 0

extension UIViewController {
    /// The `$screen_view` name the UIKit hook uses for this controller.
    /// Defaults to the class name; set an empty string to skip it.
    public var lerixScreenName: String? {
        get { objc_getAssociatedObject(self, &lerixScreenNameKey) as? String }
        set { objc_setAssociatedObject(self, &lerixScreenNameKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    @objc func lerix_viewDidAppear(_ animated: Bool) {
        lerix_viewDidAppear(animated) // the original implementation (swizzled)
        if let name = LerixScreenTracking.screenName(for: self) {
            LerixAnalytics.shared.screen(name, props: nil, source: .uikit)
        }
    }
}
#endif

#if canImport(SwiftUI)
@available(iOS 13.0, macOS 10.15, *)
private struct LerixScreenModifier: ViewModifier {
    let name: String
    let props: [String: Any]?

    func body(content: Content) -> some View {
        content.onAppear {
            LerixAnalytics.shared.screen(name, props: props, source: .modifier)
        }
    }
}

@available(iOS 13.0, macOS 10.15, *)
extension View {
    /// Records a `$screen_view` named `name` when this view appears
    /// (a repeat of the current screen is skipped).
    public func lerixScreen(_ name: String, props: [String: Any]? = nil) -> some View {
        modifier(LerixScreenModifier(name: name, props: props))
    }
}
#endif
