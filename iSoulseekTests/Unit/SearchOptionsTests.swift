import XCTest
@testable import iSoulseek

final class SearchOptionsTests: XCTestCase {

    private func result(name: String = "Music\\Album\\song.mp3", extension fileExtension: String = "mp3",
                        size: UInt64 = 5_000_000, bitrate: UInt32? = nil,
                        bitDepth: UInt32? = nil, sampleRate: UInt32? = nil,
                        isSlotFree: Bool = true) -> SearchResult {
        var attributes: [UInt32: UInt32] = [:]
        if let bitrate { attributes[SearchAttribute.bitrate.rawValue] = bitrate }
        if let bitDepth { attributes[SearchAttribute.bitDepth.rawValue] = bitDepth }
        if let sampleRate { attributes[SearchAttribute.sampleRate.rawValue] = sampleRate }
        return SearchResult(username: "user", token: 1,
                            file: ShareFile(name: name, size: size, fileExtension: fileExtension,
                                            attributes: attributes),
                            isSlotFree: isSlotFree, averageSpeed: 0, queueLength: 0)
    }

    func testParsingWordsIsForgiving() {
        XCTAssertEqual(SearchOptions.parseWords("FLAC, m4a *.mp3"), ["flac", "m4a", "mp3"])
        XCTAssertEqual(SearchOptions.parseWords(" .flac ,, FLAC\nmp3 "), ["flac", "mp3"])
        XCTAssertEqual(SearchOptions.parseWords("flac;mp3|wav"), ["flac", "mp3", "wav"])
        XCTAssertEqual(SearchOptions.parseWords("   "), [])
    }

    func testExtensionFallsBackToFileName() {
        XCTAssertEqual(ShareFile(name: "Music\\Album\\song.FLAC", size: 1).normalizedExtension, "flac")
        XCTAssertEqual(ShareFile(name: "song", size: 1, fileExtension: "MP3").normalizedExtension, "mp3")
        XCTAssertEqual(ShareFile(name: "song", size: 1, fileExtension: " mp3 ").normalizedExtension, "mp3")
    }

    func testFileTypeFilter() {
        var options = SearchOptions()
        options.fileTypes = ["flac", "m4a"]
        XCTAssertFalse(options.matches(result()))
        XCTAssertTrue(options.matches(result(name: "a\\b.FLAC", extension: "flac")))
        XCTAssertTrue(options.matches(result(name: "a\\b.m4a", extension: "")))
    }

    func testEmptyOptionsMatchEverything() {
        XCTAssertTrue(SearchOptions().matches(result()))
        XCTAssertFalse(SearchOptions().isActive)
    }

    func testSizeLimitsAreInclusive() {
        var options = SearchOptions()
        options.minimumSizeMB = 5
        options.maximumSizeMB = 10

        XCTAssertFalse(options.matches(result(size: 4_999_999)))
        XCTAssertTrue(options.matches(result(size: 5_000_000)))
        XCTAssertTrue(options.matches(result(size: 10_000_000)))
        XCTAssertFalse(options.matches(result(size: 10_000_001)))
    }

    func testBitrateRequiresKnownValue() {
        var options = SearchOptions()
        options.minimumBitrate = 256

        XCTAssertFalse(options.matches(result(bitrate: nil)))
        XCTAssertFalse(options.matches(result(bitrate: 255)))
        XCTAssertTrue(options.matches(result(bitrate: 256)))
    }

    func testExcludedWordsMatchTheWholePath() {
        var options = SearchOptions()
        options.excludedWords = ["live", "demo"]

        XCTAssertFalse(options.matches(result(name: "Music\\Live at Wembley\\song.mp3")))
        XCTAssertFalse(options.matches(result(name: "Music\\Album\\Song (Demo).mp3")))
        XCTAssertTrue(options.matches(result(name: "Music\\Album\\Song.mp3")))
    }

    func testFreeSlotFilter() {
        var options = SearchOptions()
        options.requiresFreeSlot = true

        XCTAssertFalse(options.matches(result(isSlotFree: false)))
        XCTAssertTrue(options.matches(result(isSlotFree: true)))
    }

    func testLosslessByExtensionOrAttributes() {
        var options = SearchOptions()
        options.requiresLossless = true

        XCTAssertTrue(options.matches(result(name: "a\\b.FLAC", extension: "flac")))
        XCTAssertTrue(options.matches(result(name: "a\\b.wav", extension: "")))
        XCTAssertTrue(options.matches(result(bitDepth: 24, sampleRate: 96_000)))
        XCTAssertFalse(options.matches(result(bitDepth: 24)))
        XCTAssertFalse(options.matches(result()))
    }

    func testLosslessIgnoresBitrateFloor() {
        var options = SearchOptions()
        options.requiresLossless = true
        options.minimumBitrate = 320

        XCTAssertTrue(options.matches(result(name: "a\\b.flac", extension: "flac", bitrate: nil)))
    }

    func testSummaryDescribesActiveFilters() {
        var options = SearchOptions()
        XCTAssertEqual(options.summary, "Off")

        options.fileTypes = ["flac"]
        options.minimumBitrate = 256
        options.requiresFreeSlot = true
        XCTAssertEqual(options.summary, "flac · ≥ 256 kbps · free slots")

        options.requiresLossless = true
        XCTAssertEqual(options.summary, "flac · lossless · free slots")
    }

    func testSessionStoreRoundTrip() {
        let suite = "SearchOptionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SessionStore(defaults: defaults, keychainService: "test.\(suite)")
        XCTAssertEqual(store.searchOptions, SearchOptions())

        var options = SearchOptions()
        options.fileTypes = ["flac", "mp3"]
        options.excludedWords = ["live"]
        options.minimumSizeMB = 10
        options.maximumSizeMB = 500
        options.minimumBitrate = 320
        options.requiresLossless = true
        options.requiresFreeSlot = true
        store.searchOptions = options

        XCTAssertEqual(store.searchOptions, options)
    }

    func testDecodingOlderOptionsUsesDefaults() throws {
        let data = try JSONEncoder().encode(["fileTypes": ["flac"]])
        let options = try JSONDecoder().decode(SearchOptions.self, from: data)

        XCTAssertEqual(options.fileTypes, ["flac"])
        XCTAssertEqual(options.excludedWords, [])
        XCTAssertNil(options.minimumSizeMB)
        XCTAssertFalse(options.requiresLossless)
        XCTAssertFalse(options.requiresFreeSlot)
    }
}
