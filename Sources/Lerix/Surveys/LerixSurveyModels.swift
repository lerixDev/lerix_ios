import Foundation

/// The survey types this SDK can show.
public enum LerixSurveyType: String, Equatable {
    /// Net Promoter Score: a fixed 0–10 scale.
    case nps
    /// Rating (CSAT): 2–10 choices set in the dashboard.
    case rating
}

/// The group an answer falls in. NPS: `detractor` (0–6), `passive` (7–8),
/// `promoter` (9–10). Rating: the choice's `negative`, `neutral` or `positive`.
public enum LerixSurveyGroup: String, Equatable, CaseIterable {
    case detractor, passive, promoter
    case negative, neutral, positive

    static func nps(_ score: Int) -> LerixSurveyGroup {
        score <= 6 ? .detractor : score <= 8 ? .passive : .promoter
    }

    static let npsGroups: [LerixSurveyGroup] = [.detractor, .passive, .promoter]
    static let ratingGroups: [LerixSurveyGroup] = [.negative, .neutral, .positive]
}

/// How a survey looks, set per survey in the dashboard, with its labels in
/// the UI language. Unknown `style` / `shape` / `colorMode` values are kept
/// as sent; the built-in UI falls back to its defaults for them.
public struct LerixSurveyAppearance: Equatable {
    /// NPS: `numbers`. Rating: `stars`, `hearts`, `emoji`, `thumbs` or `numbers`.
    public var style: String?
    /// `rounded`, `circle`, `square` or `pill`.
    public var shape: String?
    /// `accent`, `groups` (NPS) or `options` (rating).
    public var colorMode: String?
    /// `#RRGGBB`, or `nil` to use the app's colour.
    public var accent: String?
    /// NPS `colorMode: "groups"`: `#RRGGBB` per `detractor` / `passive` / `promoter`.
    public var groupColors: [LerixSurveyGroup: String]
    public var lowLabel: String?
    public var highLabel: String?
    /// Whether the labels under the choices are shown. Default `true`.
    public var showLabels: Bool

    public init(
        style: String? = nil,
        shape: String? = nil,
        colorMode: String? = nil,
        accent: String? = nil,
        groupColors: [LerixSurveyGroup: String] = [:],
        lowLabel: String? = nil,
        highLabel: String? = nil,
        showLabels: Bool = true
    ) {
        self.style = style
        self.shape = shape
        self.colorMode = colorMode
        self.accent = accent
        self.groupColors = groupColors
        self.lowLabel = lowLabel
        self.highLabel = highLabel
        self.showLabels = showLabels
    }
}

/// One choice of a rating survey, with its label in the UI language.
public struct LerixSurveyChoice: Equatable, Identifiable {
    public let id: String
    /// 0–100, stored as the response's `score`.
    public let value: Int
    public let group: LerixSurveyGroup
    public let label: String?
    public let emoji: String?
    /// `#RRGGBB` or `nil`.
    public let color: String?
}

/// `appearance` as sent by the server (labels not yet localized).
struct LerixSurveyRawAppearance: Equatable {
    var style: String?
    var shape: String?
    var colorMode: String?
    var accent: String?
    var groupColors: [LerixSurveyGroup: String] = [:]
    var lowLabel: [String: String]?
    var highLabel: [String: String]?
    var showLabels: Bool?

    func localized(_ ui: LerixUI = .shared) -> LerixSurveyAppearance {
        LerixSurveyAppearance(
            style: style,
            shape: shape,
            colorMode: colorMode,
            accent: accent,
            groupColors: groupColors,
            lowLabel: ui.localized(lowLabel),
            highLabel: ui.localized(highLabel),
            showLabels: showLabels ?? true
        )
    }
}

/// A rating option as sent by the server.
struct LerixSurveyOption: Equatable {
    var id: String
    var value: Int
    var group: LerixSurveyGroup
    var label: [String: String]?
    var emoji: String?
    var color: String?

