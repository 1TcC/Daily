import DailyKit
import SwiftUI

/// 周视图 / 日视图：顶部日期行、全天行，下面是可滚动的 24 小时网格。
struct WeekView: View {
    let model: CalendarModel
    var hourHeight: CGFloat = 44
    var gutter: CGFloat = 56

    var body: some View {
        let days = model.visibleDays
        VStack(spacing: 0) {
            header(days)
            Divider()
            allDayRow(days)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    grid(days)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
                .onAppear { proxy.scrollTo(7, anchor: .top) }
            }
        }
    }

    // MARK: - 顶部

    private func header(_ days: [Date]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            ForEach(days, id: \.self) { day in
                let today = model.isToday(day)
                HStack(spacing: 6) {
                    Text(day.formatted("EEE", calendar: model.calendar))
                        .foregroundStyle(today ? Palette.today : .secondary)
                    Text(day.formatted("d", calendar: model.calendar))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(today ? .white : .primary)
                        .frame(minWidth: 26, minHeight: 26)
                        .background(Circle().fill(today ? Palette.today : .clear))
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 52)
    }

    private func allDayRow(_ days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("全天")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: gutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 4)
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
        .frame(minHeight: 30)
    }

    // MARK: - 时间网格

    private func grid(_ days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour == 0 ? "" : "\(hour):00")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
                        .offset(y: -6)
                        .padding(.trailing, 8)
                        .id(hour)
                }
            }
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle().fill(Palette.gridLine).frame(height: 1)
                        Spacer(minLength: 0).frame(height: hourHeight - 1)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        DayColumn(model: model, day: day, hourHeight: hourHeight)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Palette.gridLine).frame(width: 1)
                            }
                    }
                }
            }
        }
        .frame(height: hourHeight * 24)
    }
}

private struct DayColumn: View {
    let model: CalendarModel
    let day: Date
    let hourHeight: CGFloat

    var body: some View {
        let interval = model.dayInterval(day)
        let isToday = model.isToday(day)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if isToday { Palette.todayColumn }
                ForEach(DayLayout.layout(model.timedItems(on: day))) { placed in
                    let frame = frame(for: placed, in: interval, width: geo.size.width)
                    EventBlock(item: placed.item, height: frame.height, calendar: model.calendar)
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
        let columnWidth = (width - inset * 2) / CGFloat(placed.columns)
        return CGRect(x: inset + columnWidth * CGFloat(placed.column), y: top,
                      width: columnWidth - (placed.columns > 1 ? 2 : 0), height: height)
    }
}

private struct EventBlock: View {
    let item: CalendarItem
    let height: CGFloat
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(item.sourceKind.color).frame(width: 6, height: 6)
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            if height >= 40 {
                Text(timeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if height >= 56, let location = item.location {
                Text(location)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(item.sourceKind.tint))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(item.title)
    }

    private var timeText: String {
        let start = item.start.formatted("H:mm", calendar: calendar)
        guard let end = item.end else { return start }
        return "\(start) – \(end.formatted("H:mm", calendar: calendar))"
    }
}

struct AllDayChip: View {
    let item: CalendarItem

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(item.sourceKind.color).frame(width: 6, height: 6)
            Text(item.title).lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(item.sourceKind.tint))
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
