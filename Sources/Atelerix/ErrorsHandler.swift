import Foundation

/// Reports errors/crashes to the backend — mirrors `errors_handler.dart`'s
/// `ErrorsHandler`, including the retry-on-"user not registered" logic.
enum ErrorsHandler {
    private static let userNotRegisteredCode = "5006"
    private static let maxRetryAttempts = 3

    static func throwError(
        issue: String,
        stack: [String],
        type: BugType? = nil,
        severity: BugSeverity? = nil,
        metadata: [String: Any]? = nil
    ) async {
        do {
            try await send(issue: issue, stack: stack, type: type, severity: severity, metadata: metadata, attempt: 1)
        } catch {
            if AtelerixKeys.shared.debug {
                print("[Atelerix] Failed to report error after retries: \(error)")
            }
        }
    }

    private static func send(
        issue: String,
        stack: [String],
        type: BugType?,
        severity: BugSeverity?,
        metadata: [String: Any]?,
        attempt: Int
    ) async throws {
        guard let userId = AtelerixInit.existingUserId() else {
            _ = try await AtelerixInit.registerUser()
            try await send(issue: issue, stack: stack, type: type, severity: severity, metadata: metadata, attempt: attempt)
            return
        }

        let device = AtelerixDeviceInfo.collectDevice()
        let app = AtelerixDeviceInfo.collectApp()

        var body: [String: Any] = ["issue": issue, "stack": stack]
        if let deviceData = try? JSONEncoder().encode(device), let json = String(data: deviceData, encoding: .utf8) {
            body["device"] = json
        }
        if let appData = try? JSONEncoder().encode(app), let json = String(data: appData, encoding: .utf8) {
            body["app"] = json
        }
        if let metadata = metadata, let metaData = try? JSONSerialization.data(withJSONObject: metadata),
           let json = String(data: metaData, encoding: .utf8) {
            body["metadata"] = json
        }
        if let type = type { body["type"] = type.rawValue }
        if let severity = severity { body["severity"] = severity.rawValue }

        do {
            _ = try await AtelerixBackend.post(route: .sendBug, data: body, headers: ["app-user": userId])
        } catch let AtelerixApiError.server(code, _) where code == userNotRegisteredCode {
            guard attempt < maxRetryAttempts else { throw AtelerixApiError.server(code: code, message: "user not registered") }
            try await AtelerixInit.deleteUser()
            _ = try await AtelerixInit.registerUser()
            try await send(issue: issue, stack: stack, type: type, severity: severity, metadata: metadata, attempt: attempt + 1)
        }
    }
}

/// Backend error envelope — the API returns `{statusCode, message, error}`
/// on failure; `error` carries the numeric code used for retry logic (e.g. 5006).
enum AtelerixApiError: Error {
    case server(code: String, message: String)
}