    func localized(_ ui: LerixUI = .shared) -> LerixSurveyChoice {
        LerixSurveyChoice(id: id, value: value, group: group, label: ui.localized(label), emoji: emoji, color: color)
    }
}

/// One survey from `GET /plugin/surveys/config` (contract §2.1, plan §4.1).
struct LerixSurvey: Equatable {
    var id: String
    var type: String
    var key: String?
    var question: [String: String]
    var followUp: [String: [String: String]]?
    var thanks: [String: [String: String]]?
    var appearance: LerixSurveyRawAppearance
    /// Rating only, in display order.
    var options: [LerixSurveyOption]
    var sampleRate: Double
    var frequencyDays: Double
    var initialDelayDays: Double
    var minAppStarts: Int
    var dismissCooldownDays: Double

    init(
        id: String,
        type: String = "nps",
        key: String? = nil,
        question: [String: String] = [:],
        followUp: [String: [String: String]]? = nil,
        thanks: [String: [String: String]]? = nil,
        appearance: LerixSurveyRawAppearance = LerixSurveyRawAppearance(),
        options: [LerixSurveyOption] = [],
        sampleRate: Double = 1,
        frequencyDays: Double? = nil,
        initialDelayDays: Double? = nil,
        minAppStarts: Int? = nil,
        dismissCooldownDays: Double? = nil
    ) {
        let rating = type == LerixSurveyType.rating.rawValue
        self.id = id
        self.type = type
        self.key = key
        self.question = question
        self.followUp = followUp
        self.thanks = thanks
        self.appearance = appearance
        self.options = options
        self.sampleRate = sampleRate
        self.frequencyDays = frequencyDays ?? (rating ? 30 : 90)
        self.initialDelayDays = initialDelayDays ?? (rating ? 0 : 7)
        self.minAppStarts = minAppStarts ?? (rating ? 0 : 3)
        self.dismissCooldownDays = dismissCooldownDays ?? (rating ? 7 : 14)
    }

    var rules: LerixSurveyRules {
        LerixSurveyRules(
            sampleRate: sampleRate,
            frequencyDays: frequencyDays,
            initialDelayDays: initialDelayDays,
            minAppStarts: minAppStarts,
            dismissCooldownDays: dismissCooldownDays
        )
    }

    var isRating: Bool { type == LerixSurveyType.rating.rawValue }
}

// MARK: - Lossy parsing

/// Reads `GET /plugin/surveys/config` the way every Lerix SDK does (plan
/// §4.1): an entry that can't be read is skipped and the rest are kept, a
/// rating with fewer than two readable options is skipped, a bad field value
/// falls back to its default, and types this SDK doesn't know are kept (and
/// never shown).
enum LerixSurveyParser {
    private static let hexColor = try! NSRegularExpression(pattern: "^#[0-9a-fA-F]{6}$")

    static func surveys(from payload: LerixJSON?) -> [LerixSurvey] {
        guard case .array(let list)? = payload?["surveys"] else { return [] }
        return list.compactMap(survey)
    }

    static func survey(_ entry: LerixJSON) -> LerixSurvey? {
        guard let s = entry.objectValue, let id = s["id"]?.stringValue else { return nil }
        let type = s["type"]?.stringValue ?? LerixSurveyType.nps.rawValue
        let rating = type == LerixSurveyType.rating.rawValue
        let options = rating ? self.options(s["options"]) : []
        if rating, options.count < 2 { return nil }
        return LerixSurvey(
            id: id,
            type: type,
            key: s["key"]?.stringValue,
            question: text(s["question"]) ?? [:],
            followUp: textGroups(s["followUp"]),
            thanks: textGroups(s["thanks"]),
            appearance: appearance(s["appearance"]),
            options: options,
            sampleRate: number(s["sampleRate"]) ?? 1,
            frequencyDays: number(s["frequencyDays"]),
            initialDelayDays: number(s["initialDelayDays"]),
            minAppStarts: number(s["minAppStarts"]).map { Int($0) },
            dismissCooldownDays: number(s["dismissCooldownDays"])
        )
    }

