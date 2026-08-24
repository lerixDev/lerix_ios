import Foundation

/// Holds the SDK's configuration and runtime state — mirrors `AtelerixKeys`
/// in the Flutter SDK.
final class AtelerixKeys {
    static let shared = AtelerixKeys()
    private init() {}

    var url: String = "https://api.atelerix.dev"
    var apiKey: String = ""
    var projectId: String = ""
    var debug: Bool = false

    var projectConfig: AtelerixPingConfig?
    var projectUser: String?
    var deviceToken: String?
}
