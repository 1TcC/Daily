import DailyKit
import SwiftUI

/// 「接下来几天」小组件的尺寸。
public enum UpcomingLayout: Sendable {
    case medium, large, extraLarge
}

/// 仿系统「日历」小组件：左边大号日期 + 农历 + 红色星期和今天的安排，右边按日期分组列出之后几天。
/// 一天的日程要么完整显示、要么整天不显示；放不下时先改用单行紧凑样式，再把后面的日子折叠成一句话。
public struct UpcomingWidgetView: View {
    let snapshot: WidgetSnapshot
    let layout: UpcomingLayout

    public init(snapshot: WidgetSnapshot, layout: UpcomingLayout) {
        self.snapshot = snapshot
        self.layout = layout
    }

    private var today: DayAgenda { snapshot.days.first ?? DayAgenda(date: snapshot.date, items: []) }
    private var later: [DayAgenda] { snapshot.days.dropFirst().filter { !$0.items.isEmpty } }

    public var body: some View {
        switch layout {
        case .medium:
            HStack(alignment: .top, spacing: 14) {
                todayColumn.frame(width: 118, alignment: .leading)
                DayStack(days: later, showHeaders: true, emptyText: "未来 7 天无日程")
            }
        case .large:
            VStack(alignment: .leading, spacing: 8) {
                DateBlock(date: snapshot.date)
                // 今天最多占三分之一高度，剩下的给之后几天
                GeometryReader { geo in
                    let todayHeight = DayStack.height(of: [today], showHeaders: false, compact: false)
                        .clamped(to: 18...(geo.size.height * 0.36))
                    VStack(alignment: .leading, spacing: 8) {
                        DayStack(days: [today], showHeaders: false, emptyText: "今天无日程")
                            .frame(height: todayHeight, alignment: .top)
                        Divider()
                        DayStack(days: later, showHeaders: true, emptyText: "未来 7 天无日程")
                    }
                }
            }
        case .extraLarge:
            HStack(alignment: .top, spacing: 16) {
                todayColumn.frame(width: 170, alignment: .leading)
                let split = Self.split(later)
                DayStack(days: split.0, showHeaders: true, emptyText: "未来 7 天无日程")
                DayStack(days: split.1, showHeaders: true, emptyText: nil)
            }
        }
    }

    private var todayColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            DateBlock(date: snapshot.date)
            DayStack(days: [today], showHeaders: false, emptyText: "今天无日程")
        }
    }

    /// 超大号右侧两栏：按估算高度大致对半分，一天不拆开。
    static func split(_ days: [DayAgenda]) -> ([DayAgenda], [DayAgenda]) {
        let total = DayStack.height(of: days, showHeaders: true, compact: false)
        var left: [DayAgenda] = [], right: [DayAgenda] = []
        var used: CGFloat = 0
        for day in days {
            let h = DayStack.height(of: [day], showHeaders: true, compact: false)
            if right.isEmpty, used == 0 || used + h / 2 <= total / 2 {
                left.append(day)
                used += h
            } else {
                right.append(day)
            }
        }
        return (left, right)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), Swift.max(range.lowerBound, range.upperBound))
    }
}

/// 大号日期 | 农历 | 星期（红色），和系统日历小组件一样竖排、细线分隔。
private struct DateBlock: View {
    let date: Date
    private let cal = Calendar.mondayFirst

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: 32, weight: .regular))
                .monospacedDigit()
                .fixedSize()
            divider
            VerticalText(text: Lunar.dayText(date))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
            divider
            VerticalText(text: date.formatted("EEE", calendar: cal))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.today)
        }
        .frame(height: 38)
    }

    private var divider: some View {
        Rectangle().fill(.secondary.opacity(0.3)).frame(width: 1, height: 26)
    }
}

/// 一个字一行的竖排文字。
private struct VerticalText: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { Text(String($0.element)) }
        }
        .fixedSize()
    }
}

/// 按天排列的日程：根据可用高度决定显示哪些天、用卡片还是单行样式。
private struct DayStack: View {
    let days: [DayAgenda]
    let showHeaders: Bool
    let emptyText: String?

    // 估算高度用的尺寸（字号：标题 11、副标题 10、日期标题 10）
    static let cardHeight: CGFloat = 29
    static let rowHeight: CGFloat = 14
    static let headerHeight: CGFloat = 15
    static let spacing: CGFloat = 3
    static let foldHeight: CGFloat = 14

