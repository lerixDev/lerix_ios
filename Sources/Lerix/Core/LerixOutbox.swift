import Foundation

enum LerixOutboxKind: String, Codable, CaseIterable {
    case event
    case feedback
    case survey

    var feature: LerixFeature {
        switch self {
        case .event: return .analytics
        case .feedback: return .feedback
        case .survey: return .surveys
        }
    }

    init(feature: LerixFeature) {
        switch feature {
        case .analytics: self = .event
        case .feedback: self = .feedback
        case .surveys: self = .survey
        }
    }
}

/// A screenshot waiting to be attached to a feedback item. The local file is
/// kept until the feedback itself is accepted: the server sweeps unlinked
/// uploads after 24 h and scopes them to one `app-user`, so an upload that
/// is too old or was made by a replaced user is sent again.
struct LerixOutboxAttachment: Codable, Equatable {
    var file: String
    var mime: String
    var width: Int?
    var height: Int?
    var uploadedId: String?
    var uploadedAt: Date?
    var uploadedBy: String?
}

struct LerixOutboxItem: Codable {
    var id: String
    var kind: LerixOutboxKind
    var createdAt: Date
    var payload: LerixJSON
    var attachments: [LerixOutboxAttachment]?

    init(id: String = LerixIds.make(), kind: LerixOutboxKind, createdAt: Date = Date(), payload: LerixJSON, attachments: [LerixOutboxAttachment]? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.payload = payload
        self.attachments = attachments
    }

    /// `<kind>_<zero-padded epoch ms>_<id>.json`, so a sorted directory
    /// listing is oldest first.
    var fileName: String {
        let millis = max(0, LerixTime.millis(createdAt))
        return "\(kind.rawValue)_\(String(format: "%015lld", millis))_\(id).json"
    }
}

/// Durable outbox: one JSON file per item, written to a `.tmp` file and
/// renamed into place, so a crash mid-write never leaves a half item.
/// Delivery follows contract §0 (see `LerixRetryPolicy`), with one backoff
/// and one `SDK_DISABLED` deadline per feature.
final class LerixOutbox {
    static let shared = LerixOutbox(
        directory: LerixPaths.root.appendingPathComponent("outbox", isDirectory: true),
        attachmentsDirectory: LerixPaths.root.appendingPathComponent("attachments", isDirectory: true),
        store: .shared,
        transport: LerixURLSessionTransport()
    )

    static let eventMaxAge: TimeInterval = 7 * 86_400
    static let eventMaxBytes = 1_000_000
    static let batchMaxEvents = 100
    /// Below the 512 KB request limit, leaving room for `context`.
    static let batchMaxBytes = 480_000
    /// Re-upload attachments older than this (the server sweeps at 24 h).
    static let attachmentReuseWindow: TimeInterval = 20 * 3600

    let directory: URL
    let attachmentsDirectory: URL
    let store: LerixStore
    let transport: LerixTransport

    /// Returns the registered `app-user` id, registering if needed; `nil`
    /// keeps everything queued.
    var userIdProvider: () async -> String? = { nil }
    /// Called on a "user not registered" answer.
    var reregister: () async -> Void = {}
    /// `context` for `/plugin/events`.
    var eventContext: () -> [String: Any] = { [:] }
    var now: () -> Date = { Date() }

    private let lock = NSLock()
    private var failures: [LerixFeature: Int] = [:]
    private var nextAttempt: [LerixFeature: Date] = [:]
    private var inFlight: [LerixFeature: Task<Void, Never>] = [:]
    private var scheduledTask: Task<Void, Never>?
    private var scheduledFor: Date?
    private var enqueuedEventsSincePrune = 0
    private var deliveredFeedbackIds: [String: String] = [:]

