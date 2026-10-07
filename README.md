# Lerix (native iOS / Swift)

Native Swift Package Manager SDK for iOS apps with no Flutter involved —
feature parity with the `lerix` Flutter plugin: app/device registration,
error/crash reporting, and push notifications (APNs).

## Install

### Swift Package Manager

Published on GitHub and resolved directly by Swift Package Manager from tagged
releases.

Add the package via Xcode: **File → Add Package Dependencies…** and enter
`https://github.com/lerixDev/lerix_ios`, or add it directly to
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lerixDev/lerix_ios", from: "1.2.0")
]
```

For local development against this checkout instead, use a path dependency:

```swift
dependencies: [
    .package(path: "../lerix_ios")
]
```

### CocoaPods

```ruby
pod 'Lerix', '~> 1.0'
```

Then run `pod install` and open the `.xcworkspace`.

## Setup

### 1. Initialize

```swift
import Lerix

func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    Lerix.initialize(
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
    Lerix.notifications.setDeviceToken(deviceToken)
}

func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
    Lerix.notifications.handleRemoteNotification(userInfo: userInfo)
    completionHandler(.newData)
}
```

### 3. Request permission and observe notifications

```swift
Task {
    let granted = await Lerix.notifications.requestPermissions()
}

Lerix.notifications.setOnNotificationTapped { payload in
    // navigate based on payload.notificationId / payload.metadata
}

Lerix.notifications.setOnNotificationReceived { payload in
    // foreground banner already shown by the SDK; use this for custom UI state
}
```

### 4. Report errors

```swift
Lerix.throwError(
    "Something went wrong",
    stack: Thread.callStackSymbols,
    type: .runtimeError,
    severity: .high
)
```

Uncaught exceptions and fatal signals (force-unwraps, array out-of-bounds,
etc.) are reported automatically — `Lerix.initialize()` installs a crash
handler by default (pass `enableCrashReporting: false` to opt out). A crash
can't do async network I/O, so it's persisted to disk and reported on the
*next* launch, tagged `type: .crash, severity: .critical`.

### Filtering errors

Drop or rewrite error reports on the device before they are sent. Filtering
runs on every report: manual `throwError` calls and crashes reported on the
next launch.

```swift
Lerix.initialize(
    apiKey: "<project api key>",
    projectId: "<project slug>",
    // Dropped if any entry is a case-insensitive substring of the message.
    ignoreErrors: ["The network connection was lost"],
    // Dropped if any regex matches anywhere in the message.
    ignoreErrorPatterns: [try! NSRegularExpression(pattern: "^NSURLErrorDomain -10\\d{2}")],
    // Runs after the ignore lists, right before sending. Return the
    // (optionally modified) event to send it, or nil to drop it.
    beforeSend: { event in
        var event = event
        event.message = event.message.replacingOccurrences(of: "secret", with: "[redacted]")
        if event.severity == .low { return nil }
        return event
    }
)
```

`LerixErrorEvent` exposes `message`, `stack`, `type`, `severity` and
`metadata`, all mutable. The SDK ships no default ignore patterns; common
noise is filtered on the server.

### 5. Rich notification images (optional)

APNs has no native "image" field — add a **Notification Service Extension**
target to your app and copy `NotificationServiceExtension/NotificationService.swift`
into it. The backend sets `mutable-content` automatically whenever a
notification has an `imageUrl`, which triggers this extension to download and
attach the image before display.

### 6. Link installs to your users

Call `setUser` after login with your own user id, and `clearUser` on logout.
Your backend can then send to all of a user's devices with `externalUserIds`.

```swift
// After login
try await Lerix.setUser(user.id, identityHash: hashFromYourServer)

// On logout
try await Lerix.clearUser()
```

The id is stored in the Keychain and re-sent automatically if the install is
registered again; called before `initialize` finishes registering, it is
queued. `identityHash` is only needed when the project requires identity
verification: it is the hex HMAC-SHA256 of the user id keyed with the
project's identity secret. Compute it on your server and pass it to the app;
never ship the identity secret in the app.

## Requirements

- iOS 13+ (macOS 11+ apps register as `os: "macos"` and receive pushes via APNs)
- `Push Notifications` and `Background Modes → Remote notifications`
  capabilities enabled in your app target
- An APNs key configured in your Lerix project settings

## Notes

- Device/user identity is persisted in the Keychain (`LerixKeychain`), not
  `UserDefaults`, so it survives reinstalls the same way the Flutter SDK's
  `flutter_secure_storage`-backed storage does.
- Backend routes and payload shapes are identical to the Flutter/Web SDKs —
  bugs reported from a native iOS app show up in the dashboard exactly like
  ones from a Flutter app.
