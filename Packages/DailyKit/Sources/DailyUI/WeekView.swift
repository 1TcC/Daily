import DailyKit
import SwiftUI

/// 周视图 / 日视图：顶部日期行、全天行，下面是可滚动的 24 小时网格。
/// 翻页时只有日期相关的三条（日期行、全天行、日期列）跟手平移；时间刻度、网格线和竖直滚动位置保持不动。
struct WeekView: View {
    let model: CalendarModel
    let pager: Pager
    @Environment(\.uiScale) private var scale
    private var hourHeight: CGFloat { (44 * scale).rounded() }
    private var gutter: CGFloat { (56 * scale).rounded() }

    var body: some View {
        let anchors = model.pageAnchors
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter)
                PagedStrip(pager: pager, axis: .horizontal, anchors: anchors) { anchor in
                    WeekHeaderPage(model: model, days: model.days(for: anchor))
                }
            }
            .frame(height: 52 * scale)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                Text("全天")
                    .scaledFont(10)
                    .foregroundStyle(.secondary)
                    .frame(width: gutter - 8, alignment: .trailing)
                    .padding(.trailing, 8)
                    .padding(.top, 8)
                PagedStrip(pager: pager, axis: .horizontal, anchors: anchors) { anchor in
                    AllDayPage(model: model, days: model.days(for: anchor))
                }
            }
            .frame(height: allDayHeight(anchors))
            Divider()
            // 时间轴从 7 点（或更早的日程）开始，打开就能看到白天的安排，不用先划过凌晨。
            ScrollView(.vertical) {
                grid(anchors, startHour: model.timelineStartHour(for: anchors))
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
        }
    }

    /// 全天行高度取三页里最多的那一天，翻页时不跳动。
    private func allDayHeight(_ anchors: [Date]) -> CGFloat {
        let most = anchors.flatMap { model.days(for: $0) }.map { model.allDayItems(on: $0).count }.max() ?? 0
        return max(30 * scale, CGFloat(most) * (22 * scale + 2) + 8)
    }

    private func grid(_ anchors: [Date], startHour: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(startHour..<24, id: \.self) { hour in
                    Text(hour == 0 ? "" : "\(hour):00")
                        .scaledFont(10)
                        .foregroundStyle(.secondary)
                        .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
                        .offset(y: -6)
                        .padding(.trailing, 8)
                        .id(hour)
                }
            }
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(startHour..<24, id: \.self) { _ in
                        Rectangle().fill(Palette.gridLine).frame(height: 1)
                        Spacer(minLength: 0).frame(height: hourHeight - 1)
                    }
                }
                PagedStrip(pager: pager, axis: .horizontal, anchors: anchors) { anchor in
                    WeekColumnsPage(model: model, days: model.days(for: anchor), hourHeight: hourHeight,
                                    startHour: startHour)
                }
            }
        }
        .frame(height: hourHeight * CGFloat(24 - startHour))
    }
}

private struct WeekHeaderPage: View {
    let model: CalendarModel
    let days: [Date]
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let today = model.isToday(day)
                HStack(spacing: 6) {
                    Text(day.formatted("EEE", calendar: model.calendar))
                        .foregroundStyle(today ? Palette.today : .secondary)
                    Text(day.formatted("d", calendar: model.calendar))
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(today ? .white : .primary)
                        .frame(minWidth: 26 * scale, minHeight: 26 * scale)
                        .background(Circle().fill(today ? Palette.today : .clear))
                }
                .scaledFont(13)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct AllDayPage: View {
    let model: CalendarModel
    let days: [Date]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(days, id: \.self) { day in
                VStack(spacing: 2) {
                    ForEach(model.allDayItems(on: day)) { item in
                        AllDayChip(item: item)
                    }
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.vertical, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct WeekColumnsPage: View {
    let model: CalendarModel
    let days: [Date]
    let hourHeight: CGFloat
    let startHour: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                DayColumn(model: model, day: day, hourHeight: hourHeight, startHour: startHour)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Palette.gridLine).frame(width: 1)
                    }
            }
        }
    }
}

private struct DayColumn: View {
    let model: CalendarModel
    let day: Date
    let hourHeight: CGFloat
    let startHour: Int

