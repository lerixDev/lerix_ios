# Changelog

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
