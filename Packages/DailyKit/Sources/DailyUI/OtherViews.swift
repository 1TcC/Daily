import DailyKit
import SwiftUI

/// 列表视图：按天分组列出当前一周的条目。
struct AgendaListView: View {
    let model: CalendarModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(model.visibleDays, id: \.self) { day in
                    let items = model.items(on: day)
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(day.formatted("M月d日 EEEE", calendar: model.calendar))
                                .font(.system(size: 13, weight: .semibold))
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
    let item: CalendarItem
    let calendar: Calendar

    var body: some View {
        HStack(spacing: 12) {
            Text(item.isAllDay ? "全天" : item.start.formatted("H:mm", calendar: calendar))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(item.sourceKind.color).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .semibold))
                Text([item.location, item.sourceKind.displayName].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }
}

/// 月视图：每格列出当天前几条日程。
struct MonthView: View {
    let model: CalendarModel

    var body: some View {
        let cal = model.calendar
        let days = model.visibleDays
        let month = cal.component(.month, from: model.anchorDate)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["周一", "周二", "周三", "周四", "周五", "周六", "周日"], id: \.self) {
                    Text($0).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 32)
            Divider()
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<(days.count / 7), id: \.self) { row in
                    GridRow {
                        ForEach(days[row * 7..<row * 7 + 7], id: \.self) { day in
                            cell(day, inMonth: cal.component(.month, from: day) == month)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ day: Date, inMonth: Bool) -> some View {
        let items = model.items(on: day)
        let today = model.isToday(day)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(model.calendar.component(.day, from: day))")
                .font(.system(size: 12, weight: today ? .bold : .regular))
                .foregroundStyle(today ? .white : (inMonth ? .primary : .secondary))
                .frame(minWidth: 22, minHeight: 22)
                .background(Circle().fill(today ? Palette.today : .clear))
            ForEach(items.prefix(3)) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.sourceKind.color).frame(width: 5, height: 5)
                    Text(item.title).lineLimit(1)
                }
                .font(.system(size: 10))
            }
            if items.count > 3 {
                Text("还有 \(items.count - 3) 项").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            Rectangle().strokeBorder(Palette.gridLine, lineWidth: 0.5)
        }
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
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(item.title).font(.system(size: 14, weight: .semibold))
                    Text([item.start.formatted("M月d日 EEE H:mm", calendar: model.calendar), item.location]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12))
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
