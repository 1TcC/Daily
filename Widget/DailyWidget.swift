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
        }
        .configurationDisplayName("进行中 / 下一项")
        .description("当前正在进行的安排和接下来的一项。")
        .supportedFamilies([.systemMedium])
    }
}

struct SubscriptionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "subscriptions", provider: SnapshotProvider()) { entry in
            SubscriptionWidgetView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("订阅支出")
        .description("本月订阅总额和下一次续费。")
        .supportedFamilies([.systemSmall])
    }
}

struct TripWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "trip", provider: SnapshotProvider()) { entry in
            TripWidgetView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("下一次出行")
        .description("最近两周内的车次 / 航班。")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct DailyWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        NowNextWidget()
        SubscriptionWidget()
        TripWidget()
    }
}
