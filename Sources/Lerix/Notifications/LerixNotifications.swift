import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

public enum LerixPermissionStatus: String {
    case authorized
    case denied
    case notDetermined
    case provisional
}

/// Native push-notification manager — mirrors `NotificationsManager`
/// (io variant) in the Flutter SDK, adapting the existing
/// `LerixPlugin.swift` `UNUserNotificationCenterDelegate` logic without
/// the Flutter method-channel plumbing.
public final class LerixNotifications: NSObject {
    public static let shared = LerixNotifications()
    private override init() { super.init() }

    private var onReceived: ((LerixNotificationPayload) -> Void)?
    private var onTapped: ((LerixNotificationPayload) -> Void)?
    private static var pendingTap: LerixNotificationPayload?

    private let deviceTokenKey = "lerix_device_token"
    private let registeredTokenIdKey = "lerix_registered_token_id"

    /// Call once, from `application(_:didFinishLaunchingWithOptions:)`.
    public func register() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func setOnNotificationReceived(_ handler: @escaping (LerixNotificationPayload) -> Void) {
        onReceived = handler
    }

    public func setOnNotificationTapped(_ handler: @escaping (LerixNotificationPayload) -> Void) {
        onTapped = handler
        if let pending = Self.pendingTap {
            handler(pending)
            Self.pendingTap = nil
        }
    }

    /// For a tap that launched the app cold, before a handler was set.
    public func getInitialNotificationTap() -> LerixNotificationPayload? {
        defer { Self.pendingTap = nil }
        return Self.pendingTap
    }

    @discardableResult
    public func requestPermissions() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            #if canImport(UIKit)
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            #endif
            return granted
        } catch {
            return false
        }
    }

    public func checkPermissionStatus() async -> LerixPermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .provisional: return .provisional
        default: return .notDetermined
        }
    }

    public func clearBadge() {
        #if canImport(UIKit)
        Task { @MainActor in
            if #available(iOS 16.0, *) {
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
            } else {
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
        }
        #endif
    }

    /// Call from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public func setDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        LerixKeys.shared.deviceToken = token
        LerixKeychain.write(deviceTokenKey, value: token)
        Task { try? await registerTokenWithBackend(token: token) }
    }

    public func getDeviceToken() -> String? {
        if let cached = LerixKeys.shared.deviceToken { return cached }
        let stored = LerixKeychain.read(deviceTokenKey)
        LerixKeys.shared.deviceToken = stored
        return stored
    }

    public func getDeviceId() -> String {
        LerixDeviceInfo.vendorIdentifier()
    }

    public func clearToken() {
        LerixKeys.shared.deviceToken = nil
        LerixKeychain.delete(deviceTokenKey)
        LerixKeychain.delete(registeredTokenIdKey)
    }

    /// The `notifications_users_tokens.id` row-id the backend assigned when
    /// this device's token was registered — this, not the user id or the
    /// vendor device id, is what the dashboard's "send notification"
    /// feature expects in its `deviceTokens` field.
    public func getRegisteredTokenId() -> String? {
        LerixKeychain.read(registeredTokenIdKey)
    }

    public func subscribeToTopic(_ topic: String) async throws {
        let body = try await topicBody(topic: topic)
        _ = try await LerixBackend.post(route: .subscribeTopic, data: body)
    }

    public func unsubscribeFromTopic(_ topic: String) async throws {
        let body = try await topicBody(topic: topic)
        _ = try await LerixBackend.post(route: .unsubscribeTopic, data: body)
    }

    private func topicBody(topic: String) async throws -> [String: Any] {
        guard let token = getDeviceToken(), let userId = LerixInit.existingUserId() else {
            throw LerixBackendError.invalidResponse
        }
        let config = try await LerixInit.cachedOrFreshPingConfig()
        return ["userId": userId, "appId": config.id ?? "", "token": token, "topicKey": topic]
    }

    private func registerTokenWithBackend(token: String) async throws {
        guard let userId = LerixInit.existingUserId() else { return }
        let config = try await LerixInit.cachedOrFreshPingConfig()
        let response = try await LerixBackend.post(
            route: .registerToken,
            data: ["userId": userId, "appId": config.id ?? "", "token": token],
            headers: ["app-user": userId]
        )
        if let tokenId = response?["id"] as? String {
            LerixKeychain.write(registeredTokenIdKey, value: tokenId)
        }
    }

    /// Handles a silent "remove" push used to revoke a previously delivered
    /// notification — mirrors `LerixPlugin.handleRemoteNotification`.
    /// Call from `application(_:didReceiveRemoteNotification:...)`.
    public func handleRemoteNotification(userInfo: [AnyHashable: Any]) {
        guard let command = userInfo["command"] as? String, command == "remove" else { return }
        guard let notificationId = userInfo["notificationId"] as? String else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationId])
    }
}

extension LerixNotifications: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let payload = LerixNotificationPayload(userInfo: notification.request.content.userInfo)
        onReceived?(payload)
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = LerixNotificationPayload(userInfo: response.notification.request.content.userInfo)
        if let handler = onTapped {
            handler(payload)
        } else {
            Self.pendingTap = payload
        }
        completionHandler()
    }
}
