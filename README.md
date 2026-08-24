# Atelerix (native iOS / Swift)

Native Swift Package Manager SDK for iOS apps with no Flutter involved —
feature parity with the `atelerix` Flutter plugin: app/device registration,
error/crash reporting, and push notifications (APNs).

## Install

Add the package via Xcode: **File → Add Package Dependencies…** and point it
at this directory (or a Git URL once published), or add it to
`Package.swift`:

```swift
dependencies: [
    .package(path: "../atelerix_ios")
]
```

## Setup

### 1. Initialize

```swift
import Atelerix

func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    Atelerix.initialize(
        apiKey: "YOUR_PROJECT_API_KEY",
        projectId: "YOUR_PROJECT_ID",
        debugMode: true
    )
    return true
}
```

### 2. Wire up push notification callbacks (AppDelegate)

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    Atelerix.notifications.setDeviceToken(deviceToken)
}

func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
    Atelerix.notifications.handleRemoteNotification(userInfo: userInfo)
    completionHandler(.newData)
}
```

### 3. Request permission and observe notifications

```swift
Task {
    let granted = await Atelerix.notifications.requestPermissions()
}

Atelerix.notifications.setOnNotificationTapped { payload in
    // navigate based on payload.notificationId / payload.metadata
}

Atelerix.notifications.setOnNotificationReceived { payload in
    // foreground banner already shown by the SDK; use this for custom UI state
}
```

### 4. Report errors

```swift
Atelerix.throwError(
    "Something went wrong",
    stack: Thread.callStackSymbols,
    type: .runtimeError,
    severity: .high
)
```

### 5. Rich notification images (optional)

APNs has no native "image" field — add a **Notification Service Extension**
target to your app and copy `NotificationServiceExtension/NotificationService.swift`
into it. The Atelerix backend sets `mutable-content` automatically whenever a
notification has an `imageUrl`, which triggers this extension to download and
attach the image before display.

## Requirements

- iOS 13+
- `Push Notifications` and `Background Modes → Remote notifications`
  capabilities enabled in your app target
- An APNs key configured in your Atelerix project settings

## Notes

- Device/user identity is persisted in the Keychain (`AtelerixKeychain`), not
  `UserDefaults`, so it survives reinstalls the same way the Flutter SDK's
  `flutter_secure_storage`-backed storage does.
- Backend routes and payload shapes are identical to the Flutter/Web SDKs —
  bugs reported from a native iOS app show up in the dashboard exactly like
  ones from a Flutter app.
