import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum LerixEmailMode: String {
    case hidden
    case optional
    case required
}

public enum LerixScreenshotMode: String {
    case hidden
    case optional
}

/// Per-call overrides for `Lerix.feedback.show` (contract §7). Anything
/// left `nil` comes from the dashboard's feedback settings.
public struct LerixFeedbackOptions {
    /// Only offer these label keys (in this order).
    public var labels: [String]?
    public var email: LerixEmailMode?
    public var screenshot: LerixScreenshotMode?
    /// Prefills the email step (else the `setUserEmail` value).
    public var prefillEmail: String?
    /// Extra JSON-serialisable data sent with the feedback (≤ 50 keys, ≤ 16 KB).
    public var custom: [String: Any]?

    public init(
        labels: [String]? = nil,
        email: LerixEmailMode? = nil,
        screenshot: LerixScreenshotMode? = nil,
        prefillEmail: String? = nil,
        custom: [String: Any]? = nil
    ) {
        self.labels = labels
        self.email = email
        self.screenshot = screenshot
        self.prefillEmail = prefillEmail
        self.custom = custom
    }
}

public struct LerixFeedbackResult {
    /// The user sent it (it may still be queued for delivery).
    public let submitted: Bool
    /// The server id, when it was delivered right away.
    public let id: String?
    /// The client id the server dedupes on.
    public let clientId: String?

    static let cancelled = LerixFeedbackResult(submitted: false, id: nil, clientId: nil)
}

public enum LerixFeedbackError: Error {
    case emptyMessage
    case invalidEmail
    case disabled
}

/// A label as configured in the dashboard.
struct LerixFeedbackLabel: Codable, Equatable {
    var key: String
    var title: [String: String]
    var color: String?
    var hidden: Bool

    init(key: String, title: [String: String], color: String? = nil, hidden: Bool = false) {
        self.key = key
        self.title = title
        self.color = color
        self.hidden = hidden
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = (try? c.decode([String: String].self, forKey: .title)) ?? [:]
        color = try? c.decode(String.self, forKey: .color)
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
    }
}

/// `GET /plugin/feedback/config` (contract §1.1), cached for 24 h.
struct LerixFeedbackConfig: Codable, Equatable {
    var enabled: Bool
    var email: String
    var screenshot: String
    var maxScreenshots: Int
    var maxMessageLength: Int
    var labels: [LerixFeedbackLabel]

    static let defaults = LerixFeedbackConfig(
        enabled: true,
        email: "optional",
        screenshot: "optional",
        maxScreenshots: 3,
        maxMessageLength: 4000,
        labels: [
            LerixFeedbackLabel(key: "bug", title: ["en": "Bug", "ar": "خطأ"], color: "#E5484D"),
            LerixFeedbackLabel(key: "improvement", title: ["en": "Improvement", "ar": "تحسين"], color: "#3E63DD"),
            LerixFeedbackLabel(key: "praise", title: ["en": "Praise", "ar": "إشادة"], color: "#30A46C"),
        ]
    )

    init(enabled: Bool, email: String, screenshot: String, maxScreenshots: Int, maxMessageLength: Int, labels: [LerixFeedbackLabel]) {
        self.enabled = enabled
        self.email = email
        self.screenshot = screenshot
        self.maxScreenshots = maxScreenshots
        self.maxMessageLength = maxMessageLength
        self.labels = labels
    }

    init(from decoder: Decoder) throws {
        let d = Self.defaults
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        email = (try? c.decode(String.self, forKey: .email)) ?? d.email
        screenshot = (try? c.decode(String.self, forKey: .screenshot)) ?? d.screenshot
        maxScreenshots = min(max((try? c.decode(Int.self, forKey: .maxScreenshots)) ?? d.maxScreenshots, 0), 5)
        maxMessageLength = max((try? c.decode(Int.self, forKey: .maxMessageLength)) ?? d.maxMessageLength, 1)
        labels = (try? c.decode([LerixFeedbackLabel].self, forKey: .labels)) ?? d.labels
    }
}

/// The settings one feedback flow runs with: dashboard config + call options.
struct LerixFeedbackSettings {
    var emailMode: LerixEmailMode
    var screenshotMode: LerixScreenshotMode
    var maxScreenshots: Int
    var maxMessageLength: Int
    var labels: [LerixFeedbackLabel]
    var prefillEmail: String?
    var custom: [String: Any]?

    init(config: LerixFeedbackConfig, options: LerixFeedbackOptions, storedEmail: String?) {
        emailMode = options.email ?? LerixEmailMode(rawValue: config.email) ?? .optional
        screenshotMode = options.screenshot ?? LerixScreenshotMode(rawValue: config.screenshot) ?? .optional
        maxScreenshots = screenshotMode == .hidden ? 0 : config.maxScreenshots
        maxMessageLength = config.maxMessageLength
        let visible = config.labels.filter { !$0.hidden }
        if let keys = options.labels {
            labels = keys.compactMap { key in
                visible.first { $0.key == key } ?? config.labels.first { $0.key == key }
                    ?? LerixFeedbackLabel(key: key, title: [:])
            }
        } else {
            labels = visible
        }
        prefillEmail = options.prefillEmail ?? storedEmail
        custom = options.custom
    }
}

