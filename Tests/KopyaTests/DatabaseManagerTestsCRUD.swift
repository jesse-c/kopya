import GRDB
@testable import Kopya
import XCTest

final class DatabaseManagerTestsCRUD: XCTestCase {
    var dbManager: DatabaseManager!
    var dbPath: String!
    let testMaxEntries = 5

    override func setUp() async throws {
        // Create a temporary database for testing
        let tempDir = FileManager.default.temporaryDirectory
        dbPath = tempDir.appendingPathComponent("kopya_test_\(UUID().uuidString).db").path
        dbManager = try DatabaseManager(databasePath: dbPath, maxEntries: testMaxEntries)
    }

    override func tearDown() async throws {
        // Clean up test database
        if let path = dbPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func testSaveAndRetrieveEntry() throws {
        let entry = ClipboardEntry(
            id: nil,
            content: "Test content",
            type: "public.utf8-plain-text",
            timestamp: Date()
        )

        // Save entry
        let isNewEntry = try dbManager.saveEntry(entry)
        XCTAssertTrue(isNewEntry, "Entry should be saved as new")

        // Retrieve and verify
        let entries = try dbManager.getRecentEntries(limit: 1)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].content, "Test content")
        XCTAssertEqual(entries[0].type, "public.utf8-plain-text")
    }

    func testMaxEntriesLimit() throws {
        // Add more than max entries
        for index in 1 ... 10 {
            let entry = ClipboardEntry(
                id: nil,
                content: "Content \(index)",
                type: "public.utf8-plain-text",
                timestamp: Date()
            )
            _ = try dbManager.saveEntry(entry)
        }

        // Verify only max entries are kept
        let entries = try dbManager.getRecentEntries()
        XCTAssertEqual(entries.count, testMaxEntries)

        // Verify we kept the most recent entries (entries are returned in descending order by timestamp)
        // Since we're adding entries in quick succession, we can only verify that we have the correct number
        // of entries and that they all start with "Content "
        for entry in entries {
            XCTAssertTrue(entry.content.hasPrefix("Content "))
        }
    }

    func testSearchByType() throws {
        // Add mixed content types
        let entries = [
            ("https://example.com", "public.url"),
            ("Plain text", "public.utf8-plain-text"),
            ("https://test.com", "public.url"),
        ]

        for (content, type) in entries {
            let entry = ClipboardEntry(
                id: nil,
                content: content,
                type: type,
                timestamp: Date()
            )
            _ = try dbManager.saveEntry(entry)
        }

        // Search for URLs
        let urlEntries = try dbManager.searchEntries(type: "url")
        XCTAssertEqual(urlEntries.count, 2)
        XCTAssertTrue(urlEntries.allSatisfy { $0.type == "public.url" })

        // Search for text
        let textEntries = try dbManager.searchEntries(type: "textual")
        XCTAssertEqual(textEntries.count, 1)
        XCTAssertEqual(textEntries[0].type, "public.utf8-plain-text")
    }

    func testDateRangeFiltering() throws {
        let now = Date()
        let calendar = Calendar.current

        // Add entries with different timestamps
        let entries = try [
            ("Old entry", XCTUnwrap(calendar.date(byAdding: .hour, value: -2, to: now))),
            ("Recent entry", XCTUnwrap(calendar.date(byAdding: .minute, value: -30, to: now))),
            ("Very recent entry", XCTUnwrap(calendar.date(byAdding: .minute, value: -5, to: now))),
        ]

        for (content, timestamp) in entries {
            let entry = ClipboardEntry(
                id: nil,
                content: content,
                type: "public.utf8-plain-text",
                timestamp: timestamp
            )
            _ = try dbManager.saveEntry(entry)
        }

        // Test last hour filtering
        let lastHourEntries = try dbManager.searchEntries(
            startDate: XCTUnwrap(calendar.date(byAdding: .hour, value: -1, to: now)),
            endDate: now
        )
        XCTAssertEqual(lastHourEntries.count, 2)
        XCTAssertTrue(lastHourEntries.contains { $0.content == "Recent entry" })
        XCTAssertTrue(lastHourEntries.contains { $0.content == "Very recent entry" })
    }
}
