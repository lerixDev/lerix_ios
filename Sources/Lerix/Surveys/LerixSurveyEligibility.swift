import Foundation

/// FNV-1a 32-bit over UTF-8 bytes — identical in every Lerix SDK, so one
/// install lands in the same sample bucket everywhere.
enum LerixFNV {
    static func hash32(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return hash
    }

    /// `(fnv1a32(s) % 10000) / 10000`, in [0, 1).
    static func bucket(_ string: String) -> Double {
        Double(hash32(string) % 10_000) / 10_000
    }
}

/// The survey fields eligibility depends on (contract §2.1).
struct LerixSurveyRules: Equatable {
    var sampleRate: Double
    var frequencyDays: Double
    var initialDelayDays: Double
    var minAppStarts: Int
    var dismissCooldownDays: Double
}

/// Locally persisted history for one survey.
struct LerixSurveyHistory: Equatable {
    var lastShownAt: Date?
    var lastAnsweredAt: Date?
    var lastDismissedAt: Date?
}

struct LerixSurveyEligibility: Equatable {
    var eligible: Bool
    /// Human-readable failing conditions (logged in debug mode).
    var failures: [String]
    var nextDue: Date
}

/// Contract §2.2, the same algorithm in every SDK:
///
///     eligible = appStarts >= minAppStarts
///             && now >= firstStartAt + initialDelayDays
///             && bucket(installId + surveyId) < sampleRate
///             && now >= nextDue
///     nextDue  = lastAnsweredAt  ? lastAnsweredAt  + frequencyDays
///              : lastDismissedAt ? lastDismissedAt + dismissCooldownDays
///              : firstStartAt + (fnv1a32(installId + surveyId + "spread") % (frequencyDays*86400)) s
///
/// With both an answer and a dismissal recorded, the later of the two
/// decides (an answer after a dismissal → frequency; a dismissal after an
/// answer → cooldown).
enum LerixSurveyEligibilityRule {
    static let day: TimeInterval = 86_400

    static func nextDue(
        rules: LerixSurveyRules,
        surveyId: String,
        installId: String,
        firstStartAt: Date,
        history: LerixSurveyHistory
    ) -> Date {
        let answered = history.lastAnsweredAt.map { $0.addingTimeInterval(rules.frequencyDays * day) }
        let dismissed = history.lastDismissedAt.map { $0.addingTimeInterval(rules.dismissCooldownDays * day) }
        switch (history.lastAnsweredAt, history.lastDismissedAt) {
        case let (answeredAt?, dismissedAt?):
            return answeredAt >= dismissedAt ? answered! : dismissed!
        case (_?, nil):
            return answered!
        case (nil, _?):
            return dismissed!
        case (nil, nil):
            let window = UInt64(max(0, (rules.frequencyDays * day).rounded(.down)))
            let offset = window > 0 ? UInt64(LerixFNV.hash32(installId + surveyId + "spread")) % window : 0
            return firstStartAt.addingTimeInterval(TimeInterval(offset))
        }
    }

    static func evaluate(
        rules: LerixSurveyRules,
        surveyId: String,
        installId: String,
        appStarts: Int,
        firstStartAt: Date,
        history: LerixSurveyHistory,
        now: Date
    ) -> LerixSurveyEligibility {
        var failures: [String] = []
        if appStarts < rules.minAppStarts {
            failures.append("appStarts \(appStarts) < minAppStarts \(rules.minAppStarts)")
        }
        let delayEnds = firstStartAt.addingTimeInterval(rules.initialDelayDays * day)
        if now < delayEnds {
            failures.append("initial delay runs until \(LerixTime.iso(delayEnds))")
        }
        let bucket = LerixFNV.bucket(installId + surveyId)
        if !(bucket < rules.sampleRate) {
            failures.append("bucket \(bucket) is not < sampleRate \(rules.sampleRate)")
        }
        let due = nextDue(rules: rules, surveyId: surveyId, installId: installId, firstStartAt: firstStartAt, history: history)
        if now < due {
            failures.append("not due until \(LerixTime.iso(due))")
        }
        return LerixSurveyEligibility(eligible: failures.isEmpty, failures: failures, nextDue: due)
    }
}
