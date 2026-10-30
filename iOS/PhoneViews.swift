import DailyKit
import DailyUI
import SwiftUI

/// 列表：和系统日历的列表视图一样，从某天起按天列出 31 天内的安排。
struct AgendaView: View {
    let services: PhoneServices
    let onOpen: (CalendarItem) -> Void

    var body: some View {
        let cal = services.calendar
        List {
            if let error = services.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
            }
            ForEach(services.days) { day in
                Section {
                    if day.items.isEmpty {
                        Text("没有安排").foregroundStyle(.secondary).font(.subheadline)
                    }
                    ForEach(day.items) { item in
                        PhoneEventRow(item: item, calendar: cal)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(item) }
                    }
                } header: {
                    DayHeader(date: day.date, calendar: cal)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await services.syncNow() }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DayHeader: View {
    let date: Date
    let calendar: Calendar

    var body: some View {
        let today = calendar.isDateInToday(date)
        let tomorrow = calendar.isDateInTomorrow(date)
        HStack(spacing: 6) {
            Text(date.formatted("M月d日 EEEE", calendar: calendar))
                .foregroundStyle(today ? Color.red : .primary)
            if today || tomorrow { Text(today ? "今天" : "明天").foregroundStyle(.secondary) }
            Spacer()
            Text(Lunar.dayText(date)).foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
    }
}

struct PhoneEventRow: View {
    let item: CalendarItem
    let calendar: Calendar
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.isAllDay ? "全天" : item.start.formatted("H:mm", calendar: calendar))
                if !item.isAllDay, let end = item.end, end > item.start {
                    Text(end.formatted("H:mm", calendar: calendar)).foregroundStyle(.secondary)
                }
            }
            .font(.footnote.monospacedDigit())
            .frame(width: 44, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(item.eventBar(scheme)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.semibold)).lineLimit(2)
                let detail = [item.location, item.metadata["pickupCode"].map { "取件码 \($0)" },
                              item.metadata["gate"].map { "检票口 \($0)" }].compactMap { $0 }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// 待取件：大号取件码，取完点「已取」（Mac 和小组件同步消失）。
struct ParcelsView: View {
    let services: PhoneServices

    var body: some View {
        let cal = services.calendar
        NavigationStack {
            List {
                if services.pendingParcels.isEmpty {
                    ContentUnavailableView("没有要取的快递", systemImage: "shippingbox",
                                           description: Text("收到取件短信后会出现在这里"))
                }
                ForEach(services.pendingParcels) { parcel in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(parcel.metadata["pickupCode"] ?? parcel.title)
                                .font(.title2.weight(.semibold).monospacedDigit())
                                .textSelection(.enabled)
                            Text([parcel.metadata["station"] ?? parcel.location, parcel.metadata["carrier"],
                                  parcel.start.formatted("M/d H:mm", calendar: cal)].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("已取") { services.markPicked(parcel) }
                            .buttonStyle(.bordered)
                    }
                    .swipeActions {
                        Button("已取") { services.markPicked(parcel) }.tint(SourceKind.parcel.color)
                    }
                }
            }
            .refreshable { await services.syncNow() }
            .navigationTitle("待取件")
        }
    }
}

/// 新建日程：写进中转服务，Mac 上显示在「Agent / Bot 写入」里。
struct AddEventView: View {
    let services: PhoneServices
    @State private var draft: EventDraft
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(services: PhoneServices, start: Date) {
        self.services = services
        _draft = State(initialValue: EventDraft(start: start, calendar: services.calendar))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $draft.title)
                    TextField("地点（可选）", text: $draft.location)
                }
                Section {
                    Toggle("全天", isOn: $draft.isAllDay)
                    DatePicker("开始", selection: $draft.start,
                               displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                        .onChange(of: draft.start) { old, new in
                            draft.end = draft.end.addingTimeInterval(new.timeIntervalSince(old))
                        }
                    DatePicker("结束", selection: $draft.end, in: draft.start...,
                               displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                }
                Section {
                    TextField("备注（可选）", text: $draft.notes, axis: .vertical).lineLimit(2...5)
                } footer: {
                    Text("会同步到 Mac 上的 Daily，Grok、Muse 也能看到。")
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .navigationTitle("新建日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("添加") { save() }.disabled(!draft.isValid)
                    }
                }
            }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await services.addEvent(draft)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}

/// 还没连接：扫 Mac 上的二维码，或粘贴地址。
struct ConnectView: View {
    let services: PhoneServices
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "calendar.badge.clock").font(.system(size: 44)).foregroundStyle(.red)
                        Text("连接 Mac 上的 Daily").font(.title2.weight(.semibold))
                        Text("在 Mac 上打开 Daily →「设置」→「AI 连接」，用 iPhone 相机扫描「iPhone 版 Daily」的二维码，点「在 Daily 中打开」即可。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                Section {
                    TextField("https://…/密钥", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("连接") { invalid = !services.connect(text) }
                        .disabled(text.isEmpty)
                    if invalid { Text("地址格式不对").foregroundStyle(.red) }
                } header: {
                    Text("或者粘贴连接地址")
                } footer: {
                    Text("Mac 上「复制连接地址」得到的就是它。地址里含密钥，保存在钥匙串里。")
                }
            }
            .navigationTitle("Daily")
        }
    }
}
