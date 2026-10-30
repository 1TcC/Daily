import DailyKit
import SwiftUI

/// 「接下来几天」小组件的尺寸。
public enum UpcomingLayout: Sendable {
    case medium, large, extraLarge
}

/// 仿系统「日历」小组件：左边大号日期 + 农历 + 星期和今天的安排，右边按日期分组列出之后几天。
public struct UpcomingWidgetView: View {
    let snapshot: WidgetSnapshot
    let layout: UpcomingLayout

    public init(snapshot: WidgetSnapshot, layout: UpcomingLayout) {
        self.snapshot = snapshot
        self.layout = layout
    }

    private var today: [CalendarItem] { snapshot.days.first?.items ?? [] }
    private var later: [DayAgenda] { snapshot.days.dropFirst().filter { !$0.items.isEmpty } }

    public var body: some View {
        switch layout {
        case .medium:
            HStack(alignment: .top, spacing: 14) {
                todayColumn(maxCards: 1).frame(width: 118, alignment: .leading)
                UpcomingList(days: later, maxCards: 2)
            }
        case .large:
            VStack(alignment: .leading, spacing: 8) {
                todayColumn(maxCards: 2)
                Divider()
                UpcomingList(days: later, maxCards: 4)
            }
        case .extraLarge:
            HStack(alignment: .top, spacing: 16) {
                todayColumn(maxCards: 6).frame(width: 170, alignment: .leading)
                let split = splitDays(later)
                UpcomingList(days: split.0, maxCards: 7)
                UpcomingList(days: split.1, maxCards: 7, emptyText: nil)
            }
        }
    }

    private func todayColumn(maxCards: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DateBlock(date: snapshot.date)
            TodayList(items: today, maxCards: maxCards)
        }
    }

    /// 超大号右侧两栏：按条数大致对半分，一天不拆开。
    private func splitDays(_ days: [DayAgenda]) -> ([DayAgenda], [DayAgenda]) {
        let half = (min(days.reduce(0) { $0 + $1.items.count }, 14) + 1) / 2
        var left: [DayAgenda] = [], right: [DayAgenda] = []
        var count = 0
        for day in days {
            if count < half { left.append(day) } else { right.append(day) }
            count += day.items.count
        }
        return (left, right)
    }
}

/// 大号日期 + 竖排的农历和星期（和系统日历小组件一样）。
private struct DateBlock: View {
    let date: Date
    private let cal = Calendar.mondayFirst

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: 38, weight: .light))
                .monospacedDigit()
                .fixedSize()
            divider
            VerticalText(text: Lunar.dayText(date))
                .foregroundStyle(.secondary)
            divider
            VerticalText(text: date.formatted("EEE", calendar: cal))
                .fontWeight(.semibold)
        }
        .frame(height: 44)
    }

    private var divider: some View {
        Rectangle().fill(.secondary.opacity(0.35)).frame(width: 1, height: 30)
    }
}

/// 一个字一行的竖排文字。
private struct VerticalText: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { Text(String($0.element)) }
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize()
    }
}

private struct TodayList: View {
    let items: [CalendarItem]
    let maxCards: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if items.isEmpty {
                Text("今天无日程")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ForEach(items.prefix(maxCards)) { EventCard(item: $0) }
                if items.count > maxCards {
                    MoreText(count: items.count - maxCards)
                }
            }
        }
    }
}

/// 之后几天：日期标题 + 卡片，超出 maxCards 的部分折叠成「还有 N 项」。
private struct UpcomingList: View {
    let days: [DayAgenda]
    let maxCards: Int
    var emptyText: String? = "未来 7 天无日程"
    private let cal = Calendar.mondayFirst

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if days.isEmpty, let emptyText {
                Text(emptyText).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
            }
            let plan = budget()
            ForEach(plan, id: \.day.id) { entry in
                Text(entry.day.date.formatted("M月d日 EEEE", calendar: cal))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, entry.day.id == plan.first?.day.id ? 0 : 3)
                ForEach(entry.shown) { EventCard(item: $0) }
            }
            let hidden = days.reduce(0) { $0 + $1.items.count } - plan.reduce(0) { $0 + $1.shown.count }
            if hidden > 0 { MoreText(count: hidden) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 按顺序分配卡片名额，直到用完。
    private func budget() -> [(day: DayAgenda, shown: [CalendarItem])] {
        var left = maxCards
        var out: [(DayAgenda, [CalendarItem])] = []
        for day in days where left > 0 {
            let shown = Array(day.items.prefix(left))
            left -= shown.count
            out.append((day, shown))
        }
        return out
    }
}

/// 和系统日历一样的事件卡片：左侧色条，标题 + 时间（地点）。
private struct EventCard: View {
    let item: CalendarItem
    private let cal = Calendar.mondayFirst

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text([item.timeText(calendar: cal), item.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // 色条放在背景里，不参与布局，卡片高度只由文字决定
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(item.displayColor.opacity(0.16))
                RoundedRectangle(cornerRadius: 1.5).fill(item.displayColor).frame(width: 3).padding(.vertical, 4).padding(.leading, 3)
            }
        }
    }
}

private struct MoreText: View {
    let count: Int
    var body: some View {
        Text("还有 \(count) 项").font(.system(size: 11)).foregroundStyle(.secondary)
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
