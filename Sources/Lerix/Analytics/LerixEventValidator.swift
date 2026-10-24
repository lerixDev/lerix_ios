import Foundation

/// Client-side event validation (contract §3.1). Invalid events and props are
/// dropped with a debug log; nothing here throws to the caller.
enum LerixEventValidator {
    static let reservedNames: Set<String> = [
        "$first_open", "$session_start", "$session_end", "$screen_view", "$app_update",
        // Release Control (CONTRACT-release-control §2.4)
        "$update_prompt_shown", "$update_prompt_action", "$maintenance_shown", "$config_applied",
    ]
    static let maxProps = 25
    static let maxStringLength = 1024

    private static let namePattern = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9 _.:-]{1,63}$")
    private static let keyPattern = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_.-]{0,127}$")

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// `allowReserved` is for the SDK's own `$` events; `Lerix.track` passes
    /// `false`, so a host app can't emit (or fake) a reserved name.
    static func isValidName(_ name: String, allowReserved: Bool) -> Bool {
        if name.hasPrefix("$") { return allowReserved && reservedNames.contains(name) }
        return matches(namePattern, name)
    }

    static func isValidKey(_ key: String) -> Bool { matches(keyPattern, key) }

    /// Keeps valid keys with string (truncated to 1024), finite number, bool
    /// or null values; at most 25 keys, chosen in sorted key order so the
    /// result is deterministic. Returns the props and what was dropped.
    static func sanitize(_ props: [String: Any]?) -> (props: [String: LerixJSON], dropped: [String]) {
        guard let props = props else { return ([:], []) }
        var result: [String: LerixJSON] = [:]
        var dropped: [String] = []
        for key in props.keys.sorted() {
            guard isValidKey(key), let value = sanitizeValue(props[key] as Any) else {
                dropped.append(key)
                continue
            }
            guard result.count < maxProps else {
                dropped.append(key)
                continue
            }
            result[key] = value
        }
        return (result, dropped)
    }

    static func sanitizeValue(_ raw: Any) -> LerixJSON? {
        guard let value = LerixJSON.unwrapOptional(raw) else { return .null }
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return .string(String(string.prefix(maxStringLength)))
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let double = number.doubleValue
            return double.isFinite ? .number(double) : nil
        default:
            return nil
        }
    }
}
