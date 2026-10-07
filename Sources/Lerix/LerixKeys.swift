import Foundation

/// Holds the SDK's configuration and runtime state — mirrors `LerixKeys`
/// in the Flutter SDK.
final class LerixKeys {
    static let shared = LerixKeys()
    private init() {}

    var url: String = "https://api.lerix.dev/v1"
    var apiKey: String = ""
    var projectId: String = ""
    var debug: Bool = false

    // Client-side error filtering — see `LerixErrorFilter`.
    var ignoreErrors: [String] = []
    var ignoreErrorPatterns: [NSRegularExpression] = []
    var beforeSend: ((LerixErrorEvent) -> LerixErrorEvent?)?

    var projectConfig: LerixPingConfig?
    var projectUser: String?
    var deviceToken: String?
}