    init(directory: URL, attachmentsDirectory: URL, store: LerixStore, transport: LerixTransport) {
        self.directory = directory
        self.attachmentsDirectory = attachmentsDirectory
        self.store = store
        self.transport = transport
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Storage

    @discardableResult
    func enqueue(_ item: LerixOutboxItem) -> Bool {
        let ok = write(item)
        if ok, item.kind == .event {
            let shouldPrune: Bool = locked {
                enqueuedEventsSincePrune += 1
                if enqueuedEventsSincePrune >= 100 { enqueuedEventsSincePrune = 0; return true }
                return false
            }
            if shouldPrune { pruneEvents() }
        }
        return ok
    }

    /// Overwrites an item in place (used to checkpoint uploaded attachments).
    @discardableResult
    func save(_ item: LerixOutboxItem) -> Bool { write(item) }

    private func write(_ item: LerixOutboxItem) -> Bool {
        guard let data = try? JSONEncoder().encode(item) else { return false }
        let target = directory.appendingPathComponent(item.fileName)
        let temp = directory.appendingPathComponent(item.fileName + ".tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            LerixLog.debug("Outbox write failed: \(error.localizedDescription)")
            return false
        }
    }

    private func fileNames(of kind: LerixOutboxKind) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(kind.rawValue + "_") && $0.hasSuffix(".json") }.sorted()
    }

    func count(of kind: LerixOutboxKind) -> Int { fileNames(of: kind).count }

    /// Oldest first. Unreadable files are deleted.
    func items(of kind: LerixOutboxKind) -> [LerixOutboxItem] {
        fileNames(of: kind).compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let item = try? JSONDecoder().decode(LerixOutboxItem.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return item
        }
    }

    func item(id: String, kind: LerixOutboxKind) -> LerixOutboxItem? {
        items(of: kind).first { $0.id == id }
    }

    /// Deletes the item and any attachment files it still references.
    func remove(_ item: LerixOutboxItem) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.fileName))
        for attachment in item.attachments ?? [] {
            try? FileManager.default.removeItem(at: attachmentsDirectory.appendingPathComponent(attachment.file))
        }
    }

    /// Stores screenshot bytes for a feedback item; returns the file name.
    func storeAttachment(_ data: Data, fileExtension: String) -> String? {
        let name = "\(LerixIds.make()).\(fileExtension)"
        do {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            try data.write(to: attachmentsDirectory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Event cap: 7 days or 1 MB, oldest dropped first.
    func pruneEvents() {
        let cutoff = now().addingTimeInterval(-Self.eventMaxAge)
        var entries: [(url: URL, size: Int)] = []
        for name in fileNames(of: .event) {
            let url = directory.appendingPathComponent(name)
            if let millis = Self.millis(fromFileName: name), Date(timeIntervalSince1970: Double(millis) / 1000) < cutoff {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            entries.append((url, size))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        var index = 0
        while total > Self.eventMaxBytes, index < entries.count {
            try? FileManager.default.removeItem(at: entries[index].url)
            total -= entries[index].size
            index += 1
        }
    }

    static func millis(fromFileName name: String) -> Int64? {
        let parts = name.split(separator: "_")
        guard parts.count >= 3 else { return nil }
        return Int64(parts[1])
    }

    /// Removes every queued analytics event (opt-out).
    func clearEvents() {
        for name in fileNames(of: .event) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Kill switch and backoff

    func disabledUntil(_ feature: LerixFeature) -> Date? {
        guard let until = store.date(LerixStoreKey.disabledUntil(feature)), until > now() else { return nil }
        return until
    }

    func isDisabled(_ feature: LerixFeature) -> Bool { disabledUntil(feature) != nil }

    func backoffRemaining(_ feature: LerixFeature) -> TimeInterval? {
        let next: Date? = locked { nextAttempt[feature] }
        guard let next = next else { return nil }
        let remaining = next.timeIntervalSince(now())
        return remaining > 0 ? remaining : nil
    }

    /// Applies a non-success outcome to the feature's backoff/kill switch.
    private func record(_ outcome: LerixDeliveryOutcome, for feature: LerixFeature) {
        switch outcome {
        case .success, .drop:
            locked { failures[feature] = 0; nextAttempt[feature] = nil }
        case .retry, .reregister:
            locked {
                let count = (failures[feature] ?? 0) + 1
                failures[feature] = count
                nextAttempt[feature] = now().addingTimeInterval(LerixRetryPolicy.backoff(failures: count))
            }
        case .disabled(let until):
            store.setDate(LerixStoreKey.disabledUntil(feature), until)
            LerixLog.debug("Server disabled \(feature.rawValue) until \(until) (SDK_DISABLED)")
        }
    }

    // MARK: - Delivery

    func drainAll() async {
        for feature in LerixFeature.allCases where count(of: LerixOutboxKind(feature: feature)) > 0 {
            await drain(feature)
        }
    }

    /// Sends what is pending for one feature. A call while that feature is
    /// already draining waits for the running drain instead of starting a
    /// second one.
    func drain(_ feature: LerixFeature) async {
        let (task, isNew): (Task<Void, Never>, Bool) = locked {
            if let running = inFlight[feature] { return (running, false) }
            let task = Task { await self.runDrain(feature) }
            inFlight[feature] = task
            return (task, true)
        }
        await task.value
        if isNew { locked { inFlight[feature] = nil } }
    }

    private func runDrain(_ feature: LerixFeature) async {
        let kind = LerixOutboxKind(feature: feature)
        guard count(of: kind) > 0 else { return }
        if isDisabled(feature) { return }
        if backoffRemaining(feature) != nil { return }
        guard let userId = await userIdProvider() else {
            record(.retry, for: feature)
            return
        }
        switch kind {
        case .event: await drainEvents(userId: userId)
        case .feedback: await drainFeedback(userId: userId)
        case .survey: await drainSurveys(userId: userId)
        }
    }

    private func handle(_ outcome: LerixDeliveryOutcome, feature: LerixFeature) async {
        record(outcome, for: feature)
        if outcome == .reregister { await reregister() }
    }

    private func drainEvents(userId: String) async {
        pruneEvents()
        for _ in 0..<20 {
            let pending = items(of: .event)
            guard !pending.isEmpty else { return }
            var batch: [LerixOutboxItem] = []
            var events: [Any] = []
            var bytes = 0
            for item in pending {
                let event = item.payload.anyValue
                let size = (try? JSONSerialization.data(withJSONObject: event).count) ?? 0
                if !batch.isEmpty, bytes + size > Self.batchMaxBytes { break }
                batch.append(item)
                events.append(event)
                bytes += size
                if batch.count >= Self.batchMaxEvents { break }
            }
            let body: [String: Any] = ["context": eventContext(), "events": events]
            let response = await transport.sendJSON(route: .events, headers: ["app-user": userId], body: body)
            let outcome = LerixRetryPolicy.outcome(for: response, now: now())
            switch outcome {
            case .success, .drop:
                // Rejected events are dropped, never retried (contract §3.1).
                if let rejected = response.payload?["rejected"] as? [[String: Any]], !rejected.isEmpty {
                    LerixLog.debug("Server rejected \(rejected.count) event(s): \(rejected)")
                }
                batch.forEach(remove)
                await handle(outcome, feature: .analytics)
            default:
                await handle(outcome, feature: .analytics)
                return
            }
        }
    }

    private func drainSurveys(userId: String) async {
        for item in items(of: .survey) {
            guard let body = item.payload.anyValue as? [String: Any] else { remove(item); continue }
            let response = await transport.sendJSON(route: .surveyResponses, headers: ["app-user": userId], body: body)
            let outcome = LerixRetryPolicy.outcome(for: response, now: now())
            await handle(outcome, feature: .surveys)
            switch outcome {
            case .success, .drop: remove(item)
            default: return
            }
        }
    }

    private func drainFeedback(userId: String) async {
        for item in items(of: .feedback) {
            let outcome = await deliver(feedback: item, userId: userId)
            await handle(outcome, feature: .feedback)
            switch outcome {
            case .success, .drop: continue
            default: return
            }
        }
    }

    /// Uploads (checkpointing each attachment id), then posts the feedback.
    private func deliver(feedback original: LerixOutboxItem, userId: String) async -> LerixDeliveryOutcome {
        var item = original
        var attachments = item.attachments ?? []
        var index = 0
        while index < attachments.count {
            var attachment = attachments[index]
            if let uploadedAt = attachment.uploadedAt, attachment.uploadedId != nil, attachment.uploadedBy == userId,
               now().timeIntervalSince(uploadedAt) < Self.attachmentReuseWindow {
                index += 1
                continue
            }
            let fileURL = attachmentsDirectory.appendingPathComponent(attachment.file)
            guard let data = try? Data(contentsOf: fileURL) else {
                attachments.remove(at: index)
                item.attachments = attachments
                save(item)
                continue
            }
            var fields: [String: String] = [:]
            if let width = attachment.width { fields["width"] = String(width) }
            if let height = attachment.height { fields["height"] = String(height) }
            let response = await transport.sendMultipart(
                route: .feedbackAttachments,
                headers: ["app-user": userId],
                file: data,
                fileName: attachment.file,
                mime: attachment.mime,
                fields: fields
            )
            let outcome = LerixRetryPolicy.outcome(for: response, now: now())
            switch outcome {
            case .success:
                guard let id = response.payload?["id"] as? String else { return .retry }
                attachment.uploadedId = id
                attachment.uploadedAt = now()
                attachment.uploadedBy = userId
                attachments[index] = attachment
                item.attachments = attachments
                save(item)
                index += 1
            case .drop:
                // A rejected image (bad type, too large) shouldn't cost the
                // user their message: drop just this attachment.
                LerixLog.debug("Attachment rejected (\(response.effectiveStatus ?? 0)); sending feedback without it")
                try? FileManager.default.removeItem(at: fileURL)
                attachments.remove(at: index)
                item.attachments = attachments
                save(item)
            default:
                return outcome
            }
        }

        guard var body = item.payload.anyValue as? [String: Any] else {
            remove(item)
            return .drop
        }
        body["attachmentIds"] = attachments.compactMap { $0.uploadedId }
        let response = await transport.sendJSON(route: .feedback, headers: ["app-user": userId], body: body)
        let outcome = LerixRetryPolicy.outcome(for: response, now: now())
        switch outcome {
        case .success:
            if let id = response.payload?["id"] as? String { locked { deliveredFeedbackIds[item.id] = id } }
            remove(item)
        case .drop:
            LerixLog.debug("Feedback rejected (\(response.effectiveStatus ?? 0)): \(response.json ?? [:])")
            remove(item)
        default:
            break
        }
        return outcome
    }

    /// Tries to deliver one feedback item now. Returns the server id when it
    /// was accepted, `nil` when it is still queued.
    func deliverFeedbackNow(itemId: String) async -> String? {
        for _ in 0..<2 {
            if let id = takeDeliveredId(itemId) { return id }
            guard item(id: itemId, kind: .feedback) != nil else { return takeDeliveredId(itemId) }
            await drain(.feedback)
        }
        return takeDeliveredId(itemId)
    }

    private func takeDeliveredId(_ itemId: String) -> String? {
        locked { deliveredFeedbackIds.removeValue(forKey: itemId) }
    }

    // MARK: - Scheduling

    /// Drains after `seconds`, unless a drain is already due sooner.
    func scheduleDrain(after seconds: TimeInterval) {
        let target = now().addingTimeInterval(max(seconds, 0))
        let shouldSchedule: Bool = locked {
            if let scheduled = scheduledFor, scheduled <= target { return false }
            scheduledTask?.cancel()
            scheduledFor = target
            return true
        }
        guard shouldSchedule else { return }
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            self.locked { self.scheduledFor = nil; self.scheduledTask = nil }
            await self.drainAll()
            self.scheduleFollowUp()
        }
        locked { scheduledTask = task }
    }

    /// While anything is pending: retry when its backoff ends, otherwise
    /// every 30 s (events) — or when the kill switch expires.
    func scheduleFollowUp() {
        var wait: TimeInterval?
        for feature in LerixFeature.allCases where count(of: LerixOutboxKind(feature: feature)) > 0 {
            let candidate: TimeInterval
            if let until = disabledUntil(feature) {
                candidate = until.timeIntervalSince(now())
            } else if let remaining = backoffRemaining(feature) {
                candidate = remaining
            } else {
                candidate = 30
            }
            wait = min(wait ?? candidate, candidate)
        }
        if let wait = wait { scheduleDrain(after: max(wait, 1)) }
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
