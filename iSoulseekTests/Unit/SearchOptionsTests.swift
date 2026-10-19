import XCTest
@testable import iSoulseek

final class SearchOptionsTests: XCTestCase {

    private func result(size: UInt64, bitrate: UInt32? = nil, duration: UInt32? = nil,
                        slotFree: Bool = true) -> SearchResult {
        var attributes: [UInt32: UInt32] = [:]
        if let bitrate { attributes[SearchAttribute.bitrate.rawValue] = bitrate }
        if let duration { attributes[SearchAttribute.duration.rawValue] = duration }
        return SearchResult(username: "u", token: 1,
                            file: ShareFile(name: "a.bin", size: size, attributes: attributes),
                            isSlotFree: slotFree, averageSpeed: 0, queueLength: 0)
    }

    func testFreeSlotFilter() {
        var options = SearchOptions()
        XCTAssertTrue(options.allows(result(size: 1, slotFree: false)),
                      "with no filter every result is allowed")

        options.onlyFreeSlots = true
        XCTAssertTrue(options.allows(result(size: 1, slotFree: true)))
        XCTAssertFalse(options.allows(result(size: 1, slotFree: false)))
    }

    func testArrivalNeverReorders() {
        let options = SearchOptions()
        XCTAssertFalse(options.isOrderedBefore(result(size: 1), result(size: 2)))
        XCTAssertFalse(options.isOrderedBefore(result(size: 2), result(size: 1)))
    }

    func testSizeOrdering() {
        var options = SearchOptions(sortOrder: .largest)
        XCTAssertTrue(options.isOrderedBefore(result(size: 10), result(size: 5)))
        XCTAssertFalse(options.isOrderedBefore(result(size: 5), result(size: 10)))
        XCTAssertFalse(options.isOrderedBefore(result(size: 5), result(size: 5)))

        options.sortOrder = .smallest
        XCTAssertTrue(options.isOrderedBefore(result(size: 5), result(size: 10)))
        XCTAssertFalse(options.isOrderedBefore(result(size: 10), result(size: 5)))
    }

    func testAttributeOrderingTreatsMissingAsZero() {
        var options = SearchOptions(sortOrder: .bitrate)
        XCTAssertTrue(options.isOrderedBefore(result(size: 1, bitrate: 320), result(size: 1)))
        XCTAssertFalse(options.isOrderedBefore(result(size: 1), result(size: 1, bitrate: 320)))

        options.sortOrder = .duration
        XCTAssertTrue(options.isOrderedBefore(result(size: 1, duration: 200), result(size: 1, duration: 100)))
        XCTAssertFalse(options.isOrderedBefore(result(size: 1, duration: 100), result(size: 1, duration: 200)))
    }

    func testSessionStoreRoundTrip() {
        let suite = "SearchOptionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = SessionStore(defaults: defaults, keychainService: "test.\(suite)")
        XCTAssertEqual(store.searchOptions, SearchOptions(), "defaults are unfiltered and unordered")

        store.searchOptions = SearchOptions(onlyFreeSlots: true, sortOrder: .largest)
        XCTAssertEqual(defaults.bool(forKey: "searchOnlyFreeSlots"), true)
        XCTAssertEqual(SearchOptions(
            onlyFreeSlots: defaults.bool(forKey: "searchOnlyFreeSlots"),
            sortOrder: SearchSortOrder(rawValue: defaults.integer(forKey: "searchSortOrder")) ?? .arrival
        ), store.searchOptions)
    }
}
