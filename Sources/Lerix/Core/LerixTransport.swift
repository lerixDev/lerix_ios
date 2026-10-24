import Foundation

/// One HTTP exchange that never throws: `status == nil` means the request
/// didn't get an HTTP response at all (offline, DNS, timeout).
struct LerixHTTPResponse {
    var status: Int?
    var json: [String: Any]?
    /// The `ETag` response header (app-config).
    var etag: String? = nil

    static let network = LerixHTTPResponse(status: nil, json: nil)

    /// `code` (the `SDK_DISABLED` hint) or `error` (`ResponseErrors`).
    var errorCode: String? {
        (json?["code"] as? String) ?? (json?["error"] as? String)
    }

    var retryAfterSeconds: Double? {
        (json?["retryAfterSeconds"] as? NSNumber)?.doubleValue
    }

    /// The status to act on. The legacy gateway routes wrap a backend error
    /// in a 2xx and keep only the body, so a 2xx carrying an error envelope
    /// uses the envelope's `statusCode` (or counts as a server error when it
    /// has none, so nothing is deleted on a guess).
    var effectiveStatus: Int? {
        guard let status = status else { return nil }
        if (200..<300).contains(status), json?["error"] is String || json?["code"] is String {
            return (json?["statusCode"] as? NSNumber)?.intValue ?? 500
        }
        return status
    }

    var warnings: [(code: String, message: String)] {
        guard let raw = json?["warnings"] as? [[String: Any]] else { return [] }
        return raw.map { (($0["code"] as? String) ?? "UNKNOWN", ($0["message"] as? String) ?? "") }
    }

    /// The response body, unwrapped from a `{ "data": … }` envelope if the
    /// gateway added one.
    var payload: [String: Any]? {
        if let data = json?["data"] as? [String: Any] { return data }
        return json
    }
}

/// What to do with an outbox item after one delivery attempt (contract §0).
enum LerixDeliveryOutcome: Equatable {
    /// 2xx: delete it.
    case success
    /// 400 / 413 / 422: it will never succeed; delete it.
    case drop
    /// 401 / 403 / 404 / 429 / 5xx / network: keep it and back off.
    case retry
    /// The `app-user` isn't registered (409, or the backend's 400
    /// `USER_PROJECT_NOT_EXIST`): register again, keep it, retry.
    case reregister
    /// `403 SDK_DISABLED`: keep it; send nothing for that feature until then.
    case disabled(until: Date)
}

enum LerixRetryPolicy {
    static let minBackoff: TimeInterval = 2
    static let maxBackoff: TimeInterval = 300

    static func outcome(for response: LerixHTTPResponse, now: Date = Date()) -> LerixDeliveryOutcome {
        outcome(
            status: response.effectiveStatus,
            errorCode: response.errorCode,
            retryAfterSeconds: response.retryAfterSeconds,
            now: now
        )
    }

    static func outcome(status: Int?, errorCode: String?, retryAfterSeconds: Double?, now: Date = Date()) -> LerixDeliveryOutcome {
        guard let status = status else { return .retry }
        if errorCode == "SDK_DISABLED" {
            let seconds = max(retryAfterSeconds ?? 3600, 1)
            return .disabled(until: now.addingTimeInterval(seconds))
        }
        // The backend's CheckProjectUserGuard answers "user not registered"
        // with a 400 USER_PROJECT_NOT_EXIST (the contract calls it 409), and
        // an app-user from another project with a 403 PROJECT_USER_MISMATCH.
        // Either way the data is fine; the install needs a new app-user.
        if status == 409 || errorCode == "USER_PROJECT_NOT_EXIST" || errorCode == "PROJECT_USER_MISMATCH" {
            return .reregister
        }
        if (200..<300).contains(status) { return .success }
        // A wrong project id is a configuration error (400 PROJECT_NOT_FOUND);
        // keep the data so a fixed release can still deliver it.
        if errorCode == "PROJECT_NOT_FOUND" { return .retry }
        switch status {
        case 400, 413, 422: return .drop
        default: return .retry      // 401 never deletes data; nor do 403/404/409/429/5xx
        }
    }

