import AppKit
import DailyKit
import SwiftUI

extension Color {
    /// 随系统浅色 / 深色外观自动切换的颜色。
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

public extension SourceKind {
    var color: Color {
        switch self {
        case .course: Color(light: 0x2F6FED, dark: 0x6B9BFF)
        case .systemCalendar: Color(light: 0x0F8B8D, dark: 0x2BC4C7)
        case .message: Color(light: 0x7C4DFF, dark: 0xB79CFF)
        case .travel: Color(light: 0xE8730C, dark: 0xFFA24D)
        case .parcel: Color(light: 0x1F9D55, dark: 0x46D483)
        case .subscription: Color(light: 0xD9387B, dark: 0xFF7AB6)
        case .agent: Color(light: 0x52525B, dark: 0xB4B4BC)
        case .manual: Color(light: 0xB7791F, dark: 0xE6B450)
        }
    }

    /// 日程块的浅色底。
    var tint: Color { color.opacity(0.14) }

    var symbol: String {
        switch self {
        case .course: "graduationcap"
        case .systemCalendar: "calendar"
        case .message: "envelope"
        case .travel: "tram"
        case .parcel: "shippingbox"
        case .subscription: "creditcard"
        case .agent: "cpu"
        case .manual: "person"
        }
    }
}

public extension CalendarItem {
    /// 系统日历条目沿用它在「日历」App 里的颜色，其他来源用来源色。
    var displayColor: Color {
        if let hex = metadata["color"], let value = UInt32(hex.dropFirst(), radix: 16), hex.count == 7 {
            return Color(nsColor: NSColor(hex: value))
        }
        return sourceKind.color
    }

    var displayTint: Color { displayColor.opacity(0.14) }
}

enum Palette {
    static let today = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let todayColumn = Color(light: 0xF5F8FF, dark: 0x1A1D24)
    static let gridLine = Color(light: 0xEDEDF0, dark: 0x2A2B30)
    static let sidebar = Color(light: 0xF6F6F8, dark: 0x1E1E21)
    static let weekRow = Color(light: 0xE6E6EB, dark: 0x2C2C30)
}

extension Date {
    func formatted(_ pattern: String, calendar: Calendar = .mondayFirst) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: self)
    }
}
