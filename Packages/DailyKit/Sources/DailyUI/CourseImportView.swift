import DailyKit
import SwiftUI
import WebKit

/// 导入课表窗口的状态。
@MainActor @Observable
final class CourseImportModel {
    var address: String
    var detected: RawCourseTable?
    var firstMonday: Date
    var preview: [CourseEntry] = []
    var isLoading = false
    /// 递增时让网页视图加载 `address`。
    var loadRequest = 0
    var navigation: WebNavigation?

    init(address: String, firstMonday: Date) {
        self.address = address
        self.firstMonday = firstMonday
    }

    func receive(_ table: RawCourseTable) {
        detected = table
        preview = table.cells.flatMap(CourseTableParser.parseCell)
            .sorted { ($0.weekday, $0.startUnit, $0.name) < ($1.weekday, $1.startUnit, $1.name) }
    }
}

/// 网页视图的前进 / 后退 / 刷新操作，由 WebView 注入。
struct WebNavigation {
    var back: () -> Void
    var forward: () -> Void
    var reload: () -> Void
}

/// 从教务系统导入课表：在 App 内打开教务网站，由用户自己登录（连着校园 VPN 即可访问），
/// 打开「我的课表」后自动识别表格，确认第一周日期后导入。
struct CourseImportView: View {
    let model: CalendarModel
    @State private var importer: CourseImportModel
    @State private var showingPreview = false
    @Environment(\.dismiss) private var dismiss

    init(model: CalendarModel) {
        self.model = model
        _importer = State(initialValue: CourseImportModel(
            address: Preferences.shared.courseSiteURL,
            firstMonday: model.courseSchedule?.firstMonday ?? CourseImportView.defaultFirstMonday
        ))
    }

    /// 本学期第一周周一。
    static var defaultFirstMonday: Date {
        Calendar.mondayFirst.date(from: DateComponents(year: 2026, month: 8, day: 31)) ?? .now
    }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()
            CourseWebView(importer: importer)
                .frame(minWidth: 900, minHeight: 560)
            Divider()
            footer
        }
        .frame(width: 1080, height: 760)
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { importer.navigation?.back() } label: { Image(systemName: "chevron.left") }
                .help("后退")
            Button { importer.navigation?.forward() } label: { Image(systemName: "chevron.right") }
                .help("前进")
            Button { importer.navigation?.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新")
            TextField("教务系统网址", text: $importer.address)
                .textFieldStyle(.roundedBorder)
                .onSubmit(load)
            if importer.isLoading { ProgressView().controlSize(.small) }
            Button("打开", action: load)
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(10)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let table = importer.detected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已识别课表\(table.semester.map { "：\($0)" } ?? "")")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(Set(importer.preview.map(\.name)).count) 门课 · \(importer.preview.count) 个上课时段 · \(table.units.count) 节作息时间")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button("预览") { showingPreview = true }
                    .popover(isPresented: $showingPreview, arrowEdge: .top) { previewList }
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("连上校园 VPN，登录后打开「我的课表」，识别到课表后这里会提示。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            DatePicker("第一周周一", selection: $importer.firstMonday, displayedComponents: .date)
                .datePickerStyle(.field)
                .fixedSize()
            Button("导入课表", action: importSchedule)
                .keyboardShortcut(.defaultAction)
                .disabled(importer.preview.isEmpty)
        }
        .padding(12)
    }

    private var previewList: some View {
        let weekdays = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return List(importer.preview, id: \.self) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: 13, weight: .semibold))
                Text([weekdays[min(max(entry.weekday, 0), 7)] + " 第\(entry.startUnit)-\(entry.endUnit)节",
                      entry.weeksText, entry.room, entry.teacher].compactMap { $0 }.filter { !$0.isEmpty }
                        .joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 420, height: 420)
    }

    private func load() {
        var text = importer.address.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        importer.address = text
        importer.loadRequest += 1
    }

    private func importSchedule() {
        guard let table = importer.detected else { return }
        Preferences.shared.courseSiteURL = importer.address
        model.actions.importCourseSchedule(CourseSchedule.build(from: table, firstMonday: importer.firstMonday))
        dismiss()
    }
}

/// 内嵌浏览器。登录状态保存在默认的网站数据里，下次打开通常不用再登录。
private struct CourseWebView: NSViewRepresentable {
    let importer: CourseImportModel

