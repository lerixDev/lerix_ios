#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Button shapes a survey's `appearance.shape` can pick.
enum LerixSurveyShape: String {
    case rounded, circle, square, pill

    init(_ raw: String?) {
        self = raw.flatMap(LerixSurveyShape.init(rawValue:)) ?? .rounded
    }
}

/// A survey button outline in one of the dashboard's shapes.
@available(iOS 13.0, macOS 10.15, *)
struct LerixSurveyButtonShape: Shape {
    var shape: LerixSurveyShape
    /// Corner radius for `rounded`.
    var radius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .rounded: return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        case .square: return RoundedRectangle(cornerRadius: 2).path(in: rect)
        case .pill: return Capsule().path(in: rect)
        case .circle:
            let side = min(rect.width, rect.height)
            return Circle().path(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        }
    }
}

/// Colour rules shared by the NPS and rating views, as in lerix_core's
/// `survey-card.ts`: a survey accent beats `LerixUI.tintColor`; text on a
/// filled colour is black or white, whichever reads better.
enum LerixSurveyColors {
    /// `colorMode: "groups"` when the dashboard sets no colour for a group.
    static let groupDefaults: [LerixSurveyGroup: String] = [.detractor: "#E5484D", .passive: "#F5A524", .promoter: "#30A46C"]
    /// Stars / hearts fill without an accent.
    static let starFill = "#F5B301"
    static let heartFill = "#E5484D"

    /// Relative luminance of `#RRGGBB`, or `nil` for anything else.
    static func luminance(hex: String?) -> Double? {
        guard var value = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return luminance(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Whether text on `hex` should be dark (`true`) or white.
    static func prefersDarkText(hex: String) -> Bool {
        (luminance(hex: hex) ?? 0) > 0.45
    }
}

@available(iOS 13.0, macOS 10.15, *)
extension View {
    /// A square (for `circle` buttons) or the view unchanged. `aspectRatio(nil)`
    /// is not a no-op: it would keep the content's own ratio and shrink the button.
    @ViewBuilder
    func lerixSquare(_ square: Bool) -> some View {
        if square {
            aspectRatio(1, contentMode: .fit)
        } else {
            self
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension Color {
    /// Black or white, whichever reads better on `self`.
    var lerixOnColor: Color {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        #else
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        #endif
        let lum = LerixSurveyColors.luminance(red: Double(r), green: Double(g), blue: Double(b))
        return lum > 0.45 ? Color(red: 0.067, green: 0.067, blue: 0.078) : .white
    }
}
#endif
