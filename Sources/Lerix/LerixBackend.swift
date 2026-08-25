import Foundation

/// A backend route — mirrors the `atelerix-api` gateway's controller
/// paths (`:projectId/plugin/...`). `path` excludes the project slug; it's
/// prefixed automatically from `LerixKeys.shared.projectId`.
struct LerixRoute {
    let method: String
    let path: String

    static let ping = LerixRoute(method: "GET", path: "plugin/init/ping")
    static let registerUser = LerixRoute(method: "POST", path: "plugin/init/register-user")
    static let deleteUser = LerixRoute(method: "DELETE", path: "plugin/init/user")
    static let sendBug = LerixRoute(method: "POST", path: "plugin/bugs/create")
    static let registerToken = LerixRoute(method: "POST", path: "plugin/notifications/register-token")
    static let subscribeTopic = LerixRoute(method: "POST", path: "plugin/notifications/subscribe-topic")
    static let unsubscribeTopic = LerixRoute(method: "POST", path: "plugin/notifications/unsubscribe-topic")
}

enum LerixBackendError: Error {
    case invalidURL
    case invalidResponse
}

/// Backend error envelope. The gateway in front of `api.lerix.dev`
/// proxies the real backend's response body as-is but does NOT propagate
/// its HTTP status — a logical failure can still arrive wrapped in a 200/201.
/// The only reliable failure signal is an `error` key in the JSON body, so
/// that's what `LerixBackend` checks instead of the transport status.
enum LerixApiError: Error {
    case server(code: String, message: String)
}

/// HTTP client — mirrors `LerixBackend`/`LerixHelper` in the Flutter
/// SDK. Every request carries the `atelerix-key` header and is scoped under
/// `/{projectId}/...` automatically; callers only supply the route, body,
/// and any extra headers (e.g. `app-user`).
enum LerixBackend {
    static func get(
        route: LerixRoute,
        headers: [String: String] = [:],
        queryItems: [URLQueryItem] = []
    ) async throws -> [String: Any]? {
        try await request(route: route, headers: headers, queryItems: queryItems, body: nil)
    }

    static func post(
        route: LerixRoute,
        data: [String: Any] = [:],
        headers: [String: String] = [:]
    ) async throws -> [String: Any]? {
        try await request(route: route, headers: headers, queryItems: [], body: data)
    }

    static func delete(
        route: LerixRoute,
        headers: [String: String] = [:]
    ) async throws -> [String: Any]? {
        try await request(route: route, headers: headers, queryItems: [], body: nil)
    }

    private static func request(
        route: LerixRoute,
        headers: [String: String],
        queryItems: [URLQueryItem],
        body: [String: Any]?
    ) async throws -> [String: Any]? {
        let keys = LerixKeys.shared
        guard var components = URLComponents(string: "\(keys.url)/\(keys.projectId)/\(route.path)") else {
            throw LerixBackendError.invalidURL
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw LerixBackendError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = route.method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        // Header name is mandated by the backend — do not rename.
        request.setValue(keys.apiKey, forHTTPHeaderField: "atelerix-key")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        if keys.debug {
            print("[Lerix] → \(route.method) \(url)")
        }

        let (data, response) = try await Self.data(for: request)

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if keys.debug {
            print("[Lerix] ← \(status) \(url)")
        }

        let json = data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let errorCode = json?["error"] as? String {
            let message = (json?["message"] as? String) ?? "Request failed"
            throw LerixApiError.server(code: errorCode, message: message)
        }

        guard (200...299).contains(status) else {
            throw LerixApiError.server(code: String(status), message: "Request failed")
        }

        return json
    }

    /// Bridges the completion-handler `URLSession` API into async/await —
    /// `URLSession.data(for:)` is iOS 15+ only, and this package targets
    /// iOS 13+.
    private static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = data, let response = response else {
                    continuation.resume(throwing: LerixBackendError.invalidResponse)
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}
