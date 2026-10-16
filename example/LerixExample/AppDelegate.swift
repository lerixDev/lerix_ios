import UIKit
import Lerix

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // LERIX_API_KEY / LERIX_PROJECT_ID / LERIX_URL override the defaults, e.g. for a local
        // gateway: `SIMCTL_CHILD_LERIX_URL=http://localhost:3010/v1 xcrun simctl launch ...`.
        let env = ProcessInfo.processInfo.environment
        Lerix.initialize(
            apiKey: env["LERIX_API_KEY"] ?? "6141d7ec-6860-414e-bd5f-96a056698be5",
            projectId: env["LERIX_PROJECT_ID"] ?? "u2ip-111-2esw",
            url: env["LERIX_URL"] ?? "https://api.lerix.dev/v1",
            debugMode: true
        )
        Lerix.feedback.enableShakeToReport()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Lerix.notifications.setDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[LerixExample] Failed to register for remote notifications: \(error)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Lerix.notifications.handleRemoteNotification(userInfo: userInfo)
        completionHandler(.newData)
    }
}
