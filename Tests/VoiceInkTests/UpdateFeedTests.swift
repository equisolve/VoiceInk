import Foundation
import XCTest

@testable import VoiceInk

/// A build whose Info.plist has no Sparkle feed must never start the updater.
final class UpdateFeedTests: XCTestCase {
    private var bundleURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in bundleURLs {
            try? FileManager.default.removeItem(at: url)
        }
        bundleURLs = []
    }

    private func makeBundle(info: [String: Any]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateFeedTests-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = "com.example.UpdateFeedTests"
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        bundleURLs.append(root)
        return try XCTUnwrap(Bundle(url: root))
    }

    func testBundleWithFeedHasUpdateFeed() throws {
        let bundle = try makeBundle(info: ["SUFeedURL": "https://example.com/appcast.xml"])
        XCTAssertTrue(UpdaterViewModel.bundleHasUpdateFeed(bundle))
    }

    func testBundleWithoutFeedHasNoUpdateFeed() throws {
        let bundle = try makeBundle(info: [:])
        XCTAssertFalse(UpdaterViewModel.bundleHasUpdateFeed(bundle))
    }

    func testBlankFeedIsNoUpdateFeed() throws {
        let bundle = try makeBundle(info: ["SUFeedURL": "  "])
        XCTAssertFalse(UpdaterViewModel.bundleHasUpdateFeed(bundle))
    }
}
