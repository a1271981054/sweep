import XCTest
@testable import SweepAgent

final class TrashTests: XCTestCase {
    private var sandboxRoot: URL!
    private var mockTrash: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-trash-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        sandboxRoot = base
        mockTrash = base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: mockTrash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandboxRoot {
            try? FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    func testInspectIgnoresFinderMetadataAndSizesNestedFolder() throws {
        // Seed .DS_Store which must not appear as a user item
        try Data([0, 1, 2, 3]).write(to: mockTrash.appendingPathComponent(".DS_Store"))

        let emptySummary = TrashStore.inspect(trashDirectory: mockTrash)
        XCTAssertEqual(emptySummary.items, 0)
        XCTAssertEqual(emptySummary.bytes, 0)
        XCTAssertFalse(emptySummary.denied)

        // Create a file and a nested folder with known byte counts
        let topFile = mockTrash.appendingPathComponent("old-archive.zip")
        try Data(repeating: 0x41, count: 1200).write(to: topFile)

        let nestedDir = mockTrash.appendingPathComponent("stale-build", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 3000).write(to: nestedDir.appendingPathComponent("artifact.bin"))

        let summary = TrashStore.inspect(trashDirectory: mockTrash)
        XCTAssertEqual(summary.items, 2)
        XCTAssertEqual(summary.bytes, 4200)
        XCTAssertEqual(summary.top.first?.name, "stale-build")
        XCTAssertEqual(summary.top.first?.isDirectory, true)
    }

    func testSymlinkInsideTrashDoesNotFollowTargetBytesOrDeleteTarget() throws {
        let outsideDir = sandboxRoot.appendingPathComponent("ImportantOutside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let outsideFile = outsideDir.appendingPathComponent("keep.txt")
        try Data(repeating: 0x55, count: 5000).write(to: outsideFile)

        let linkURL = mockTrash.appendingPathComponent("link-to-outside")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideDir)

        let summary = TrashStore.inspect(trashDirectory: mockTrash)
        XCTAssertEqual(summary.items, 1)
        XCTAssertLessThan(summary.bytes, 5000)
        XCTAssertEqual(summary.top.first?.isDirectory, false)

        let emptied = try TrashStore.empty(expectedDigest: summary.digest, trashDirectory: mockTrash, writeAudit: false)
        XCTAssertEqual(emptied.deletedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testEmptyRejectsDigestMismatchAndRemovesOnExactDigest() throws {
        let item = mockTrash.appendingPathComponent("cache.bin")
        try Data(repeating: 0x11, count: 640).write(to: item)

        let before = TrashStore.inspect(trashDirectory: mockTrash)
        XCTAssertEqual(before.items, 1)

        XCTAssertThrowsError(
            try TrashStore.empty(expectedDigest: "wrong-digest", trashDirectory: mockTrash, writeAudit: false)
        ) { error in
            guard case CleanError.digestMismatch = error else {
                XCTFail("Expected digestMismatch, got \(error)")
                return
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))

        let result = try TrashStore.empty(expectedDigest: before.digest, trashDirectory: mockTrash, writeAudit: false)
        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(result.deletedBytes, 640)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))

        let after = TrashStore.inspect(trashDirectory: mockTrash)
        XCTAssertEqual(after.items, 0)
        XCTAssertEqual(after.bytes, 0)
    }
}
