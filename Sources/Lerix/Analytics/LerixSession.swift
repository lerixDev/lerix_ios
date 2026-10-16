import Foundation

/// Persisted session state. `activeSeconds` counts foreground time only.
struct LerixSessionState: Codable, Equatable {
    var id: String
    var startedAt: Date
    /// When the current foreground stretch began; `nil` while in background.
    var foregroundSince: Date?
    var backgroundedAt: Date?
    var activeSeconds: Double
    /// Last time the SDK saw the app in use (heartbeat), for an app killed
    /// while in the foreground.
    var lastActiveAt: Date
}

/// An automatic event the session logic wants recorded.
struct LerixAutoEvent: Equatable {
    var name: String
    var props: [String: LerixJSON]
    var eventId: String?
    var sessionId: String
    var date: Date
}

/// Session rules (contract §3.2), free of I/O so they can be unit-tested.
///
/// - A session ends after ≥ 30 min in the background; returning sooner
///   continues it, even across a process restart.
/// - `$session_end` is sent on every backgrounding (the app may never come
///   back) with the cumulative foreground duration. Its `eventId` is
///   `end_<sessionId>`, so repeated ends of one session collapse into one row.
/// - An app killed in the foreground has its end detected on the next start.
struct LerixSessionTracker {
    static let timeout: TimeInterval = 30 * 60

    private(set) var state: LerixSessionState?
    var makeId: () -> String = { LerixIds.make() }

    init(state: LerixSessionState?) {
        self.state = state
    }

    static func endEventId(_ sessionId: String) -> String { "end_\(sessionId)" }

    /// Process start while in the foreground.
    mutating func coldStart(now: Date) -> [LerixAutoEvent] {
        var events: [LerixAutoEvent] = []
        if var previous = state {
            if let backgroundedAt = previous.backgroundedAt, now.timeIntervalSince(backgroundedAt) < Self.timeout {
                previous.backgroundedAt = nil
                previous.foregroundSince = now
                previous.lastActiveAt = now
                state = previous
                return []
            }
            if previous.backgroundedAt == nil {
                // Killed (or crashed) in the foreground: its end was never sent.
                let recent = now.timeIntervalSince(previous.lastActiveAt) < 6 * 86_400
                events.append(endEvent(for: previous, until: previous.lastActiveAt, date: recent ? previous.lastActiveAt : now))
            }
        }
        events.append(startNew(now: now, coldStart: true))
        return events
    }

    mutating func foreground(now: Date) -> [LerixAutoEvent] {
        guard var current = state else { return [startNew(now: now, coldStart: false)] }
        guard let backgroundedAt = current.backgroundedAt else {
            // Already in the foreground (duplicate notification).
            return []
        }
        if now.timeIntervalSince(backgroundedAt) >= Self.timeout {
            // Its end was sent when it went to the background.
            return [startNew(now: now, coldStart: false)]
        }
        current.backgroundedAt = nil
        current.foregroundSince = now
        current.lastActiveAt = now
        state = current
        return []
    }

    mutating func background(now: Date) -> [LerixAutoEvent] {
        guard var current = state, current.backgroundedAt == nil else { return [] }
        if let since = current.foregroundSince { current.activeSeconds += max(0, now.timeIntervalSince(since)) }
        current.foregroundSince = nil
        current.backgroundedAt = now
        current.lastActiveAt = now
        state = current
        return [endEvent(for: current, until: nil, date: now)]
    }

    /// Records activity, so a foreground kill reports a sensible duration.
    mutating func heartbeat(now: Date) {
        guard var current = state, current.backgroundedAt == nil else { return }
        current.lastActiveAt = now
        state = current
    }

    private mutating func startNew(now: Date, coldStart: Bool) -> LerixAutoEvent {
        let session = LerixSessionState(
            id: makeId(),
            startedAt: now,
            foregroundSince: now,
            backgroundedAt: nil,
            activeSeconds: 0,
            lastActiveAt: now
        )
        state = session
        return LerixAutoEvent(name: "$session_start", props: ["coldStart": .bool(coldStart)], eventId: nil, sessionId: session.id, date: now)
    }

    /// `until` closes an open foreground stretch (foreground kill).
    private func endEvent(for session: LerixSessionState, until: Date?, date: Date) -> LerixAutoEvent {
        var seconds = session.activeSeconds
        if let until = until, let since = session.foregroundSince { seconds += max(0, until.timeIntervalSince(since)) }
        return LerixAutoEvent(
            name: "$session_end",
            props: ["duration": .number(seconds.rounded())],
            eventId: Self.endEventId(session.id),
            sessionId: session.id,
            date: date
        )
    }
}
