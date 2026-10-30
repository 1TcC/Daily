import DailyKit
import SwiftUI

/// 列表视图的一页：按天分组列出一周的条目。
struct AgendaPage: View {
    let model: CalendarModel
    let anchor: Date

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(model.days(for: anchor), id: \.self) { day in
                    let items = model.items(on: day)
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(day.formatted("M月d日 EEEE", calendar: model.calendar))
                                .scaledFont(13, weight: .semibold)
                                .foregroundStyle(model.isToday(day) ? Palette.today : .primary)
                            ForEach(items) { item in
                                AgendaRow(item: item, calendar: model.calendar)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

struct AgendaRow: View {
    @Environment(\.uiScale) private var scale
    let item: CalendarItem
    let calendar: Calendar
    @State private var showingDetail = false

    var body: some View {
        HStack(spacing: 12) {
            Text(item.isAllDay ? "全天" : item.start.formatted("H:mm", calendar: calendar))
                .scaledFont(12, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .frame(width: 44 * scale, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(item.displayColor).frame(width: 4, height: 30 * scale)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).scaledFont(13, weight: .semibold)
                Text([item.location, item.sourceKind.displayName].compactMap { $0 }.joined(separator: " · "))
                    .scaledFont(11)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .contentShape(Rectangle())
        .onTapGesture { showingDetail = true }
        .popover(isPresented: $showingDetail, arrowEdge: .trailing) {
            EventDetailView(item: item, calendar: calendar)
        }
    }
}

/// 月视图：每格列出当天前几条日程。
struct MonthWeekdayHeader: View {
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            ForEach(["周一", "周二", "周三", "周四", "周五", "周六", "周日"], id: \.self) {
                Text($0).scaledFont(12).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .frame(height: 32 * scale)
    }
}

/// 月视图的一页（一个月）：每天列出全部日程的名称、时间和地点。
/// 每周一行，行高随当周最忙的一天变化；整页比窗口矮时各行平均拉高填满。
struct MonthPage: View {
    @Environment(\.uiScale) private var scale
    let model: CalendarModel
    let anchor: Date

    static func rowHeights(model: CalendarModel, anchor: Date, scale: CGFloat) -> [CGFloat] {
        let days = model.days(for: anchor)
        return stride(from: 0, to: days.count, by: 7).map { start in
            let most = days[start..<min(start + 7, days.count)].map { model.items(on: $0).count }.max() ?? 0
            return max(96 * scale, (28 + CGFloat(most) * MonthEventRow.pitch) * scale + 6)
        }
    }

    static func height(model: CalendarModel, anchor: Date, scale: CGFloat) -> CGFloat {
        rowHeights(model: model, anchor: anchor, scale: scale).reduce(0, +)
    }

    var body: some View {
        let cal = model.calendar
        let days = model.days(for: anchor)
        let month = cal.component(.month, from: anchor)
        let natural = Self.rowHeights(model: model, anchor: anchor, scale: scale)
        GeometryReader { geo in
            let extra = max(0, geo.size.height - natural.reduce(0, +)) / CGFloat(max(natural.count, 1))
            VStack(spacing: 0) {
                ForEach(natural.indices, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(days[row * 7..<min(row * 7 + 7, days.count)], id: \.self) { day in
                            cell(day, inMonth: cal.component(.month, from: day) == month)
                        }
                    }
                    .frame(height: natural[row] + extra)
                }
            }
        }
    }

    private func cell(_ day: Date, inMonth: Bool) -> some View {
        let items = model.items(on: day)
        let today = model.isToday(day)
        return VStack(alignment: .leading, spacing: 2 * scale) {
            Text("\(model.calendar.component(.day, from: day))")
                .scaledFont(12, weight: today ? .bold : .regular)
                .foregroundStyle(today ? .white : (inMonth ? .primary : .secondary))
                .frame(minWidth: 22 * scale, minHeight: 22 * scale)
                .background(Circle().fill(today ? Palette.today : .clear))
                .padding(.leading, 2)
                .frame(height: 26 * scale, alignment: .leading)
            ForEach(items) { item in
                MonthEventRow(item: item, calendar: model.calendar)
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(inMonth ? 1 : 0.55)
        .overlay(alignment: .topLeading) {
            Rectangle().strokeBorder(Palette.gridLine, lineWidth: 0.5)
        }
    }
}

/// 月视图里的一条日程：第一行名称，第二行时间和地点；点击弹出详情。
struct MonthEventRow: View {
    /// 每条日程占的高度（含间距），未乘缩放。
    static let pitch: CGFloat = 36

    @Environment(\.uiScale) private var scale
    let item: CalendarItem
    let calendar: Calendar
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title)
                .scaledFont(11, weight: .semibold)
                .lineLimit(1)
            Text([item.timeText(calendar: calendar, compact: true), item.location].compactMap { $0 }.joined(separator: " "))
                .scaledFont(10)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, minHeight: (Self.pitch - 2) * scale, maxHeight: (Self.pitch - 2) * scale,
               alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(item.displayTint))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(item.displayColor).frame(width: 2.5).padding(.vertical, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { showingDetail = true }
        .popover(isPresented: $showingDetail, arrowEdge: .trailing) {
            EventDetailView(item: item, calendar: calendar)
        }
        .help([item.title, item.timeText(calendar: calendar), item.location].compactMap { $0 }.joined(separator: "\n"))
    }
}

/// 待确认收件箱：AI 从邮件、微信等识别出的日程，确认后才进入日历。
struct PendingInboxView: View {
    let model: CalendarModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待确认").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            if model.pending.isEmpty {
                Text("没有待确认的日程").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(model.pending) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.metadata["from"] ?? item.sourceKind.displayName)
                        .scaledFont(11).foregroundStyle(.secondary)
                    Text(item.title).scaledFont(14, weight: .semibold)
                    Text([item.start.formatted("M月d日 EEE H:mm", calendar: model.calendar), item.location]
                        .compactMap { $0 }.joined(separator: " · "))
                        .scaledFont(12)
                    HStack {
                        Button("加入日历") { model.confirm(item) }.buttonStyle(.borderedProminent)
                        Button("忽略") { model.dismiss(item) }
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
