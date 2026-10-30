import AppIntents
import DailyKit
import DailyUI
import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// 从共享数据库读取快照，在每个日程开始 / 结束时刷新。
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let first = entry(at: .now)
        let entries = first.snapshot.refreshDates().prefix(30).map { entry(at: $0) }
        completion(Timeline(entries: entries.isEmpty ? [first] : Array(entries), policy: .atEnd))
    }

    private func entry(at date: Date) -> SnapshotEntry {
        let snapshot = (try? ItemStore(url: AppGroup.databaseURL))
            .flatMap { try? WidgetSnapshot.load(from: $0, now: date) } ?? .placeholder
        return SnapshotEntry(date: date, snapshot: snapshot)
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "today", provider: SnapshotProvider()) { entry in
            TodayAgendaWidgetView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "daily://open"))
        }
        .configurationDisplayName("今日日程")
        .description("今天所有来源的安排。")
        .supportedFamilies([.systemLarge])
    }
}

struct NowNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "now-next", provider: SnapshotProvider()) { entry in
            NowNextWidgetView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "daily://open"))
        }
        .configurationDisplayName("进行中 / 下一项")
        .description("当前正在进行的安排和接下来的一项。")
        .supportedFamilies([.systemMedium])
    }
}

struct SubscriptionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "subscriptions", provider: SnapshotProvider()) { entry in
            SubscriptionEntryView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "daily://subscriptions"))
        }
        .configurationDisplayName("订阅支出")
        .description("本月订阅总额和接下来的续费。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TripWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "trip", provider: SnapshotProvider()) { entry in
            TripWidgetView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "daily://open" + (entry.snapshot.nextTrip.map { "?date=\(Int($0.start.timeIntervalSince1970))" } ?? "")))
        }
        .configurationDisplayName("下一次出行")
        .description("最近两周内的车次 / 航班。")
        .supportedFamilies([.systemSmall])
    }
}

/// 仿系统「日历」小组件：今天 + 接下来几天，有中号（长条）、大号、超大号。
struct UpcomingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "upcoming", provider: SnapshotProvider()) { entry in
            UpcomingEntryView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "daily://open"))
        }
        .configurationDisplayName("接下来几天")
        .description("今天和之后几天的安排，按日期分组。")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

/// 待取件：小号显示最新的取件码，中号可以直接点「已取」。
struct ParcelWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "parcels", provider: SnapshotProvider()) { entry in
            ParcelEntryView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "daily://open"))
        }
        .configurationDisplayName("待取件")
        .description("短信里收到的取件码，取完可以直接在小组件上点「已取」。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ParcelEntryView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ParcelWidgetView(snapshot: snapshot, wide: family != .systemSmall) { parcel in
            Button(intent: MarkParcelPickedIntent(itemID: parcel.id)) {
                Text("已取").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(SourceKind.parcel.color)
        }
    }
}

private struct SubscriptionEntryView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        SubscriptionWidgetView(snapshot: snapshot, wide: family == .systemMedium)
    }
}

private struct UpcomingEntryView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemLarge: UpcomingWidgetView(snapshot: snapshot, layout: .large)
        case .systemExtraLarge: UpcomingWidgetView(snapshot: snapshot, layout: .extraLarge)
        default: UpcomingWidgetView(snapshot: snapshot, layout: .medium)
        }
    }
}

@main
struct DailyWidgetBundle: WidgetBundle {
    var body: some Widget {
        UpcomingWidget()
        ParcelWidget()
        TodayWidget()
        NowNextWidget()
        SubscriptionWidget()
        TripWidget()
    }
}
