import Foundation

/// An error report about to be sent to Lerix — what `beforeSend` receives
/// and may modify. Mirrors the error event passed to `beforeSend` in every
/// other Lerix SDK.
public struct LerixErrorEvent {
    public var message: String
    public var stack: [String]
    public var type: BugType?
    public var severity: BugSeverity?
    public var metadata: [String: Any]?

    public init(
        message: String,
        stack: [String] = [],
        type: BugType? = nil,
        severity: BugSeverity? = nil,
        metadata: [String: Any]? = nil
    ) {
        self.message = message
        self.stack = stack
        self.type = type
        self.severity = severity
        self.metadata = metadata
    }
}

/// Client-side error filtering, applied at the single point every report
/// goes through (`ErrorsHandler.throwError`): manual `throwError` calls and
/// crashes persisted to disk and reported on the next launch alike.
///
/// Order: `ignoreErrors` / `ignoreErrorPatterns` first, then `beforeSend`.
/// There are deliberately no built-in default patterns — noise defaults live
/// on the server.
enum LerixErrorFilter {
    /// Returns the event to send, or `nil` if it should be dropped.
    static func apply(
        _ event: LerixErrorEvent,
        ignoreErrors: [String],
        ignoreErrorPatterns: [NSRegularExpression],
        beforeSend: ((LerixErrorEvent) -> LerixErrorEvent?)?
    ) -> LerixErrorEvent? {
        if isIgnored(event.message, ignoreErrors: ignoreErrors, ignoreErrorPatterns: ignoreErrorPatterns) {
            return nil
        }
        guard let beforeSend = beforeSend else { return event }
        return beforeSend(event)
    }

    /// `ignoreErrors` entries match as case-insensitive substrings of the
    /// message (empty entries are skipped, so they can't drop everything);
    /// `ignoreErrorPatterns` match if the regex finds a match anywhere in it.
    static func isIgnored(
        _ message: String,
        ignoreErrors: [String],
        ignoreErrorPatterns: [NSRegularExpression]
    ) -> Bool {
        for needle in ignoreErrors where !needle.isEmpty {
            if message.range(of: needle, options: .caseInsensitive) != nil { return true }
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        for pattern in ignoreErrorPatterns {
            if pattern.firstMatch(in: message, options: [], range: range) != nil { return true }
        }
        return false
    }
}
