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
                .navigationSplitViewColumnWidth(min: 220 * model.textScale, ideal: 240 * model.textScale,
                                                max: 300 * model.textScale)
        } detail: {
            pageContent
                // 双指左右滑动翻页；月视图里上下滑动也翻页，周 / 日视图上下滑动滚动时间轴。
                .scrollPaging(vertical: model.mode == .month) { delta, vertical in
                    model.page(delta, vertical: vertical)
                }
                .clipped()
                .background(Color(nsColor: .textBackgroundColor))
                .toolbar { toolbar }
        }
        .environment(\.uiScale, model.textScale)
        .sheet(isPresented: $model.showingInbox) { PendingInboxView(model: model) }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.mode {
        // 周 / 日视图不重建视图，保留时间轴的滚动位置。
        case .day, .week:
            WeekView(model: model)
        case .month:
            MonthView(model: model)
                .id(model.visibleInterval.start)
                .transition(.push(from: model.pageEdge))
        case .list:
            AgendaListView(model: model)
                .id(model.visibleInterval.start)
                .transition(.push(from: model.pageEdge))
        }
    }

    private func page(_ delta: Int) {
        withAnimation(.easeOut(duration: 0.22)) { model.page(delta) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { page(-1) } label: { Image(systemName: "chevron.left") }
                .help("上一页（⌘←）")
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("今天") { withAnimation(.easeOut(duration: 0.22)) { model.goToToday() } }
                .help("回到今天（⌘T）")
                .keyboardShortcut("t", modifiers: .command)
            Button { page(1) } label: { Image(systemName: "chevron.right") }
                .help("下一页（⌘→）")
                .keyboardShortcut(.rightArrow, modifiers: .command)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.title).scaledFont(17, weight: .semibold)
                Text(model.subtitle).scaledFont(14).foregroundStyle(.secondary)
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

/// 「显示」菜单里的字体大小命令。
public struct TextSizeCommands: Commands {
    let model: CalendarModel

    public init(model: CalendarModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("放大字体") { model.textScale = TextScale.larger(than: model.textScale) }
                .keyboardShortcut("=", modifiers: .command)
            Button("缩小字体") { model.textScale = TextScale.smaller(than: model.textScale) }
                .keyboardShortcut("-", modifiers: .command)
            Button("默认字体大小") { model.textScale = TextScale.standard }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
