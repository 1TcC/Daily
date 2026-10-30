import DailyKit
import SwiftUI

/// 主窗口（A · 原生简洁）：侧边栏 + 日 / 周 / 月 / 列表视图。
public struct MainWindowView: View {
    @Bindable var model: CalendarModel
    @State private var pager = Pager()

    public init(model: CalendarModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220 * model.textScale, ideal: 240 * model.textScale,
                                                max: 300 * model.textScale)
        } detail: {
            Group {
                if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    pageContent
                } else {
                    SearchResultsView(model: model)
                }
            }
                .background(Color(nsColor: .textBackgroundColor))
                // 标题交给系统排版：新版 macOS 会把同一组工具栏按钮包进圆角胶囊，自定义文字放进去会顶到边上。
                .navigationTitle(model.title)
                .navigationSubtitle(model.subtitle)
                .toolbar { toolbar }
                .searchable(text: $model.searchText, isPresented: $model.searchPresented, placement: .toolbar,
                            prompt: "搜索日程、地点、取件码")
        }
        .environment(\.uiScale, model.textScale)
        .environment(\.markParcelPicked, { model.actions.markParcelPicked($0) })
        .environment(model)
        .sheet(isPresented: $model.showingInbox) { PendingInboxView(model: model) }
        .sheet(isPresented: $model.showingCourseImport) { CourseImportView(model: model) }
        .sheet(isPresented: $model.showingSubscriptions) { SubscriptionsView(model: model) }
        .sheet(item: $model.editor) { EventEditorView(model: model, draft: $0) }
        .onChange(of: model.mode) { pager.reset() }
    }

    /// 双指左右滑动翻页；上下滑动滚动内容。
    @ViewBuilder
    private var pageContent: some View {
        switch model.mode {
        case .day, .week:
            WeekView(model: model, pager: pager)
                .pagingGesture(.horizontal, pager: pager) { model.step($0) }
        case .month:
            // 月视图：左右滑动翻月，上下滚动看完整个月（安排多的周行会变高）。
            let anchors = model.pageAnchors
            let contentHeight = anchors.map { MonthPage.height(model: model, anchor: $0, scale: model.textScale) }.max() ?? 0
            VStack(spacing: 0) {
                MonthWeekdayHeader()
                Divider()
                GeometryReader { geo in
                    ScrollView(.vertical) {
                        PagedStrip(pager: pager, axis: .horizontal, anchors: anchors) { anchor in
                            MonthPage(model: model, anchor: anchor)
                        }
                        .frame(height: max(contentHeight, geo.size.height))
                    }
                }
            }
            .pagingGesture(.horizontal, pager: pager) { model.step($0) }
        case .list:
            PagedStrip(pager: pager, axis: .horizontal, anchors: model.pageAnchors) { anchor in
                AgendaPage(model: model, anchor: anchor)
            }
            .pagingGesture(.horizontal, pager: pager) { model.step($0) }
        }
    }

    /// 工具栏按钮 / 快捷键翻页，和手势一样滑过去。
    private func page(_ delta: Int) {
        pager.finish(delta) { model.step(delta) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { page(-1) } label: { Image(systemName: "chevron.left") }
                .help("上一页（⌘←）")
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("今天") { model.goToToday() }
                .help("回到今天（⌘T）")
                .keyboardShortcut("t", modifiers: .command)
            Button { page(1) } label: { Image(systemName: "chevron.right") }
                .help("下一页（⌘→）")
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        ToolbarItem(placement: .principal) {
            Picker("视图", selection: $model.mode) {
                ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.actions.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.isSyncing ? 360 : 0))
                    .animation(model.isSyncing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: model.isSyncing)
            }
            .help("刷新：同步全部来源（⌘R）")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isSyncing)
            Button { model.newEvent() } label: { Image(systemName: "plus") }
                .help("新建日程（⌘N）")
        }
    }
}

/// 「文件」菜单里的新建日程和「编辑」菜单里的搜索。
public struct EventCommands: Commands {
    let model: CalendarModel

    public init(model: CalendarModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建日程") { model.newEvent() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("搜索日程") { model.searchPresented = true }
                .keyboardShortcut("f", modifiers: .command)
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
