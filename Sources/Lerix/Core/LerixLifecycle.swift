import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// App foreground/background hooks: `UIApplication` notifications on iOS,
/// `NSApplication` activation on macOS. Drives analytics sessions and the
/// background flush.
final class LerixLifecycle {
    static let shared = LerixLifecycle()

    var onForeground: () -> Void = {}
    var onBackground: () -> Void = {}

    private var observers: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        #if canImport(UIKit)
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onForeground()
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onBackground()
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onBackground()
        })
        #elseif canImport(AppKit)
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onForeground()
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onBackground()
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onBackground()
        })
        #endif
    }

    /// Whether the app was launched straight into the background (silent
    /// push, background fetch): such a launch is not an app start.
    static var isInBackground: Bool {
        #if canImport(UIKit)
        guard Thread.isMainThread else { return false }
        return UIApplication.shared.applicationState == .background
        #else
        return false
        #endif
    }

    /// Runs `work` with extra background execution time on iOS, so the flush
    /// on backgrounding can finish.
    static func withBackgroundTime(_ work: @escaping () async -> Void) {
        #if canImport(UIKit)
        /// Main-thread only: the expiration handler and the completion
        /// below both run there.
        final class Token: @unchecked Sendable {
            var id = UIBackgroundTaskIdentifier.invalid
            func end() {
                guard id != .invalid else { return }
                UIApplication.shared.endBackgroundTask(id)
                id = .invalid
            }
        }
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "lerix-flush") { token.end() }
        Task {
            await work()
            DispatchQueue.main.async { token.end() }
        }
        #else
        Task { await work() }
        #endif
    }
}
