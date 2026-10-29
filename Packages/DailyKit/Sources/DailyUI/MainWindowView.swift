import DailyKit
import SwiftUI

/// 主窗口（A · 原生简洁）：侧边栏 + 日 / 周 / 月 / 列表视图。
public struct MainWindowView: View {
    @Bindable var model: CalendarModel

    public init(model: CalendarModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            Group {
                switch model.mode {
                case .day, .week: WeekView(model: model)
                case .month: MonthView(model: model)
                case .list: AgendaListView(model: model)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .toolbar { toolbar }
        }
        .sheet(isPresented: $model.showingInbox) { PendingInboxView(model: model) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .help("上一页")
            Button("今天") { model.goToToday() }
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .help("下一页")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.title).font(.system(size: 17, weight: .semibold))
                Text(model.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
        }
        ToolbarItem(placement: .principal) {
            Picker("视图", selection: $model.mode) {
                ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { } label: { Image(systemName: "magnifyingglass") }.help("搜索")
            Button { } label: { Image(systemName: "plus") }.help("新建日程")
        }
    }
}
