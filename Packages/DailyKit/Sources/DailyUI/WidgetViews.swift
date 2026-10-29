import DailyKit
import SwiftUI

// 桌面小组件的内容视图（A · 原生简洁）。Widget 扩展负责加 containerBackground，
// 这里只放内容，方便在 DailyDev 里直接截图检查。

private let cal = Calendar.mondayFirst

private func hm(_ date: Date) -> String { date.formatted("H:mm", calendar: cal) }

private func money(_ value: Decimal) -> String {
    let n = NSDecimalNumber(decimal: value).doubleValue
    return "¥" + String(format: n.rounded() == n ? "%.0f" : "%.1f", n)
}

/// 大尺寸：今日日程。
public struct TodayAgendaWidgetView: View {
    let snapshot: WidgetSnapshot
    var maxRows = 6

    public init(snapshot: WidgetSnapshot, maxRows: Int = 6) {
        self.snapshot = snapshot
        self.maxRows = maxRows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(snapshot.date.formatted("EEE", calendar: cal))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.today)
                    Text(snapshot.date.formatted("d", calendar: cal))
                        .font(.system(size: 34, weight: .light))
                }
                Spacer()
                Text("\(snapshot.date.formatted("M月", calendar: cal)) · 今天 \(snapshot.today.count) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                if snapshot.today.isEmpty {
                    Text("今天没有安排").font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                ForEach(visibleRows) { item in
                    row(item)
                }
            }
            .padding(.top, 10)
            Spacer(minLength: 0)
            Divider()
            Text(tomorrowText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 7)
        }
    }

    /// 放不下时优先丢掉已经结束的条目，保证接下来的安排都能看到。
    private var visibleRows: [CalendarItem] {
        var rows = snapshot.today
        while rows.count > maxRows,
              let i = rows.firstIndex(where: { !$0.isAllDay && $0.effectiveEnd < snapshot.date }) {
            rows.remove(at: i)
        }
        return Array(rows.prefix(maxRows))
    }

    private func row(_ item: CalendarItem) -> some View {
        let past = item.effectiveEnd < snapshot.date && !item.isAllDay
        let current = snapshot.current?.id == item.id
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.displayColor.opacity(past ? 0.35 : 1))
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(past ? .secondary : .primary)
                    .lineLimit(1)
                Text([item.isAllDay ? "全天" : hm(item.start), current ? "进行中" : (item.location ?? item.sourceKind.displayName)]
                    .joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 9).fill(current ? item.displayTint : .clear))
    }

    private var tomorrowText: String {
        guard let first = snapshot.tomorrowFirst else { return "明天没有安排" }
        let more = snapshot.tomorrowCount > 1 ? " 等 \(snapshot.tomorrowCount) 项" : ""
        return "明天 · \(first.title) \(first.isAllDay ? "全天" : hm(first.start))\(more)"
    }
}

/// 中尺寸：进行中 + 下一项。
public struct NowNextWidgetView: View {
    let snapshot: WidgetSnapshot

    public init(snapshot: WidgetSnapshot) { self.snapshot = snapshot }

    public var body: some View {
        HStack(spacing: 16) {
            if let current = snapshot.current {
                panel(label: "进行中", labelColor: current.displayColor, item: current) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(current.displayColor)
                                .frame(width: geo.size.width * progress(current))
                        }
                    }
                    .frame(height: 5)
                    Text("还剩 \(minutesLeft(current)) 分钟 · \(hm(current.effectiveEnd)) 结束")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                panel(label: "现在", labelColor: .secondary, item: nil) {
                    Text("空闲").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Divider()
            panel(label: snapshot.next.map { "下一项 · \(hm($0.start))" } ?? "下一项", labelColor: .secondary,
                  item: snapshot.next) {
                if let next = snapshot.next {
                    Label(next.sourceKind.displayName, systemImage: next.sourceKind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("今天没有更多安排").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func panel<Footer: View>(label: String, labelColor: Color, item: CalendarItem?,
                                     @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(labelColor)
            if let item {
                Text(item.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(item.metadata["pickupCode"].map { "取件码 \($0)" } ?? item.location ?? "")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            footer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progress(_ item: CalendarItem) -> Double {
        let total = item.effectiveEnd.timeIntervalSince(item.start)
        return total > 0 ? min(1, snapshot.date.timeIntervalSince(item.start) / total) : 0
    }

    private func minutesLeft(_ item: CalendarItem) -> Int {
        max(0, Int(item.effectiveEnd.timeIntervalSince(snapshot.date) / 60))
    }
}

/// 小尺寸：本月订阅支出。
public struct SubscriptionWidgetView: View {
    let snapshot: WidgetSnapshot

    public init(snapshot: WidgetSnapshot) { self.snapshot = snapshot }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("本月订阅").font(.system(size: 11, weight: .semibold)).foregroundStyle(SourceKind.subscription.color)
            Text(money(snapshot.monthlySubscriptionCost))
                .font(.system(size: 30, weight: .semibold))
                .minimumScaleFactor(0.6)
                .padding(.top, 4)
            Text("\(snapshot.subscriptionCount) 项").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let next = snapshot.nextRenewal {
                Text("下次续费").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(next.subscription.name) · \(next.date.formatted("M/d", calendar: cal)) · \(money(next.subscription.price))")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 小尺寸：最近一次出行。
public struct TripWidgetView: View {
    let snapshot: WidgetSnapshot

    public init(snapshot: WidgetSnapshot) { self.snapshot = snapshot }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let trip = snapshot.nextTrip {
                let parts = trip.title.split(separator: " ", maxSplits: 1).map(String.init)
                let route = parts.count > 1 ? parts[1].components(separatedBy: " → ") : []
                Text("\(trip.start.formatted("EEE M/d", calendar: cal)) 出行")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SourceKind.travel.color)
                Text(parts.first ?? trip.title).font(.system(size: 24, weight: .semibold)).lineLimit(1).padding(.top, 4)
                Spacer(minLength: 0)
                HStack {
                    Text(hm(trip.start))
                    Spacer()
                    if let end = trip.end { Text(hm(end)) }
                }
                .font(.system(size: 15, weight: .semibold))
                if route.count == 2 {
                    HStack {
                        Text(route[0])
                        Spacer()
                        Text(route[1])
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text([trip.location, trip.metadata["gate"].map { "检票口 \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
            } else {
                Label("出行", systemImage: SourceKind.travel.symbol)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(SourceKind.travel.color)
                Spacer()
                Text("近两周没有出行").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