/// A screenshot ready to attach.
struct LerixScreenshotData {
    var data: Data
    var mime: String
    var width: Int?
    var height: Int?

    /// Sniffs PNG / JPEG / WebP (the server checks magic bytes too) and reads
    /// the pixel size.
    init?(data: Data) {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            mime = "image/png"
        } else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            mime = "image/jpeg"
        } else if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            mime = "image/webp"
        } else {
            return nil
        }
        self.data = data
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        }
    }

    var fileExtension: String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        default: return "png"
        }
    }
}

/// In-app feedback (contract §1 and §7): the built-in UI on iOS (a simpler
/// sheet on macOS), plus a headless `submit` for your own UI.
public final class LerixFeedback {
    public static let shared = LerixFeedback(store: .shared, outbox: .shared, transport: LerixURLSessionTransport())

    static let configTTL: TimeInterval = 24 * 3600
    static let maxCustomKeys = 50
    static let maxCustomBytes = 16 * 1024
    static let maxScreenshotBytes = 5 * 1024 * 1024

    let store: LerixStore
    let outbox: LerixOutbox
    let transport: LerixTransport

    init(store: LerixStore, outbox: LerixOutbox, transport: LerixTransport) {
        self.store = store
        self.outbox = outbox
        self.transport = transport
    }

    // MARK: - Public API

    /// Prefills the email step (and is used by `submit` when no email is
    /// given). Pass `nil` to forget it.
    public func setUserEmail(_ email: String?) {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setString(LerixStoreKey.userEmail, (trimmed?.isEmpty == false) ? trimmed : nil)
    }

    var userEmail: String? { store.string(LerixStoreKey.userEmail) }