    static func height(of days: [DayAgenda], showHeaders: Bool, compact: Bool) -> CGFloat {
        days.enumerated().reduce(0) { sum, entry in
            let (i, day) = entry
            let header = showHeaders ? headerHeight + (i == 0 ? 0 : 4) : 0
            let item = compact ? rowHeight : cardHeight
            return sum + header + CGFloat(day.items.count) * (item + spacing)
        }
    }

    /// 选出能完整放下的若干天，以及样式；第一天连紧凑样式都放不下时才截断。
    static func plan(_ days: [DayAgenda], showHeaders: Bool, available: CGFloat) -> (days: [DayAgenda], compact: Bool, truncate: Int?) {
        let days = days.filter { !$0.items.isEmpty }
        guard !days.isEmpty else { return ([], false, nil) }
        for compact in [false, true] {
            var chosen: [DayAgenda] = []
            for (i, day) in days.enumerated() {
                let candidate = chosen + [day]
                let fold: CGFloat = i < days.count - 1 ? foldHeight : 0
                if height(of: candidate, showHeaders: showHeaders, compact: compact) + fold <= available {
                    chosen = candidate
                } else {
                    break
                }
            }
            if !chosen.isEmpty { return (chosen, compact, nil) }
        }
        // 一天也放不下：紧凑样式显示这一天的前几项
        let header = showHeaders ? headerHeight : 0
        let fit = Int(max(1, (available - header - foldHeight) / (rowHeight + spacing)))
        return ([days[0]], true, fit)
    }

    var body: some View {
        GeometryReader { geo in
            let plan = Self.plan(days, showHeaders: showHeaders, available: geo.size.height)
            VStack(alignment: .leading, spacing: Self.spacing) {
                if days.allSatisfy({ $0.items.isEmpty }), let emptyText {
                    Text(emptyText).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
                }
                ForEach(Array(plan.days.enumerated()), id: \.element.id) { index, day in
                    if showHeaders {
                        Text(day.date.formatted("M月d日 EEEE", calendar: .mondayFirst))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(height: Self.headerHeight - 3, alignment: .bottom)
                            .padding(.top, index == 0 ? 0 : 4)
                    }
                    let items = plan.truncate.map { Array(day.items.prefix($0)) } ?? day.items
                    ForEach(items) { item in
                        if plan.compact { CompactRow(item: item) } else { EventCard(item: item) }
                    }
                }
                if let fold = foldText(plan) {
                    Text(fold).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func foldText(_ plan: (days: [DayAgenda], compact: Bool, truncate: Int?)) -> String? {
        if let truncate = plan.truncate, let first = plan.days.first, first.items.count > truncate {
            return "这天还有 \(first.items.count - truncate) 项"
        }
        let hiddenDays = days.filter { !$0.items.isEmpty }.count - plan.days.count
        return hiddenDays > 0 ? "之后还有 \(hiddenDays) 天的安排" : nil
    }
}

/// 和系统日历一样的事件卡片：左侧色条，标题 + 时间（地点）。
private struct EventCard: View {
    let item: CalendarItem
    private let cal = Calendar.mondayFirst

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Text([item.timeText(calendar: cal), item.location].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10))
                .opacity(0.85)
                .lineLimit(1)
        }
        // 和系统日历一样，文字用日程本身的颜色
        .foregroundStyle(item.displayColor)
        .padding(.vertical, 2.5)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, minHeight: DayStack.cardHeight, maxHeight: DayStack.cardHeight, alignment: .leading)
        // 色条放在背景里，不参与布局，卡片高度固定
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(item.displayColor.opacity(0.11))
                RoundedRectangle(cornerRadius: 1.5).fill(item.displayColor).frame(width: 3)
                    .padding(.vertical, 4).padding(.leading, 3)
            }
        }
    }
}

/// 放不下卡片时的单行样式：色点 + 时间 + 标题。
private struct CompactRow: View {
    let item: CalendarItem
    private let cal = Calendar.mondayFirst

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(item.displayColor).frame(width: 5, height: 5)
            Text(item.isAllDay ? "全天" : item.start.formatted("H:mm", calendar: cal))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .frame(height: DayStack.rowHeight)
    }
}

/// 农历日：初一显示月份（如「十月」），其余显示「廿一」这样的日子。
enum Lunar {
    private static let days = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                               "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                               "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
    private static let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]

    static func dayText(_ date: Date) -> String {
        let chinese = Calendar(identifier: .chinese)
        let c = chinese.dateComponents([.month, .day, .isLeapMonth], from: date)
        guard let month = c.month, let day = c.day, (1...30).contains(day), (1...12).contains(month) else { return "" }
        if day == 1 { return (c.isLeapMonth == true ? "闰" : "") + months[month - 1] }
        return days[day - 1]
    }
}
