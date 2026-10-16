import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

private final class LerixBundleToken {}

/// Look and language of the SDK's built-in UI (feedback, NPS).
///
/// - Strings ship in English and Arabic (`Resources/*.lproj/Lerix.strings`);
///   any other language falls back to English. Override individual keys
///   with `setStrings(_:locale:)`.
/// - The language follows the host app's own localization (so an
///   English-only app shows English UI) unless `locale` is set. Arabic lays
///   out right-to-left.
/// - Colours follow the system light/dark mode; the accent is `tintColor`,
///   or the key window's tint when unset.
public final class LerixUI {
    public static let shared = LerixUI()

    /// Language code for the UI (`"en"`, `"ar"`, …); `nil` follows the app.
    public var locale: String? {
        get { lock.lock(); defer { lock.unlock() }; return _locale }
        set { lock.lock(); _locale = newValue; lock.unlock() }
    }

    #if canImport(SwiftUI)
    /// Accent colour for buttons and selections; `nil` uses the app's tint.
    @available(iOS 13.0, macOS 10.15, *)
    public var tintColor: Color? {
        get { lock.lock(); defer { lock.unlock() }; return _tint as? Color }
        set { lock.lock(); _tint = newValue; lock.unlock() }
    }
    #endif

    private let lock = NSLock()
    private var _locale: String?
    private var _tint: Any?
    private var overrides: [String: [String: String]] = [:]
    private var tables: [String: [String: String]] = [:]

    /// Replaces built-in strings. `locale: nil` applies to every language.
    /// Keys are listed in `Resources/en.lproj/Lerix.strings`.
    public func setStrings(_ strings: [String: String], locale: String? = nil) {
        let key = locale.map(Self.baseLanguage) ?? "*"
        lock.lock()
        overrides[key, default: [:]].merge(strings) { _, new in new }
        lock.unlock()
    }

    // MARK: - Internal

    static let resourceBundle: Bundle? = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        // CocoaPods `resource_bundles` → Lerix.bundle next to the code.
        for candidate in [Bundle(for: LerixBundleToken.self), Bundle.main] {
            if let url = candidate.url(forResource: "Lerix", withExtension: "bundle"), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle(for: LerixBundleToken.self)
        #endif
    }()

    static func baseLanguage(_ code: String) -> String {
        let normalized = code.replacingOccurrences(of: "_", with: "-").lowercased()
        return normalized.split(separator: "-").first.map(String.init) ?? normalized
    }

    /// The resolved UI language.
    var language: String {
        if let explicit = locale, !explicit.isEmpty { return Self.baseLanguage(explicit) }
        return Self.baseLanguage(Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en")
    }

    var isRightToLeft: Bool {
        Locale.characterDirection(forLanguage: language) == .rightToLeft
    }

    func string(_ key: String) -> String {
        let lang = language
        lock.lock()
        let override = overrides[lang]?[key] ?? overrides["*"]?[key]
        lock.unlock()
        if let override = override { return override }
        return table(lang)[key] ?? table("en")[key] ?? key
    }

    func string(_ key: String, _ argument: String) -> String {
        string(key).replacingOccurrences(of: "%@", with: argument)
    }

    /// Server-provided text such as `{"en": "Bug", "ar": "خطأ"}`:
    /// the UI language, then English.
    func localized(_ map: [String: String]?) -> String? {
        guard let map = map else { return nil }
        let value = map[language] ?? map["en"]
        return (value?.isEmpty == false) ? value : nil
    }

    private func table(_ lang: String) -> [String: String] {
        lock.lock()
        if let cached = tables[lang] { lock.unlock(); return cached }
        lock.unlock()
        var loaded: [String: String] = [:]
        if let bundle = Self.resourceBundle,
           let path = bundle.path(forResource: "Lerix", ofType: "strings", inDirectory: nil, forLocalization: lang),
           let dict = NSDictionary(contentsOfFile: path) as? [String: String] {
            loaded = dict
        }
        lock.lock()
        tables[lang] = loaded
        lock.unlock()
        return loaded
    }
}
