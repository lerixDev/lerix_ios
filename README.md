# Lerix (native iOS / Swift)

Native Swift Package Manager SDK for iOS apps with no Flutter involved —
feature parity with the `lerix` Flutter plugin: app/device registration,
error/crash reporting, push notifications (APNs), in-app feedback, NPS
surveys and product analytics.

## Install

### Swift Package Manager

Published on GitHub and resolved directly by Swift Package Manager from tagged
releases.

Add the package via Xcode: **File → Add Package Dependencies…** and enter
`https://github.com/lerixDev/lerix_ios`, or add it directly to
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lerixDev/lerix_ios", from: "1.3.0")
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
pod 'Lerix', '~> 1.3'
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

### 7. Product analytics

Events, screens and sessions are recorded automatically once `initialize`
runs; add your own with `track` and `screen`. Nothing here throws: invalid
names or props are dropped (and logged when `debugMode` is on).

```swift
Lerix.track("checkout_started", props: ["items": 3, "coupon": "EID"])
Lerix.screen("Checkout")

Lerix.analytics.flush()              // send now (also happens every 30 s and on background)
Lerix.analytics.setEnabled(false)    // opt-out: stops recording, clears the queue, persisted
```

- **Names** match `^[A-Za-z][A-Za-z0-9 _.:-]{1,63}$`; `$` names are reserved.
  **Props**: up to 25 keys, values `String` (≤ 1024 chars), number, `Bool` or `nil`.
- **Automatic events**: `$first_open`, `$session_start` / `$session_end` (a
  session ends after 30 min in the background), `$app_update`, `$screen_view`.
- **Screens**: SwiftUI `.lerixScreen("Name")`, or opt in to automatic UIKit
  tracking (swizzles `viewDidAppear`; name a controller with
  `viewController.lerixScreenName`, or set it to `""` to skip it):

  ```swift
  Lerix.initialize(
      apiKey: "…", projectId: "…",
      environment: "staging",   // default: "dev" for debug builds and the simulator, else "prod"
      analytics: LerixAnalyticsOptions(autoSessions: true, autoScreens: true, uikitScreenTracking: true)
  )
  ```

- Events are written to a durable on-disk outbox (one file per item in
  `Application Support/lerix/outbox`) and sent in batches of up to 100: first
  5 s after launch, then every 30 s while events are pending (immediately at
  50), and when the app goes to the background. Offline, up to 1 MB / 7 days
  of events is kept.
- The session id is also attached to error and crash reports, so the
  dashboard can show crash-free sessions.
- `Lerix.addBreadcrumb("Tapped pay", category: .ui)` adds to the last-50
  breadcrumb trail sent with feedback and error reports (screen views are
  added automatically).

### 8. In-app feedback

```swift
// From anywhere: UIKit or SwiftUI. The current screen is captured first.
Lerix.feedback.show { result in
    print(result.submitted, result.id ?? "queued")
}

// Optional
Lerix.feedback.setUserEmail(user.email)       // prefills the email step
Lerix.feedback.enableShakeToReport()          // opt-in; disableShakeToReport() to stop
Lerix.feedback.show(options: LerixFeedbackOptions(
    labels: ["bug", "improvement"],            // offer only these label keys
    email: .required,                          // .hidden / .optional / .required
    screenshot: .optional,                     // .hidden to skip screenshots
    custom: ["plan": "pro"]
))
```

The flow is message → labels → screenshots (tap one to draw on it with
PencilKit; "Add another screenshot" lets the user go to another screen and
capture it) → email → review ("Show details" lists everything that is sent)
→ done. Labels, email and screenshot modes come from the dashboard's feedback
settings (cached for 24 h) unless overridden. The UI needs iOS 15; on macOS 12+
a simpler sheet without screenshots is shown.

Hide sensitive content from screenshots:

```swift
cardNumberLabel.lerixConfidential = true   // UIKit
Text(balance).lerixConfidential()           // SwiftUI
```

Build your own UI with the headless API (PNG/JPEG/WebP screenshots, ≤ 5 MB each):

```swift
let result = try await Lerix.feedback.submit(
    message: "Checkout button does nothing",
    labels: ["bug"],
    email: "user@example.com",
    screenshots: [pngData]
)
```

Feedback goes through the same outbox: screenshots are uploaded first (and
checkpointed), then the feedback is posted with a client id the server
dedupes on. Offline feedback is kept until it can be delivered; a `401`
never deletes it.

### 9. NPS survey

```swift
// e.g. after a successful checkout
Task { await Lerix.surveys.maybeShowNps() }

// During development: skip the eligibility rules
Task { await Lerix.surveys.maybeShowNps(force: true) }
```

The survey (question, cadence, sampling, targeting) is configured in the
dashboard; a default NPS survey exists for every project. The SDK shows it
only when this install has had enough app starts, is past the initial delay,
falls inside the sample, and is due (90 days after an answer, 14 days after a
dismissal by default). With `debugMode: true` it logs why a survey was
skipped. The sheet (0–10 score → follow-up → thanks) opens at half height.

### 10. Language and colours

The feedback and NPS UI ships in English and Arabic (right-to-left) and
follows the app's language and light/dark mode.

```swift
Lerix.ui.locale = "ar"                                   // default: the app's language
Lerix.ui.tintColor = .purple                             // default: the key window's tint
Lerix.ui.setStrings(["feedback.title": "Report a problem"], locale: "en")
```

String keys are listed in `Sources/Lerix/Resources/en.lproj/Lerix.strings`.

## Requirements

- iOS 13+ (macOS 11+ apps register as `os: "macos"` and receive pushes via APNs)
- The feedback and NPS UI needs iOS 15+ / macOS 12+; everything else, including
  `Lerix.feedback.submit`, works on iOS 13+
- `Push Notifications` and `Background Modes → Remote notifications`
  capabilities enabled in your app target
- An APNs key configured in your Lerix project settings

## Notes

- Device/user identity is persisted in the Keychain (`LerixKeychain`), not
  `UserDefaults`, so it survives reinstalls the same way the Flutter SDK's
  `flutter_secure_storage`-backed storage does.
- Analytics, feedback and survey state lives in `Application Support/lerix/`
  (`Application Support/<bundle id>/lerix/` on macOS), so it is removed with
  the app. `$first_open` fires on the first launch of a new install. It is
  skipped when a Lerix user id is already in the Keychain: an upgrade from an
  SDK version without analytics, or a reinstall (the Keychain survives it).
- Shake-to-report swizzles `UIWindow.motionEnded(_:with:)`. A view controller
  that handles shakes itself without calling `super` keeps them from reaching
  the window.
- Backend routes and payload shapes are identical to the Flutter/Web SDKs —
  bugs reported from a native iOS app show up in the dashboard exactly like
  ones from a Flutter app.
