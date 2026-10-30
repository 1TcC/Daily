import DailyKit
import SwiftUI

/// 侧边栏「待取件」：短信识别出的还没取的快递，取完点「已取」。
/// 不是每个驿站都会发「已取出」短信，所以需要手动收尾；7 天没取也会自动过期。
struct PendingParcelsSection: View {
    let model: CalendarModel
    @Environment(\.uiScale) private var scale

    var body: some View {
        if !model.pendingParcels.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("待取件 \(model.pendingParcels.count)")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                ForEach(model.pendingParcels) { parcel in
                    PendingParcelRow(item: parcel, calendar: model.calendar) {
                        model.actions.markParcelPicked(parcel)
                    }
                }
            }
        }
    }
}

private struct PendingParcelRow: View {
    let item: CalendarItem
    let calendar: Calendar
    let done: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: SourceKind.parcel.symbol)
                .foregroundStyle(SourceKind.parcel.color)
                .scaledFont(12)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.metadata["pickupCode"] ?? item.title)
                    .scaledFont(13, weight: .semibold)
                    .textSelection(.enabled)
                Text([item.metadata["station"], item.start.formatted("M/d H:mm", calendar: calendar)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .scaledFont(10)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("已取", action: done)
                .controlSize(.small)
                .help("标记为已取件")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(SourceKind.parcel.tint))
    }
}

/// 日程详情里「标记为已取件」用的动作，由主窗口注入。
private struct ParcelPickedKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (CalendarItem) -> Void)? = nil
}

extension EnvironmentValues {
    var markParcelPicked: (@MainActor @Sendable (CalendarItem) -> Void)? {
        get { self[ParcelPickedKey.self] }
        set { self[ParcelPickedKey.self] = newValue }
    }
}
