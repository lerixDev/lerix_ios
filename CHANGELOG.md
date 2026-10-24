# Changelog

## 1.5.1

### Changed
- **Minimum versions are now iOS 15 and macOS 12.** Xcode 27 can't build for anything older, so CocoaPods rejected
  1.5.0 (its validation builds the pod). 1.5.0 is only on SwiftPM; this is the same SDK, also on CocoaPods.

## 1.5.0

### Changed
- **`Lerix.initialize` no longer takes over the notification delegate in apps that don't use push.** It sets
  `UNUserNotificationCenter.current().delegate` only when the app has registered for remote notifications (every
  push app has, after its first launch), so taps that open the app still reach `setOnNotificationTapped`. Other apps
  keep their own delegate, or another library's. The first use of `Lerix.notifications` sets it otherwise, and
  `register()` can now be called any number of times.

### Added
- **Rating (CSAT) surveys**: `Lerix.surveys.showRating(_:force:custom:from:)` shows the rating
  survey with that dashboard key when it is active, matches the app and is due. Styles: stars,
  hearts, emoji/faces, thumbs (exactly two choices) and numbers, each choice with its own value,
  group, label, emoji and colour. The row mirrors in right-to-left languages; follow-up question
  per group, then thanks. Eligibility has no first-showing spread, and `frequencyDays` 0 means no
  gap after an answer. Responses carry the `choice` id and its value as `score`.
- **Headless surveys**: `dueNps(force:custom:)` / `dueRating(_:force:custom:)` return a
  `LerixSurveyPrompt` (`question`, `choices`, `appearance`, `groupOf`, `followUp`, `thanks`,
  `shown()`, `answer(_:message:)`, `dismiss()`) for your own UI. They work on every OS version and
  record exactly what the built-in sheet would.
- **NPS appearance** from the dashboard: button shape (rounded, circle, square, pill), accent
  colour (beats `Lerix.ui.tintColor`), colour by score group, end labels and `showLabels`.
- `maybeShowNps` takes `custom` too.
- VoiceOver labels and the selected trait on every survey choice; EN + AR strings for the rating UI.

### Changed
- The survey config is decoded lossily: an unreadable entry, or a rating with fewer than two
  readable options, is skipped instead of failing the whole payload; a bad field value falls back
  to its default.
- A follow-up message now keeps the first answer's `answeredAt` instead of sending a new one.
- The NPS 0–10 scale and its end labels always read left to right, also in Arabic.

### Fixed
- Survey responses queued while the outbox was already sending (e.g. the answer right after
  "shown") went out only with the next 30 s drain; they are now sent by the running drain.

## 1.4.0 (unreleased)

### Added
- **Release Control**: `Lerix.appControl` (`state`, `onChange`, `addListener`/`removeListener`,
  `refresh()`, `openStore()`, `later()`, `skip()`), configured with
  `Lerix.initialize(..., appControl: LerixAppControlOptions(enabled:ui:))`. Fetches
  `GET /plugin/app-config` at launch, on foreground and on a silent `config_refresh` push, with
  ETag/304 and an offline cache.
- Built-in screens: a full-screen maintenance screen (with "Try again" and the expected return time),
  a full-screen required-update screen (store link and release notes), and a soft update prompt
  (Update / Later / Skip this version). The screens are in English and Arabic, with RTL.
- **SDK kill switch**: when Lerix switches the SDK off for a version, every SDK request stops except
  `app-config`. Queued items are kept and sent once the switch lifts.
- Events: `$update_prompt_shown`, `$update_prompt_action`, `$maintenance_shown`, `$config_applied`.

### Fixed
- Silent "unsend" pushes now read the backend's `data.action` payload.

## 1.3.0 (unreleased)

### Added
- **Product analytics**: `Lerix.track(_:props:)`, `Lerix.screen(_:props:)`,
  `Lerix.analytics.flush()` / `flushAndWait()` / `setEnabled(_:)` / `sessionId`.
  Automatic `$first_open`, `$session_start` / `$session_end` (30-minute
  background timeout), `$app_update` and `$screen_view` events, batched to
  `POST /plugin/events`. SwiftUI `.lerixScreen("Name")` and opt-in UIKit screen
  tracking (`LerixAnalyticsOptions.uikitScreenTracking`, `UIViewController.lerixScreenName`).
- **In-app feedback**: `Lerix.feedback.show(from:options:completion:)` (iOS 15+,
  simpler sheet on macOS 12+) with screenshots captured before the sheet opens,
  PencilKit drawing, "add another screenshot", labels and email from the
  dashboard config, and "show details". Headless `Lerix.feedback.submit(...)`,
  `setUserEmail(_:)`, opt-in `enableShakeToReport()` / `disableShakeToReport()`.
  Screenshot masking with `UIView.lerixConfidential` and SwiftUI `.lerixConfidential()`.
- **NPS surveys**: `Lerix.surveys.maybeShowNps(force:from:)` with on-device
  eligibility (app starts, initial delay, FNV-1a sampling, frequency and dismiss
  cooldown) and a half-height sheet (score → follow-up → thanks).
- **Breadcrumbs**: `Lerix.addBreadcrumb(_:category:data:)`; the last 50 are
  sent with feedback and as `metadata.breadcrumbs` on handled errors.
- **Durable outbox** for analytics, feedback and survey responses: one JSON file
  per item, retries with 2 s → 5 min jittered backoff, `401` never deletes data,
  `403 SDK_DISABLED` pauses that feature, and the app user is re-registered when
  the backend no longer knows it.
- `initialize(environment:analytics:)`: environment defaults to `dev` for debug
  builds and the simulator, `prod` otherwise.
- UI strings in English and Arabic (right-to-left), overridable with
  `Lerix.ui.setStrings(_:locale:)`; `Lerix.ui.locale` and `Lerix.ui.tintColor`.

### Changed
- Error and crash reports now carry the analytics `sessionId` (crash-free
  sessions in the dashboard).
- Concurrent registrations (initialize, outbox, error reports) share one
  `register-user` call.

## 1.2.0
- External user linking (`setUser` / `clearUser`) and macOS support.
