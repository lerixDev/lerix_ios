import Foundation

/// A Codable JSON value, so outbox items and cached configs can be written
/// to disk with `JSONEncoder` and turned back into `[String: Any]` for
/// `JSONSerialization` when sent.
enum LerixJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LerixJSON])
    case object([String: LerixJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([LerixJSON].self) { self = .array(value); return }
        self = .object(try container.decode([String: LerixJSON].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Converts a `JSONSerialization`-style value. Returns `nil` for values
    /// JSON can't represent (dates, custom objects, non-finite numbers).
    init?(any value: Any?) {
        guard let value = value.flatMap(LerixJSON.unwrapOptional) else { self = .null; return }
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                let double = number.doubleValue
                guard double.isFinite else { return nil }
                self = .number(double)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var items: [LerixJSON] = []
            for element in array {
                guard let item = LerixJSON(any: element) else { return nil }
                items.append(item)
            }
            self = .array(items)
        case let dict as [String: Any]:
            var items: [String: LerixJSON] = [:]
            for (key, element) in dict {
                guard let item = LerixJSON(any: element) else { return nil }
                items[key] = item
            }
            self = .object(items)
        default:
            return nil
        }
    }

    /// `Any` can hold an `Optional` (e.g. `["coupon": nil as String?]`); treat
    /// a boxed `nil` as JSON null.
    static func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let child = mirror.children.first else { return nil }
        return unwrapOptional(child.value)
    }

    /// The `JSONSerialization` form. Whole numbers come back as `Int` so they
    /// serialize without a trailing `.0` (epoch-millisecond `ts`, counts).
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return Int64(value) }
            return value
        case .string(let value): return value
        case .array(let value): return value.map { $0.anyValue }
        case .object(let value): return value.mapValues { $0.anyValue }
        }
    }

    var objectValue: [String: LerixJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> LerixJSON? {
        objectValue?[key]
    }
}

extension LerixJSON {
    /// `[String: Any]` → JSON data, used for request bodies.
    static func data(from object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object)
    }
}
