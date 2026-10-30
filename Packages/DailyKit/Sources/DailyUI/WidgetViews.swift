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

/// 本月订阅支出：小号显示总额和下一次续费，中号右边再列出接下来的续费。
public struct SubscriptionWidgetView: View {
    let snapshot: WidgetSnapshot
    let wide: Bool

    public init(snapshot: WidgetSnapshot, wide: Bool = false) {
        self.snapshot = snapshot
        self.wide = wide
    }

    public var body: some View {
        if wide {
            HStack(alignment: .top, spacing: 16) {
                summary.frame(width: 118, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("接下来 30 天").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if snapshot.upcomingRenewals.isEmpty {
                        Text(snapshot.subscriptionCount == 0 ? "在 Daily 里添加订阅后，续费日会显示在这里" : "30 天内没有续费")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.upcomingRenewals.prefix(4)) { renewal in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1.5).fill(SourceKind.subscription.color).frame(width: 3, height: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(renewal.subscription.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(dayLabel(renewal.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text(renewal.subscription.priceText).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("本月订阅").font(.system(size: 11, weight: .semibold)).foregroundStyle(SourceKind.subscription.color)
            Text(money(snapshot.monthlySubscriptionCost))
                .font(.system(size: 30, weight: .semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.top, 4)
            Text(snapshot.subscriptionCount == 0 ? "还没有订阅" : "\(snapshot.subscriptionCount) 项在订")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let next = snapshot.nextRenewal {
                Text("下次续费 · \(dayLabel(next.date))").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(next.subscription.name) \(next.subscription.priceText)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else if snapshot.subscriptionCount == 0 {
                Text("在 Daily 的侧边栏里添加").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayLabel(_ date: Date) -> String {
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: snapshot.date), to: date).day ?? 0
        let relative = switch days {
        case 0: "今天"
        case 1: "明天"
        case 2: "后天"
        default: "\(days) 天后"
        }
        return "\(date.formatted("M/d", calendar: cal)) \(relative)"
    }
}

/// 小尺寸：最近一次出行。兼容短信识别的车次（标题「G1234 上海虹桥」）和手动填写的「G1234 上海虹桥 → 北京南」。
public struct TripWidgetView: View {
    let snapshot: WidgetSnapshot

    public init(snapshot: WidgetSnapshot) { self.snapshot = snapshot }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let trip = snapshot.nextTrip {
                let number = trip.metadata["train"] ?? trip.metadata["flight"]
                let parts = trip.title.split(separator: " ", maxSplits: 1).map(String.init)
                let headline = number ?? parts.first ?? trip.title
                let route = parts.count > 1 && parts.first == headline ? parts[1] : ""
                header(trip)
                Text(headline).font(.system(size: 22, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).padding(.top, 2)
                if !route.isEmpty {
                    Text(route).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(hm(trip.start)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    if let end = trip.end, end > trip.start {
                        Text("– \(hm(end))").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                let detail = [trip.metadata["seat"], trip.metadata["gate"].map { "检票口 \($0)" }].compactMap { $0 }
                Text(detail.isEmpty ? (trip.location ?? "") : detail.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Label("出行", systemImage: SourceKind.travel.symbol)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(SourceKind.travel.color)
                Spacer()
                Text("近两周没有出行").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「今天 · 还有 2 小时」「明天 周六」「11/3 周二」。
    @ViewBuilder
    private func header(_ trip: CalendarItem) -> some View {
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: snapshot.date), to: cal.startOfDay(for: trip.start)).day ?? 0
        let style = Font.system(size: 11, weight: .semibold)
        if days == 0 {
            (Text("今天 · 还有 ") + Text(trip.start, style: .relative))
                .font(style).foregroundStyle(SourceKind.travel.color).lineLimit(1)
        } else {
            Text(days == 1 ? "明天 \(trip.start.formatted("EEE", calendar: cal))" : trip.start.formatted("M/d EEE", calendar: cal))
                .font(style).foregroundStyle(SourceKind.travel.color)
        }
    }
}

/// 待取件：小号显示最新的取件码，中号列出几件并带「已取」按钮（按钮由小组件扩展提供）。
public struct ParcelWidgetView<PickButton: View>: View {
    let snapshot: WidgetSnapshot
    let wide: Bool
    let pickButton: (CalendarItem) -> PickButton

    public init(snapshot: WidgetSnapshot, wide: Bool, @ViewBuilder pickButton: @escaping (CalendarItem) -> PickButton) {
        self.snapshot = snapshot
        self.wide = wide
        self.pickButton = pickButton
    }

    public var body: some View {
        let parcels = snapshot.pendingParcels
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(parcels.isEmpty ? "待取件" : "待取件 \(parcels.count)", systemImage: SourceKind.parcel.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SourceKind.parcel.color)
                Spacer()
            }
            if parcels.isEmpty {
                Spacer()
                Text("没有要取的快递").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            } else if wide {
                ForEach(parcels.prefix(3)) { parcel in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(parcel.metadata["pickupCode"] ?? parcel.title)
                                .font(.system(size: 16, weight: .semibold)).monospacedDigit().lineLimit(1)
                            Text(caption(parcel)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        pickButton(parcel)
                    }
                    .padding(.vertical, 2)
                }
                if parcels.count > 3 {
                    Text("还有 \(parcels.count - 3) 件").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            } else {
                let first = parcels[0]
                Spacer(minLength: 0)
                Text(first.metadata["pickupCode"] ?? first.title)
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(caption(first)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if parcels.count > 1 {
                    Text("另有 \(parcels.count - 1) 件").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func caption(_ parcel: CalendarItem) -> String {
        [parcel.metadata["station"] ?? parcel.location, parcel.start.formatted("M/d H:mm", calendar: cal)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