    /// Known fields only; a bad value is dropped (falls back to the default) rather than failing the survey.
    static func appearance(_ raw: LerixJSON?) -> LerixSurveyRawAppearance {
        guard let a = raw?.objectValue else { return LerixSurveyRawAppearance() }
        var out = LerixSurveyRawAppearance()
        out.style = a["style"]?.stringValue
        out.shape = a["shape"]?.stringValue
        out.colorMode = a["colorMode"]?.stringValue
        out.accent = color(a["accent"])
        if let groups = a["groupColors"]?.objectValue {
            for group in LerixSurveyGroup.npsGroups {
                if let c = color(groups[group.rawValue]) { out.groupColors[group] = c }
            }
        }
        out.lowLabel = text(a["lowLabel"])
        out.highLabel = text(a["highLabel"])
        out.showLabels = a["showLabels"]?.boolValue
        return out
    }

    static func options(_ raw: LerixJSON?) -> [LerixSurveyOption] {
        guard case .array(let list)? = raw else { return [] }
        var out: [LerixSurveyOption] = []
        var ids = Set<String>()
        for item in list {
            guard let o = item.objectValue, let id = o["id"]?.stringValue, !ids.contains(id) else { continue }
            guard let value = number(o["value"]), value.rounded() == value, abs(value) < 1e15,
                  let groupName = o["group"]?.stringValue,
                  let group = LerixSurveyGroup(rawValue: groupName), LerixSurveyGroup.ratingGroups.contains(group) else { continue }
            ids.insert(id)
            let emoji = o["emoji"]?.stringValue
            out.append(LerixSurveyOption(
                id: id,
                value: Int(value),
                group: group,
                label: text(o["label"]),
                emoji: emoji?.isEmpty == false ? emoji : nil,
                color: color(o["color"])
            ))
        }
        return out
    }

    /// `#RRGGBB` only, so every platform reads it the same.
    static func color(_ raw: LerixJSON?) -> String? {
        guard let value = raw?.stringValue else { return nil }
        return hexColor.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil ? value : nil
    }

    /// A localized text map with its non-empty strings, or `nil` when none.
    static func text(_ raw: LerixJSON?) -> [String: String]? {
        guard let o = raw?.objectValue else { return nil }
        var out: [String: String] = [:]
        for (key, value) in o {
            if let s = value.stringValue, !s.isEmpty { out[key] = s }
        }
        return out.isEmpty ? nil : out
    }

    static func textGroups(_ raw: LerixJSON?) -> [String: [String: String]]? {
        guard let o = raw?.objectValue else { return nil }
        var out: [String: [String: String]] = [:]
        for (key, value) in o {
            if let t = text(value) { out[key] = t }
        }
        return out
    }

    /// A finite number, or a numeric string; anything else is `nil` (the field's default).
    static func number(_ raw: LerixJSON?) -> Double? {
        switch raw {
        case .number(let value)?: return value.isFinite ? value : nil
        case .string(let value)?:
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let parsed = Double(trimmed), parsed.isFinite else { return nil }
            return parsed
        default: return nil
        }
    }
}

/// The rating choice an answer names: its id first, else its value.
func lerixFindChoice(_ choices: [LerixSurveyChoice], _ answer: String) -> LerixSurveyChoice? {
    if let byId = choices.first(where: { $0.id == answer }) { return byId }
    let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let n = Double(trimmed), n.rounded() == n, abs(n) < 1e15 else { return nil }
    return lerixFindChoice(choices, Int(n))
}

func lerixFindChoice(_ choices: [LerixSurveyChoice], _ answer: Int) -> LerixSurveyChoice? {
    choices.first(where: { $0.value == answer })
}
