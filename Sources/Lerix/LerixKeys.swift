import Foundation

/// Holds the SDK's configuration and runtime state — mirrors `AtelerixKeys`
/// in the Flutter SDK.
final class LerixKeys {
    static let shared = LerixKeys()
    private init() {}

    var url: String = "https://api.atelerix.dev/v1"
    var apiKey: String = ""
    var projectId: String = ""
    var debug: Bool = false

    var projectConfig: LerixPingConfig?
    var projectUser: String?
    var deviceToken: String?
}
