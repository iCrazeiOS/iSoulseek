import XCTest
@testable import iSoulseek

final class SearchSortOrderTests: XCTestCase {

    private func result(size: UInt64, bitrate: UInt32? = nil,
                        duration: UInt32? = nil, speed: UInt32 = 0) -> SearchResult {
        var attributes: [UInt32: UInt32] = [:]
        if let bitrate { attributes[SearchAttribute.bitrate.rawValue] = bitrate }
        if let duration { attributes[SearchAttribute.duration.rawValue] = duration }
        return SearchResult(username: "u", token: 1,
                            file: ShareFile(name: "a.bin", size: size, attributes: attributes),
                            isSlotFree: true, averageSpeed: speed, queueLength: 0)
    }

    func testArrivalNeverReorders() {
        XCTAssertFalse(SearchSortOrder.arrival.isOrderedBefore(result(size: 1), result(size: 2)))
        XCTAssertFalse(SearchSortOrder.arrival.isOrderedBefore(result(size: 2), result(size: 1)))
    }

    func testSizeOrdering() {
        XCTAssertTrue(SearchSortOrder.largest.isOrderedBefore(result(size: 10), result(size: 5)))
        XCTAssertFalse(SearchSortOrder.largest.isOrderedBefore(result(size: 5), result(size: 10)))
        XCTAssertFalse(SearchSortOrder.largest.isOrderedBefore(result(size: 5), result(size: 5)))

        XCTAssertTrue(SearchSortOrder.smallest.isOrderedBefore(result(size: 5), result(size: 10)))
        XCTAssertFalse(SearchSortOrder.smallest.isOrderedBefore(result(size: 10), result(size: 5)))
    }

    func testAttributeOrderingTreatsMissingAsZero() {
        XCTAssertTrue(SearchSortOrder.bitrate.isOrderedBefore(result(size: 1, bitrate: 320),
                                                             result(size: 1)))
        XCTAssertFalse(SearchSortOrder.bitrate.isOrderedBefore(result(size: 1),
                                                              result(size: 1, bitrate: 320)))

        XCTAssertTrue(SearchSortOrder.duration.isOrderedBefore(result(size: 1, duration: 200),
                                                              result(size: 1, duration: 100)))
        XCTAssertFalse(SearchSortOrder.duration.isOrderedBefore(result(size: 1, duration: 100),
                                                               result(size: 1, duration: 200)))
    }

    func testSpeedOrderingTreatsMissingAsZero() {
        XCTAssertTrue(SearchSortOrder.fastest.isOrderedBefore(result(size: 1, speed: 500),
                                                             result(size: 1, speed: 100)))
        XCTAssertFalse(SearchSortOrder.fastest.isOrderedBefore(result(size: 1, speed: 100),
                                                              result(size: 1, speed: 500)))
        XCTAssertFalse(SearchSortOrder.fastest.isOrderedBefore(result(size: 1, speed: 100),
                                                              result(size: 1, speed: 100)))
    }

    func testSessionStoreRoundTrip() {
        let suite = "SearchSortOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = SessionStore(defaults: defaults, keychainService: "test.\(suite)")
        XCTAssertEqual(store.searchSortOrder, .arrival)

        store.searchSortOrder = .largest
        XCTAssertEqual(defaults.integer(forKey: "searchSortOrder"), SearchSortOrder.largest.rawValue)
        XCTAssertEqual(store.searchSortOrder, .largest)
    }

    func testStatusDefaultsToOnline() {
        let suite = "SearchSortOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = SessionStore(defaults: defaults, keychainService: "test.\(suite)")
        XCTAssertEqual(store.status, .online)

        store.status = .away
        XCTAssertEqual(store.status, .away)
    }
}
