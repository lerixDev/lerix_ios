import Foundation

/// Reports errors/crashes to the backend — mirrors `errors_handler.dart`'s
/// `ErrorsHandler`, including the retry-on-"user not registered" logic.
enum ErrorsHandler {
    private static let userNotRegisteredCode = "USER_PROJECT_NOT_EXIST"
    private static let maxRetryAttempts = 3

    static func throwError(
        issue: String,
        stack: [String],
        type: BugType? = nil,
        severity: BugSeverity? = nil,
        metadata: [String: Any]? = nil,
        sessionId: String? = nil
    ) async {
        // Every report — manual or a crash persisted on a previous run —
        // passes through here, so this is the one place filtering happens.
        let keys = LerixKeys.shared
        let candidate = LerixErrorEvent(message: issue, stack: stack, type: type, severity: severity, metadata: metadata)
        guard let event = LerixErrorFilter.apply(
            candidate,
            ignoreErrors: keys.ignoreErrors,
            ignoreErrorPatterns: keys.ignoreErrorPatterns,
            beforeSend: keys.beforeSend
        ) else {
            if keys.debug { print("[Lerix] Error dropped by ignoreErrors/beforeSend: \(issue)") }
            return
        }

        do {
            try await send(
                issue: event.message,
                stack: event.stack,
                type: event.type,
                severity: event.severity,
                metadata: event.metadata,
                sessionId: sessionId ?? LerixAnalytics.shared.sessionId,
                attempt: 1
            )
        } catch {
            if LerixKeys.shared.debug {
                print("[Lerix] Failed to report error after retries: \(error)")
            }
        }
    }

    private static func send(
        issue: String,
        stack: [String],
        type: BugType?,
        severity: BugSeverity?,
        metadata: [String: Any]?,
        sessionId: String?,
        attempt: Int
    ) async throws {
        guard let userId = LerixInit.existingUserId() else {
            _ = try await LerixInit.ensureUserId()
            try await send(issue: issue, stack: stack, type: type, severity: severity, metadata: metadata, sessionId: sessionId, attempt: attempt)
            return
        }

        let device = LerixDeviceInfo.collectDevice()
        let app = LerixDeviceInfo.collectApp()

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
        // Optional DTO field: lets the dashboard compute crash-free sessions.
        if let sessionId = sessionId { body["sessionId"] = sessionId }
        if let type = type { body["type"] = type.rawValue }
        if let severity = severity { body["severity"] = severity.rawValue }

        do {
            _ = try await LerixBackend.post(route: .sendBug, data: body, headers: ["app-user": userId])
        } catch let LerixApiError.server(code, _) where code == userNotRegisteredCode {
            guard attempt < maxRetryAttempts else { throw LerixApiError.server(code: code, message: "user not registered") }
            LerixInit.forgetLocalUser()
            _ = try await LerixInit.ensureUserId()
            try await send(issue: issue, stack: stack, type: type, severity: severity, metadata: metadata, sessionId: sessionId, attempt: attempt + 1)
        }
    }
}
