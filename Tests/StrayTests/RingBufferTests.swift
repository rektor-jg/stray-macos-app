import XCTest
@testable import Stray

/// Testy bufora pierścieniowego — nazwa zobowiązuje, a pierwsza wersja
/// przesuwała całą tablicę przy każdym dopisaniu.
final class RingBufferTests: XCTestCase {

    func testKeepsChronologicalOrder() {
        var ring = RingBuffer<Int>(capacity: 4)
        for i in 1...3 { ring.append(i) }
        XCTAssertEqual(ring.values, [1, 2, 3])
    }

    func testDropsOldestWhenFull() {
        var ring = RingBuffer<Int>(capacity: 3)
        for i in 1...5 { ring.append(i) }
        XCTAssertEqual(ring.values, [3, 4, 5], "najstarsze mają wypadać, kolejność ma zostać")
        XCTAssertEqual(ring.count, 3)
    }

    func testSurvivesManyWraps() {
        var ring = RingBuffer<Int>(capacity: 120)
        for i in 1...10_000 { ring.append(i) }
        XCTAssertEqual(ring.values.first, 9881)
        XCTAssertEqual(ring.values.last, 10_000)
        XCTAssertEqual(ring.values.count, 120)
    }

    func testEmptyBuffer() {
        let ring = RingBuffer<Int>(capacity: 5)
        XCTAssertTrue(ring.values.isEmpty)
        XCTAssertEqual(ring.count, 0)
    }
}