    /// 2 s doubling to 5 min, ±25% jitter. `jitter` is a random value in 0...1.
    static func backoff(failures: Int, jitter: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponent = Double(max(failures, 1) - 1)
        let base = min(maxBackoff, minBackoff * pow(2, min(exponent, 20)))
        let jittered = base * (0.75 + 0.5 * min(max(jitter, 0), 1))
        return min(maxBackoff, max(minBackoff, jittered))
    }
}

/// The HTTP layer the outbox and config fetches use. A protocol so tests can
/// replay status codes without a server.
protocol LerixTransport {
    func send(
        route: LerixRoute,
        headers: [String: String],
        query: [URLQueryItem],
        body: Data?,
        contentType: String?
    ) async -> LerixHTTPResponse
}

extension LerixTransport {
    func sendJSON(route: LerixRoute, headers: [String: String], body: [String: Any]) async -> LerixHTTPResponse {
        guard let data = LerixJSON.data(from: body) else {
            // An unencodable body can never succeed.
            return LerixHTTPResponse(status: 400, json: ["error": "SDK_INVALID_BODY"])
        }
        return await send(route: route, headers: headers, query: [], body: data, contentType: "application/json")
    }

    func get(route: LerixRoute, headers: [String: String], query: [URLQueryItem] = []) async -> LerixHTTPResponse {
        await send(route: route, headers: headers, query: query, body: nil, contentType: nil)
    }

    /// `multipart/form-data` with one `file` part plus plain text fields.
    func sendMultipart(
        route: LerixRoute,
        headers: [String: String],
        file: Data,
        fileName: String,
        mime: String,
        fields: [String: String]
    ) async -> LerixHTTPResponse {
        let boundary = "lerix-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(file)
        append("\r\n--\(boundary)--\r\n")
        return await send(
            route: route,
            headers: headers,
            query: [],
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }
}

/// The real transport: same base URL, project prefix and `lerix-key` header
/// as `LerixBackend`, but it reports the status instead of throwing.
struct LerixURLSessionTransport: LerixTransport {
    func send(
        route: LerixRoute,
        headers: [String: String],
        query: [URLQueryItem],
        body: Data?,
        contentType: String?
    ) async -> LerixHTTPResponse {
        // Vendor kill switch (contract §2.5). Callers check it first so
        // queued items wait without backoff; this is the backstop.
        if let until = LerixSdkGate.shared.blockedUntil(path: route.path) {
            LerixLog.debug("\(route.method) \(route.path) skipped: SDK disabled until \(until)")
            return .network
        }
        let keys = LerixKeys.shared
        guard !keys.apiKey.isEmpty, !keys.projectId.isEmpty,
              var components = URLComponents(string: "\(keys.url)/\(keys.projectId)/\(route.path)") else {
            return .network
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return .network }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = route.method
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let contentType = contentType { request.setValue(contentType, forHTTPHeaderField: "content-type") }
        request.setValue(keys.apiKey, forHTTPHeaderField: "lerix-key")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        // A conditional request must reach the server, so its 304 does too.
        if headers.keys.contains(where: { $0.lowercased() == "if-none-match" }) {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }

        LerixLog.debug("→ \(route.method) \(url)")
        do {
            let (data, response) = try await LerixBackend.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            LerixLog.debug("← \(status.map(String.init) ?? "?") \(url)")
            let json = data.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            let result = LerixHTTPResponse(status: status, json: json, etag: etag)
            for warning in result.warnings {
                LerixLog.debug("Server warning \(warning.code): \(warning.message)")
            }
            return result
        } catch {
            LerixLog.debug("✕ \(url): \(error.localizedDescription)")
            return .network
        }
    }
}
