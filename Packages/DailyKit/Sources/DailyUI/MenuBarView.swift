import DailyKit
import SwiftUI

/// 菜单栏面板：今天剩下的安排、最近的出行、待取件和快到的续费，不用打开主窗口。
public struct MenuBarView: View {
    let model: CalendarModel
    /// 打开主窗口（由 App 处理 Dock 图标和激活）。
    let openMain: () -> Void
    @State private var snapshot: WidgetSnapshot?
    @Environment(\.openSettings) private var openSettings

    public init(model: CalendarModel, openMain: @escaping () -> Void) {
        self.model = model
        self.openMain = openMain
    }

    public var body: some View {
        let snapshot = snapshot ?? .placeholder
        let cal = model.calendar
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.date.formatted("M月d日 EEEE", calendar: cal)).font(.system(size: 14, weight: .semibold))
                Text(Lunar.dayText(snapshot.date)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if let schedule = model.courseSchedule, let week = schedule.week(of: snapshot.date, calendar: cal),
                   week >= 1, week <= schedule.lastWeek {
                    Text("第 \(week) 周").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            section("今天") {
                let today = snapshot.days.first?.items ?? []
                if today.isEmpty {
                    Text("今天没有更多安排").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(today.prefix(8)) { item in
                    MenuItemRow(item: item, calendar: cal)
                }
                if today.count > 8 {
                    Text("还有 \(today.count - 8) 项").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if let trip = snapshot.nextTrip, !(snapshot.days.first?.items.contains { $0.id == trip.id } ?? false) {
                section("出行") { MenuItemRow(item: trip, calendar: cal, showDate: true) }
            }

            if !snapshot.pendingParcels.isEmpty {
                section("待取件") {
                    ForEach(snapshot.pendingParcels.prefix(5)) { parcel in
                        HStack(spacing: 8) {
                            Image(systemName: SourceKind.parcel.symbol).foregroundStyle(SourceKind.parcel.color)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(parcel.metadata["pickupCode"] ?? parcel.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .textSelection(.enabled)
                                Text(parcel.metadata["station"] ?? parcel.location ?? "")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("已取") {
                                model.actions.markParcelPicked(parcel)
                                reload()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            let soon = snapshot.upcomingRenewals.filter { $0.date < snapshot.date.addingTimeInterval(7 * 86400) }
            if !soon.isEmpty {
                section("7 天内续费") {
                    ForEach(soon.prefix(3)) { renewal in
                        HStack {
                            Circle().fill(SourceKind.subscription.color).frame(width: 6, height: 6)
                            Text(renewal.subscription.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(renewal.date.formatted("M/d", calendar: cal)) · \(renewal.subscription.priceText)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    openMain()
                    model.newEvent()
                } label: { Label("新建日程", systemImage: "plus") }
                Spacer()
                Button("打开 Daily", action: openMain)
                Menu {
                    Button("立即同步") { model.actions.refresh() }
                    Button("设置…") {
                        openSettings()
                        NSApp.activate()
                    }
                    Divider()
                    Button("退出 Daily") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear(perform: reload)
        .onChange(of: model.lastSync) { reload() }
    }

    private func reload() {
        snapshot = try? WidgetSnapshot.load(from: model.store, now: model.now(), calendar: model.calendar)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct MenuItemRow: View {
    let item: CalendarItem
    let calendar: Calendar
    var showDate = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(item.displayColor).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text([
                    showDate ? item.start.formatted("M月d日 EEE", calendar: calendar) : nil,
                    item.timeText(calendar: calendar),
                    item.location,
                    item.metadata["gate"].map { "检票口 \($0)" },
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
