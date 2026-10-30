import Foundation
import Testing
@testable import DailyKit

@Suite struct DayLayoutTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ title: String, _ startMin: Double, _ endMin: Double) -> CalendarItem {
        CalendarItem(sourceKind: .course, sourceID: "t", externalID: title, title: title,
                     start: base.addingTimeInterval(startMin * 60), end: base.addingTimeInterval(endMin * 60))
    }

    func placed(_ items: [CalendarItem]) -> [String: PositionedItem] {
        Dictionary(uniqueKeysWithValues: DayLayout.layout(items).map { ($0.item.title, $0) })
    }

    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func singleItemTakesFullWidth() {
        let p = placed([item("a", 0, 60)])["a"]!
        #expect(p.x == 0 && p.width == 1)
    }

    @Test func overlappingItemsSitSideBySide() {
        let p = placed([item("英语", 0, 45), item("概率", 30, 125)])
        #expect(p["英语"]!.x == 0 && p["英语"]!.width == 0.5)
        #expect(p["概率"]!.x == 0.5 && p["概率"]!.width == 0.5)
    }

    @Test func nonOverlappingItemsDoNotAffectEachOther() {
        let p = placed([item("a", 0, 60), item("b", 60, 120)])
        #expect(p["a"]!.width == 1 && p["b"]!.width == 1)
    }

    @Test func reusedColumnStaysBesideOngoingItem() {
        // 英语角 13:00–13:45、概率论 13:30–15:05、体育 14:00–15:40：体育复用左栏，和概率论并排，互不遮挡
        let p = placed([item("英语角", 0, 45), item("概率论", 30, 125), item("体育", 60, 160)])
        #expect(p["体育"]!.x == 0 && p["体育"]!.width == 0.5)
        #expect(p["概率论"]!.x == 0.5)
    }

    @Test func expandsIntoFreeColumnsToTheRight() {
        // a 占满整段；b、c 让簇有三栏；d 开始时 b、c 都已结束，可以占右边两栏
        let p = placed([item("a", 0, 100), item("b", 10, 30), item("c", 15, 35), item("d", 50, 80)])
        #expect(close(p["b"]!.width, 1.0 / 3))
        #expect(close(p["d"]!.x, 1.0 / 3) && close(p["d"]!.width, 2.0 / 3))
    }
}
