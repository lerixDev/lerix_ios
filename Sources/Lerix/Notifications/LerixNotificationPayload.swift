import Foundation

/// The payload handed to `onNotificationReceived`/`onNotificationTapped` —
/// mirrors the Flutter SDK's notification payload model.
public struct LerixNotificationPayload {
    public let notificationId: String?
    public let title: String?
    public let body: String?
    public let imageUrl: String?
    public let metadata: [String: Any]

    init(userInfo: [AnyHashable: Any]) {
        let aps = userInfo["aps"] as? [String: Any]
        let alert = aps?["alert"] as? [String: Any]

        notificationId = userInfo["notificationId"] as? String
        title = alert?["title"] as? String ?? userInfo["title"] as? String
        body = alert?["body"] as? String ?? userInfo["body"] as? String
        imageUrl = userInfo["imageUrl"] as? String

        var meta: [String: Any] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String else { continue }
            if key == "aps" { continue }
            meta[key] = value
        }
        metadata = meta
    }
}
