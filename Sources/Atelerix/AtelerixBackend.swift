import Foundation

/// Backend routes — mirrors `Routes` in the Flutter SDK. Keep in sync with
/// it; these must stay identical since they hit the exact same backend.
enum AtelerixRoute: String {
    case initApp = "/plugin/init/ping"
    case registerUser = "/plugin/init/register-user"
    case deleteUser = "/plugin/init/user"
    case sendBug = "/plugin/bugs/create"
    case registerNotification = "/plugin/notifications/register-token"
    case subscribeTopic = "/plugin/notifications/subscribe-topic"
    case unsubscribeTopic = "/plugin/notifications/unsubscribe-topic"
}

enum AtelerixBackendError: Error {
    case invalidURL
    case invalidResponse
}

/// Backend API wrapper — mirrors `AtelerixBackend`/`AtelerixHelper` in the
/// Flutter SDK. Every request carries the `atelerix-key` header
/// automatically; callers only supply the route, body, and any extra
/// headers (e.g. `app-user`).
enum AtelerixBackend {
    static func get(
        route: AtelerixRoute,
        headers: [String: String] = [:],
        queryItems: [URLQueryItem] = []
    ) async throws -> [String: Any]? {
        try await request(method: "GET", route: route, headers: headers, queryItems: queryItems, body: nil)
    }

    static func post(
        route: AtelerixRoute,
        data: [String: Any] = [:],
        headers: [String: String] = [:]
    ) async throws -> [String: Any]? {
        try await request(method: "POST", route: route, headers: headers, queryItems: [], body: data)
    }

    static func delete(
        route: AtelerixRoute,
        headers: [String: String] = [:]
    ) async throws -> [String: Any]? {
        try await request(method: "DELETE", route: route, headers: headers, queryItems: [], body: nil)
    }

    private static func request(
        method: String,
        route: AtelerixRoute,
        headers: [String: String],
        queryItems: [URLQueryItem],
        body: [String: Any]?
    ) async throws -> [String: Any]? {
        let keys = AtelerixKeys.shared
        guard var components = URLComponents(string: keys.url + route.rawValue) else {
            throw AtelerixBackendError.invalidURL
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw AtelerixBackendError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(keys.apiKey, forHTTPHeaderField: "atelerix-key")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        if keys.debug {
            print("[Atelerix] → \(method) \(url)")
        }

        let (data, response) = try await Self.data(for: request)

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if keys.debug {
            print("[Atelerix] ← \(status) \(url)")
        }

        let json = data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard (200...299).contains(status) else {
            let code = (json?["error"] as? String) ?? String(status)
            let message = (json?["message"] as? String) ?? "Request failed"
            throw AtelerixApiError.server(code: code, message: message)
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
                    continuation.resume(throwing: AtelerixBackendError.invalidResponse)
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}
