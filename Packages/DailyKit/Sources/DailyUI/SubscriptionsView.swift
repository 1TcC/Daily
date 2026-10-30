import DailyKit
import SwiftUI

/// 「订阅管理」弹窗：列出、添加、编辑、停用和删除付费订阅。
public struct SubscriptionsView: View {
    let model: CalendarModel

    public init(model: CalendarModel) {
        self.model = model
    }
    @Environment(\.dismiss) private var dismiss
    /// 正在编辑的订阅（新建时是一个未保存的草稿）。
    @State private var editing: EditingTarget?
    @State private var pendingDelete: Subscription?

    private struct EditingTarget: Identifiable {
        var subscription: Subscription
        var isNew: Bool
        var id: UUID { subscription.id }
    }

    private var today: Date { model.calendar.startOfDay(for: model.now()) }

    /// 在订的按下次续费日排序，停用的排在最后。
    private var sorted: [Subscription] {
        let active = model.subscriptions.filter(\.isActive).sorted {
            ($0.nextRenewal(after: today, calendar: model.calendar) ?? .distantFuture)
                < ($1.nextRenewal(after: today, calendar: model.calendar) ?? .distantFuture)
        }
        return active + model.subscriptions.filter { !$0.isActive }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("订阅管理").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            if model.subscriptions.isEmpty {
                emptyState
            } else {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                List(sorted) { row($0) }
                    .listStyle(.inset)
            }

            Divider()
            HStack {
                Button {
                    editing = EditingTarget(subscription: newDraft(), isNew: true)
                } label: {
                    Label("添加订阅", systemImage: "plus.circle.fill")
                        .foregroundStyle(SourceKind.subscription.color)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
        .frame(minHeight: 360)
        .sheet(item: $editing) { target in
            SubscriptionEditor(initial: target.subscription, isNew: target.isNew, model: model)
        }
        .confirmationDialog(
            "删除「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let sub = pendingDelete { model.deleteSubscription(sub) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("日历里的续费日也会一起移除。")
        }
    }

    private func newDraft() -> Subscription {
        Subscription(name: "", price: 0, cycle: .monthly, firstBillingDate: today)
    }

    // MARK: 汇总

    /// 「每月约 ¥176 · 每年约 ¥2112（3 项在订）」，多币种按币种相加。
    private var summary: String {
        let active = model.subscriptions.filter(\.isActive)
        guard !active.isEmpty else { return "暂无在订的订阅" }
        let totals = Dictionary(grouping: active, by: \.currency)
            .map { (currency: $0.key, monthly: $0.value.reduce(Decimal(0)) { $0 + $1.monthlyCost }) }
            .sorted { $0.currency < $1.currency }
        let monthly = totals.map { Subscription.format($0.monthly, currency: $0.currency) }.joined(separator: " + ")
        let yearly = totals.map { Subscription.format($0.monthly * 12, currency: $0.currency) }.joined(separator: " + ")
        return "每月约 \(monthly) · 每年约 \(yearly)（\(active.count) 项在订）"
    }

    // MARK: 行

    private func row(_ sub: Subscription) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(sub.name).fontWeight(.semibold)
                    if !sub.isActive {
                        Text("已停用").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(detail(sub)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text("编辑").font(.callout).foregroundStyle(.tertiary)
        }
        .opacity(sub.isActive ? 1 : 0.5)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { editing = EditingTarget(subscription: sub, isNew: false) }
        .contextMenu {
            Button("编辑") { editing = EditingTarget(subscription: sub, isNew: false) }
            Button(sub.isActive ? "停用" : "恢复") {
                var copy = sub
                copy.isActive.toggle()
                model.save(copy)
            }
            Divider()
            Button("删除", role: .destructive) { pendingDelete = sub }
        }
    }

    /// 「¥21 · 每月 · 下次 11月3日（4 天后）」。
    private func detail(_ sub: Subscription) -> String {
        var parts = [sub.priceText, sub.cycle.displayName]
        if sub.isActive, let next = sub.nextRenewal(after: today, calendar: model.calendar) {
            let days = model.calendar.dateComponents([.day], from: today, to: next).day ?? 0
            let relative = switch days {
            case 0: "今天"
            case 1: "明天"
            default: "\(days) 天后"
            }
            parts.append("下次 \(next.formatted("M月d日"))（\(relative)）")
        }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("还没有订阅").font(.title3)
            Text("添加后会在日历里显示续费日，并在续费前提醒你。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.horizontal, 20)
    }
}

/// 新增/编辑订阅的表单。
private struct SubscriptionEditor: View {
    let initial: Subscription
    let isNew: Bool
    let model: CalendarModel
    @Environment(\.dismiss) private var dismiss

    private enum CycleKind: Hashable { case weekly, monthly, quarterly, yearly, custom }

    @State private var name: String
    @State private var priceText: String
    @State private var currency: String
    @State private var cycleKind: CycleKind
    @State private var customDays: Int
    @State private var firstDate: Date
    @State private var isActive: Bool
    @State private var notes: String
    @State private var confirmingDelete = false

    private static let currencies: [(code: String, label: String)] = [
        ("CNY", "人民币 ¥"), ("USD", "美元 $"), ("EUR", "欧元 €"),
        ("HKD", "港币 HK$"), ("JPY", "日元 JP¥"), ("GBP", "英镑 £"),
    ]

    init(initial: Subscription, isNew: Bool, model: CalendarModel) {
        self.initial = initial
        self.isNew = isNew
        self.model = model
        _name = State(initialValue: initial.name)
        _priceText = State(initialValue: isNew ? "" : "\(initial.price)")
        _currency = State(initialValue: initial.currency)
        _firstDate = State(initialValue: initial.firstBillingDate)
        _isActive = State(initialValue: initial.isActive)
        _notes = State(initialValue: initial.notes ?? "")
        switch initial.cycle {
        case .weekly: _cycleKind = State(initialValue: .weekly); _customDays = State(initialValue: 30)
        case .monthly: _cycleKind = State(initialValue: .monthly); _customDays = State(initialValue: 30)
        case .quarterly: _cycleKind = State(initialValue: .quarterly); _customDays = State(initialValue: 30)
        case .yearly: _cycleKind = State(initialValue: .yearly); _customDays = State(initialValue: 30)
        case .everyDays(let n): _cycleKind = State(initialValue: .custom); _customDays = State(initialValue: min(max(n, 1), 999))
        }
    }

    private var parsedPrice: Decimal? {
        let text = priceText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Decimal(string: text, locale: Locale(identifier: "en_US")), value >= 0 else { return nil }
        return value
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && parsedPrice != nil }

    private var cycle: BillingCycle {
        switch cycleKind {
        case .weekly: .weekly
        case .monthly: .monthly
        case .quarterly: .quarterly
        case .yearly: .yearly
        case .custom: .everyDays(customDays)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $name, prompt: Text("例如 iCloud+"))
                    HStack {
                        TextField("价格", text: $priceText, prompt: Text("例如 21 或 9.99"))
                        Picker("币种", selection: $currency) {
                            ForEach(Self.currencies, id: \.code) { Text($0.label).tag($0.code) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Picker("周期", selection: $cycleKind) {
                        Text("每周").tag(CycleKind.weekly)
                        Text("每月").tag(CycleKind.monthly)
                        Text("每季度").tag(CycleKind.quarterly)
                        Text("每年").tag(CycleKind.yearly)
                        Text("自定义天数").tag(CycleKind.custom)
                    }
                    if cycleKind == .custom {
                        Stepper("每 \(customDays) 天", value: $customDays, in: 1...999)
                    }
                }
                Section {
                    DatePicker("首次扣费日", selection: $firstDate, displayedComponents: .date)
                } footer: {
                    Text("之后的续费日按周期从这天推算。")
                }
                Section {
                    Toggle("仍在订阅", isOn: $isActive)
                    TextField("备注", text: $notes, prompt: Text("可选"))
                }
            }
            .formStyle(.grouped)
            .environment(\.locale, Locale(identifier: "zh_CN"))

            Divider()
            HStack {
                if !isNew {
                    Button("删除", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "添加" : "保存") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
        .confirmationDialog("删除「\(initial.name)」？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                model.deleteSubscription(initial)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("日历里的续费日也会一起移除。")
        }
    }

    private func commit() {
        guard let price = parsedPrice else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var sub = initial
        sub.name = trimmedName
        sub.price = price
        sub.currency = currency
        sub.cycle = cycle
        sub.firstBillingDate = firstDate
        sub.isActive = isActive
        sub.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        model.save(sub)
        dismiss()
    }
}