    var body: some View {
        // 只画时间轴可见部分（startHour 之后）；更早结束的跨午夜日程不画。
        let day = model.dayInterval(self.day)
        let interval = DateInterval(start: day.start.addingTimeInterval(TimeInterval(startHour * 3600)), end: day.end)
        let isToday = model.isToday(self.day)
        let items = model.timedItems(on: self.day).filter { $0.effectiveEnd > interval.start || $0.start >= interval.start }
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if isToday { Palette.todayColumn }
                ForEach(DayLayout.layout(items)) { placed in
                    let frame = frame(for: placed, in: interval, width: geo.size.width)
                    EventBlock(item: placed.item, size: frame.size, calendar: model.calendar)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                if isToday {
                    TimelineView(.everyMinute) { context in
                        NowIndicator()
                            .offset(y: y(for: context.date, in: interval) - 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func y(for date: Date, in interval: DateInterval) -> CGFloat {
        CGFloat(date.timeIntervalSince(interval.start) / 3600) * hourHeight
    }

    private func frame(for placed: PositionedItem, in interval: DateInterval, width: CGFloat) -> CGRect {
        let start = max(placed.item.start, interval.start)
        let end = min(max(placed.item.effectiveEnd, placed.item.start.addingTimeInterval(DayLayout.minimumVisualDuration)),
                      interval.end)
        let top = y(for: start, in: interval) + 1
        let height = max(20, y(for: end, in: interval) - top - 1)
        let inset: CGFloat = 3
        let usable = width - inset * 2
        let x = inset + usable * placed.x
        // 并排时相邻两块之间留 2pt 缝隙
        let gap: CGFloat = placed.x + placed.width < 0.999 ? 2 : 0
        return CGRect(x: x, y: top, width: usable * placed.width - gap, height: height)
    }
}

/// 周 / 日视图里的一个日程块：标题、时间、地点依次排列并自动换行，放不下的部分截掉；点击弹出详情。
private struct EventBlock: View {
    @Environment(\.uiScale) private var scale
    let item: CalendarItem
    let size: CGSize
    let calendar: Calendar
    @State private var showingDetail = false

    var body: some View {
        // 窄块（重叠并排时）省掉圆点、字号略小、时间写成紧凑格式。
        let compact = size.width < 96 * scale
        let shape = RoundedRectangle(cornerRadius: 6)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if !compact {
                    Circle().fill(item.displayColor).frame(width: 6, height: 6)
                }
                Text(item.title)
                    .scaledFont(compact ? 11 : 12, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 时间不在中间断行：放不下完整时段时只显示开始时间。
            ViewThatFits(in: .horizontal) {
                Text(item.timeText(calendar: calendar, compact: compact)).fixedSize()
                Text(item.start.formatted("H:mm", calendar: calendar)).fixedSize()
            }
            .scaledFont(compact ? 10 : 11)
            .foregroundStyle(.secondary)
            if let location = item.location {
                Text(location)
                    .scaledFont(compact ? 10 : 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, compact ? 4 : 7)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(item.displayTint))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { showingDetail = true }
        .popover(isPresented: $showingDetail, arrowEdge: .trailing) {
            EventDetailView(item: item, calendar: calendar)
        }
        .help([item.title, item.timeText(calendar: calendar), item.location].compactMap { $0 }.joined(separator: "\n"))
    }
}

extension CalendarItem {
    /// 「13:30 – 15:05」；`compact` 时去掉空格，窄处更容易放下。
    func timeText(calendar: Calendar, compact: Bool = false) -> String {
        if isAllDay { return "全天" }
        let start = start.formatted("H:mm", calendar: calendar)
        guard let end else { return start }
        return start + (compact ? "-" : " – ") + end.formatted("H:mm", calendar: calendar)
    }
}

/// 点击日程后弹出的详情。
struct EventDetailView: View {
    let item: CalendarItem
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(item.displayColor).frame(width: 9, height: 9)
                Text(item.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                row("clock", "\(item.start.formatted("M月d日 EEE", calendar: calendar))  \(item.timeText(calendar: calendar))")
                if let location = item.location { row("mappin.and.ellipse", location) }
                if let teacher = item.metadata["teacher"] { row("person", teacher) }
                if let weeks = item.metadata["weeks"], !weeks.isEmpty {
                    row("calendar", [item.metadata["units"], weeks].compactMap { $0 }.joined(separator: " · "))
                }
                if let code = item.metadata["pickupCode"] { row("number", "取件码 \(code)") }
                if let notes = item.notes, notes != item.metadata["teacher"] { row("text.alignleft", notes) }
                row(item.sourceKind.symbol, [item.sourceKind.displayName, item.metadata["calendarTitle"] ?? item.metadata["via"]]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
        }
    }
}

struct AllDayChip: View {
    @Environment(\.uiScale) private var scale
    let item: CalendarItem

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(item.displayColor).frame(width: 6, height: 6)
            Text(item.title).lineLimit(1)
        }
        .scaledFont(11)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 22 * scale, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(item.displayTint))
    }
}

private struct NowIndicator: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Palette.today).frame(width: 8, height: 8)
            Rectangle().fill(Palette.today).frame(height: 2)
        }
        .offset(x: -4)
    }
}
