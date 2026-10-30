import DailyKit
import SwiftUI

/// 搜索结果：先列还没结束的（由近到远），再列以前的（由近到远）；点一条跳到它所在的那一周。
struct SearchResultsView: View {
    let model: CalendarModel
    @Environment(\.uiScale) private var scale

    var body: some View {
        // 还没结束的算「接下来」（全天日程的结束是次日零点，不含）
        let now = model.now()
        let isUpcoming: (CalendarItem) -> Bool = { $0.isAllDay ? $0.effectiveEnd > now : $0.effectiveEnd >= now }
        let upcoming = model.searchResults.filter(isUpcoming)
        let past = model.searchResults.filter { !isUpcoming($0) }.reversed()
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 18) {
                if model.searchResults.isEmpty {
                    Text("没有找到「\(model.searchText)」")
                        .scaledFont(13)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                section("接下来", Array(upcoming))
                section("以前", Array(past))
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [CalendarItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title) · \(items.count)")
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(.secondary)
                ForEach(items) { item in
                    SearchResultRow(item: item, calendar: model.calendar, isToday: model.isToday(item.start))
                        .onTapGesture { model.reveal(item) }
                        .contextMenu {
                            Button("在日历中显示") { model.reveal(item) }
                            if item.isEditable {
                                Button("编辑…") { model.edit(item) }
                                Button("删除", role: .destructive) { model.delete(item) }
                            }
                        }
                }
            }
        }
    }
}

private struct SearchResultRow: View {
    @Environment(\.uiScale) private var scale
    let item: CalendarItem
    let calendar: Calendar
    let isToday: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.start.formatted(sameYear ? "M月d日" : "yyyy/M/d", calendar: calendar))
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(isToday ? Palette.today : .primary)
                Text(item.start.formatted("EEE", calendar: calendar) + " " + (item.isAllDay ? "全天" : item.start.formatted("H:mm", calendar: calendar)))
                    .scaledFont(10)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 76 * scale, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(item.displayColor).frame(width: 4, height: 30 * scale)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).scaledFont(13, weight: .semibold).lineLimit(1)
                Text([item.location, item.metadata["pickupCode"].map { "取件码 \($0)" }, item.sourceKind.displayName]
                    .compactMap { $0 }.joined(separator: " · "))
                    .scaledFont(11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .contentShape(Rectangle())
    }

    private var sameYear: Bool {
        calendar.component(.year, from: item.start) == calendar.component(.year, from: .now)
    }
}
