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

    @Test func singleItemTakesFullWidth() {
        let p = placed([item("a", 0, 60)])["a"]!
        #expect(p.x == 0 && p.width == 1 && !p.isStacked)
    }

    @Test func staggeredStartsCascade() {
        // 13:00–13:45 与 13:30–15:05：后者向右缩进、延伸到右边，压在上面
        let p = placed([item("英语", 0, 45), item("概率", 30, 125)])
        #expect(p["英语"]!.x == 0 && p["英语"]!.width == 1)
        #expect(p["概率"]!.isStacked)
        #expect(abs(p["概率"]!.x - 1.0 / 3) < 1e-9)
        #expect(abs(p["概率"]!.x + p["概率"]!.width - 1) < 1e-9)
    }

    @Test func simultaneousStartsSplitEvenly() {
        let p = placed([item("a", 0, 60), item("b", 10, 60)])
        #expect(p["a"]!.width == 0.5 && p["b"]!.width == 0.5)
        #expect(p["b"]!.x == 0.5 && !p["b"]!.isStacked)
    }

    @Test func nonOverlappingItemsDoNotAffectEachOther() {
        let p = placed([item("a", 0, 60), item("b", 60, 120)])
        #expect(p["a"]!.width == 1 && p["b"]!.width == 1)
    }

    @Test func threeWayCascade() {
        let p = placed([item("a", 0, 180), item("b", 30, 180), item("c", 60, 180)])
        #expect(p["a"]!.x == 0)
        #expect(abs(p["b"]!.x - 0.25) < 1e-9 && abs(p["c"]!.x - 0.5) < 1e-9)
        #expect(p["c"]!.isStacked)
    }

    @Test func reusedColumnDoesNotCoverMiddleItem() {
        // 英语角 13:00–13:45、概率论 13:30–15:05、体育 14:00–15:40：
        // 体育开始时概率论还在进行，体育要缩进到概率论右边，而不是回到最左边盖住它。
        let p = placed([item("英语角", 0, 45), item("概率论", 30, 125), item("体育", 60, 160)])
        #expect(p["英语角"]!.x == 0)
        #expect(p["体育"]!.x > p["概率论"]!.x)
        #expect(p["体育"]!.isStacked)
    }
}
