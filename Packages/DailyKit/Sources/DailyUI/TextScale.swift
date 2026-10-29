import SwiftUI

/// 主窗口的整体缩放：字号和随字号变化的行高、格子大小都乘以它。
public enum TextScale {
    public static let steps: [CGFloat] = [1.0, 1.15, 1.3, 1.45, 1.6]
    public static let standard: CGFloat = 1.15

    public static func larger(than value: CGFloat) -> CGFloat {
        steps.first { $0 > value + 0.001 } ?? steps.last!
    }

    public static func smaller(than value: CGFloat) -> CGFloat {
        steps.last { $0 < value - 0.001 } ?? steps.first!
    }
}

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let font = Font.system(size: (size * scale).rounded(), weight: weight)
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    /// 按主窗口缩放比例调整的系统字体。
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, monospacedDigit: Bool = false) -> some View {
        modifier(ScaledFont(size: size, weight: weight, monospacedDigit: monospacedDigit))
    }
}
