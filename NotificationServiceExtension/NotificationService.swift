import UserNotifications

/// Downloads and attaches the `imageUrl` Lerix sent, so the rich
/// notification image actually shows up on iOS.
///
/// APNs has no native "image" field the way FCM does — this is the only
/// mechanism: the main app's `aps.mutable-content` flag (set automatically by
/// the backend whenever `imageUrl` is present) tells iOS to launch this
/// extension before displaying the notification, giving it a chance to
/// download the image and attach it as a `UNNotificationAttachment`.
///
/// This file can't be added to your app automatically — Swift Package
/// Manager can't create a new Xcode target for you. Copy it into a
/// Notification Service Extension target you add yourself; see the push
/// notifications setup guide for the exact steps.
class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttemptContent = bestAttemptContent,
              let imageUrlString = request.content.userInfo["imageUrl"] as? String,
              !imageUrlString.isEmpty,
              let imageUrl = URL(string: imageUrlString)
        else {
            contentHandler(request.content)
            return
        }

        downloadImage(from: imageUrl) { attachment in
            if let attachment = attachment {
                bestAttemptContent.attachments = [attachment]
            }
            contentHandler(bestAttemptContent)
        }
    }

    /// Called by the OS a few seconds before this extension's time budget
    /// runs out — deliver whatever we have rather than let the notification
    /// be dropped entirely.
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    private func downloadImage(from url: URL, completion: @escaping (UNNotificationAttachment?) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { location, _, error in
            guard let location = location, error == nil else {
                completion(nil)
                return
            }

            // UNNotificationAttachment requires a file already on disk with an
            // extension it can infer a UTType from — move the downloaded temp
            // file into a new temp file with the original URL's extension.
            let fileManager = FileManager.default
            let tmpDirectory = fileManager.temporaryDirectory
            let fileExtension = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let destinationUrl = tmpDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)

            do {
                try fileManager.moveItem(at: location, to: destinationUrl)
                let attachment = try UNNotificationAttachment(identifier: "image", url: destinationUrl, options: nil)
                completion(attachment)
            } catch {
                completion(nil)
            }
        }
        task.resume()
    }
}