    /// Headless submit for your own UI. The feedback goes through the durable
    /// outbox: when the device is offline it is kept and sent later, and the
    /// result's `id` is `nil`. `screenshots` are PNG/JPEG/WebP bytes (≤ 5 MB
    /// each, up to 5).
    @discardableResult
    public func submit(
        message: String,
        labels: [String] = [],
        email: String? = nil,
        screenshots: [Data] = [],
        custom: [String: Any]? = nil
    ) async throws -> LerixFeedbackResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LerixFeedbackError.emptyMessage }
        let resolvedEmail = (email ?? userEmail)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedEmail = resolvedEmail, !resolvedEmail.isEmpty, !Self.isValidEmail(resolvedEmail) {
            throw LerixFeedbackError.invalidEmail
        }
        let config = await config()
        guard config.enabled else { throw LerixFeedbackError.disabled }

        let shots = screenshots.prefix(5).compactMap { data -> LerixScreenshotData? in
            guard data.count <= Self.maxScreenshotBytes, let shot = LerixScreenshotData(data: data) else {
                LerixLog.debug("Screenshot skipped: not PNG/JPEG/WebP, or over 5 MB")
                return nil
            }
            return shot
        }
        guard let item = enqueue(
            message: String(trimmed.prefix(config.maxMessageLength)),
            labels: labels,
            email: (resolvedEmail?.isEmpty == false) ? resolvedEmail : nil,
            screenshots: Array(shots),
            custom: custom
        ) else {
            return .cancelled
        }
        let clientId = item.payload["clientId"]?.stringValue
        let id = await outbox.deliverFeedbackNow(itemId: item.id)
        return LerixFeedbackResult(submitted: true, id: id, clientId: clientId)
    }

    // MARK: - Internal

    /// The cached config (24 h), or the contract defaults when there is none
    /// yet. A stale cache is refreshed in the background, so showing the UI
    /// never waits on the network.
    func config() async -> LerixFeedbackConfig {
        if isConfigStale { Task { await refreshConfig() } }
        return cachedConfig() ?? .defaults
    }

    var isConfigStale: Bool {
        guard cachedConfig() != nil, let at = store.date(LerixStoreKey.feedbackConfigAt) else { return true }
        return Date().timeIntervalSince(at) >= Self.configTTL
    }

    private let refreshLock = NSLock()
    private var refreshing = false

    /// Fetches the config when stale (called after registration, too).
    func refreshConfig() async {
        guard isConfigStale, beginRefresh() else { return }
        _ = await fetchConfig()
        endRefresh()
    }

    private func beginRefresh() -> Bool {
        refreshLock.lock(); defer { refreshLock.unlock() }
        if refreshing { return false }
        refreshing = true
        return true
    }

    private func endRefresh() {
        refreshLock.lock(); refreshing = false; refreshLock.unlock()
    }

    func cachedConfig() -> LerixFeedbackConfig? {
        guard let raw = store.get(LerixStoreKey.feedbackConfig), let data = try? JSONEncoder().encode(raw) else { return nil }
        return try? JSONDecoder().decode(LerixFeedbackConfig.self, from: data)
    }

    private func fetchConfig() async -> LerixFeedbackConfig? {
        guard !outbox.isDisabled(.feedback), let userId = await outbox.userIdProvider() else { return nil }
        let response = await transport.get(route: .feedbackConfig, headers: ["app-user": userId])
        switch LerixRetryPolicy.outcome(for: response) {
        case .success:
            guard let payload = response.payload,
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let config = try? JSONDecoder().decode(LerixFeedbackConfig.self, from: data),
                  let json = try? JSONDecoder().decode(LerixJSON.self, from: data) else { return nil }
            store.set(LerixStoreKey.feedbackConfig, json)
            store.setDate(LerixStoreKey.feedbackConfigAt, Date())
            return config
        case .disabled(let until):
            store.setDate(LerixStoreKey.disabledUntil(.feedback), until)
            return nil
        case .reregister:
            await outbox.reregister()
            return nil
        default:
            return nil
        }
    }

    /// Writes the feedback (and its screenshots) to the outbox and schedules
    /// delivery.
    func enqueue(
        message: String,
        labels: [String],
        email: String?,
        screenshots: [LerixScreenshotData],
        custom: [String: Any]?
    ) -> LerixOutboxItem? {
        let body = Self.body(message: message, labels: labels, email: email, custom: custom)
        guard let payload = LerixJSON(any: body) else { return nil }
        var attachments: [LerixOutboxAttachment] = []
        for shot in screenshots {
            guard let file = outbox.storeAttachment(shot.data, fileExtension: shot.fileExtension) else { continue }
            attachments.append(LerixOutboxAttachment(file: file, mime: shot.mime, width: shot.width, height: shot.height))
        }
        let item = LerixOutboxItem(kind: .feedback, payload: payload, attachments: attachments)
        guard outbox.enqueue(item) else { return nil }
        outbox.scheduleDrain(after: 0)
        return item
    }

    /// The `POST /plugin/feedback` body without `attachmentIds` (contract §1.3).
    static func body(message: String, labels: [String], email: String?, custom: [String: Any]?) -> [String: Any] {
        let app = LerixDeviceInfo.collectApp()
        var body: [String: Any] = [
            "clientId": LerixIds.make(),
            "message": message,
            "labels": labels,
            "platform": LerixPlatform.value,
            "appVersion": app.version ?? "0.0.0",
            "buildNumber": app.buildNo ?? "0",
            "environment": LerixKeys.shared.environment,
            "device": deviceInfo(),
            "app": [
                "name": app.name ?? "unknown",
                "bundleId": app.package ?? "unknown",
                "version": app.version ?? "0.0.0",
                "build": app.buildNo ?? "0",
            ],
            "breadcrumbs": LerixBreadcrumbs.shared.snapshot(),
        ]
        if let email = email { body["email"] = email }
        if let sessionId = LerixAnalytics.shared.sessionId { body["sessionId"] = sessionId }
        if let custom = sanitizeCustom(custom) { body["custom"] = custom }
        return body
    }

    static func deviceInfo() -> [String: Any] {
        var screen: [String: Any] = [:]
        #if canImport(UIKit)
        let native = UIScreen.main.nativeBounds
        screen = ["width": Int(native.width), "height": Int(native.height), "pixelRatio": Double(UIScreen.main.nativeScale)]
        #elseif canImport(AppKit)
        if let main = NSScreen.main {
            let scale = main.backingScaleFactor
            screen = ["width": Int(main.frame.width * scale), "height": Int(main.frame.height * scale), "pixelRatio": Double(scale)]
        }
        #endif
        return [
            "model": LerixPlatform.deviceModel,
            "osName": LerixPlatform.osName,
            "osVersion": LerixPlatform.osVersion,
            "locale": LerixPlatform.locale,
            "timeZone": TimeZone.current.identifier,
            "screen": screen,
            "isPhysical": !LerixEnvironment.isSimulator,
        ]
    }

    /// ≤ 50 keys (sorted order), JSON-serialisable values, ≤ 16 KB encoded;
    /// otherwise dropped with a debug log.
    static func sanitizeCustom(_ custom: [String: Any]?) -> [String: Any]? {
        guard let custom = custom, !custom.isEmpty else { return nil }
        var result: [String: Any] = [:]
        for key in custom.keys.sorted() {
            guard result.count < maxCustomKeys else {
                LerixLog.debug("Feedback custom: more than \(maxCustomKeys) keys; \"\(key)\" dropped")
                continue
            }
            guard let value = LerixJSON(any: custom[key]) else {
                LerixLog.debug("Feedback custom: \"\(key)\" is not JSON-serialisable; dropped")
                continue
            }
            result[key] = value.anyValue
        }
        guard let data = LerixJSON.data(from: result), data.count <= maxCustomBytes else {
            LerixLog.debug("Feedback custom data is over 16 KB; dropped")
            return nil
        }
        return result.isEmpty ? nil : result
    }

    static func isValidEmail(_ email: String) -> Bool {
        email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }
}
