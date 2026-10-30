import AppIntents
import DailyKit
import DailyUI
import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// 从共享数据库读取快照，在每个日程开始 / 结束时刷新（和 Mac 版相同）。
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

/// 今天 + 接下来几天：中号、大号。
struct UpcomingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "upcoming", provider: SnapshotProvider()) { entry in
            UpcomingEntryView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "daily://open"))
        }
        .configurationDisplayName("接下来几天")
        .description("今天和之后几天的安排，按日期分组。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct UpcomingEntryView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        UpcomingWidgetView(snapshot: snapshot, layout: family == .systemLarge ? .large : .medium)
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
        .description("短信里收到的取件码，取完可以直接点「已取」。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ParcelEntryView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ParcelWidgetView(snapshot: snapshot, wide: family != .systemSmall) { parcel in
            Button(intent: MarkParcelPickedIntent(itemID: parcel.id)) {
                Text("已取").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.green)
        }
    }
}

/// 下一次出行。
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

@main
struct DailyPhoneWidgetBundle: WidgetBundle {
    var body: some Widget {
        UpcomingWidget()
        ParcelWidget()
        TripWidget()
    }
}