    func makeCoordinator() -> Coordinator { Coordinator(importer: importer) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: CourseTableScript.source, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false))
        controller.add(context.coordinator, name: CourseTableScript.messageName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        importer.navigation = WebNavigation(
            back: { [weak webView] in webView?.goBack() },
            forward: { [weak webView] in webView?.goForward() },
            reload: { [weak webView] in webView?.reload() }
        )
        context.coordinator.load(importer.address)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastRequest != importer.loadRequest {
            context.coordinator.lastRequest = importer.loadRequest
            context.coordinator.load(importer.address)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: CourseTableScript.messageName)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var importer: CourseImportModel?
        weak var webView: WKWebView?
        var lastRequest = 0

        init(importer: CourseImportModel) {
            self.importer = importer
            self.lastRequest = importer.loadRequest
        }

        func load(_ address: String) {
            guard let url = URL(string: address), url.scheme != nil else { return }
            webView?.load(URLRequest(url: url))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let json = message.body as? String,
                  let table = try? JSONDecoder().decode(RawCourseTable.self, from: Data(json.utf8)),
                  !table.cells.isEmpty
            else { return }
            importer?.receive(table)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            importer?.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            importer?.isLoading = false
            if let url = webView.url?.absoluteString { importer?.address = url }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            importer?.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            importer?.isLoading = false
        }
    }
}

/// 注入到每个页面（含 iframe）的脚本：找到表头含「星期一…」的课表表格，
/// 按 rowspan / colspan 还原成网格，提取每个有内容的格子和第一列的节次标签，发给 App。
enum CourseTableScript {
    static let messageName = "dailyCourseTable"

    static let source = #"""
    (function () {
      if (window.__dailyCourseTable) return;
      window.__dailyCourseTable = true;
      var DAYS = ['一', '二', '三', '四', '五', '六', '日'];

      function dayOf(text) {
        var t = (text || '').replace(/\s/g, '');
        if (t.length > 6) return 0;
        for (var i = 0; i < 7; i++) {
          if (t.indexOf('星期' + DAYS[i]) >= 0 || t === '周' + DAYS[i] || (i === 6 && t.indexOf('星期天') >= 0)) return i + 1;
        }
        return 0;
      }

      function extract(table) {
        var rows = table.rows;
        if (!rows || rows.length < 3) return null;
        var grid = [];
        for (var r = 0; r < rows.length; r++) {
          grid[r] = grid[r] || [];
          var c = 0;
          var cells = rows[r].cells;
          for (var k = 0; k < cells.length; k++) {
            while (grid[r][c]) c++;
            var td = cells[k], rs = td.rowSpan || 1, cs = td.colSpan || 1;
            for (var i = 0; i < rs; i++) {
              grid[r + i] = grid[r + i] || [];
              for (var j = 0; j < cs; j++) grid[r + i][c + j] = { td: td, r0: r };
            }
            c += cs;
          }
        }
        var header = -1, colDay = {};
        for (var hr = 0; hr < Math.min(rows.length, 4) && header < 0; hr++) {
          var found = 0, map = {};
          (grid[hr] || []).forEach(function (g, col) {
            var d = g ? dayOf(g.td.innerText) : 0;
            if (d) { map[col] = d; found++; }
          });
          if (found >= 5) { header = hr; colDay = map; }
        }
        if (header < 0) return null;
        var units = [], out = [], seen = [];
        for (var row = header + 1; row < grid.length; row++) {
          var line = grid[row] || [];
          var first = line[0];
          if (first && first.r0 === row) units.push({ index: row - header, text: (first.td.innerText || '').trim() });
          line.forEach(function (g, col) {
            if (!g || !colDay[col] || g.r0 !== row || seen.indexOf(g.td) >= 0) return;
            seen.push(g.td);
            var text = (g.td.innerText || '').trim();
            var title = g.td.getAttribute('title') || '';
            if (!text && !title) return;
            out.push({ weekday: colDay[col], startUnit: row - header, unitSpan: g.td.rowSpan || 1, text: text, title: title });
          });
        }
        return { units: units, cells: out };
      }

      function semester(doc) {
        var re = /\d{4}\s*-\s*\d{4}\s*学年\s*[一二12]?\s*\d?\s*学期/;
        var inputs = doc.querySelectorAll('input, option[selected], select');
        for (var i = 0; i < inputs.length; i++) {
          var v = inputs[i].value || inputs[i].textContent || '';
          var m = v.match(re);
          if (m) return m[0].replace(/\s/g, '');
        }
        var m2 = (doc.body && doc.body.innerText || '').match(re);
        return m2 ? m2[0].replace(/\s/g, '') : null;
      }

      var last = '';
      function scan() {
        var best = null;
        var tables = document.querySelectorAll('table');
        for (var i = 0; i < tables.length; i++) {
          var result = extract(tables[i]);
          if (result && result.cells.length && (!best || result.cells.length > best.cells.length)) best = result;
        }
        if (!best) return;
        best.semester = semester(document);
        var json = JSON.stringify(best);
        if (json === last) return;
        last = json;
        window.webkit.messageHandlers.dailyCourseTable.postMessage(json);
      }

      var timer = null;
      function schedule() {
        clearTimeout(timer);
        timer = setTimeout(scan, 400);
      }
      new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
      schedule();
    })();
    """#
}
