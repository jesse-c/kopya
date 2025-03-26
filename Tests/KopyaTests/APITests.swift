import GRDB
@testable import Kopya
import Vapor
import XCTest
import XCTVapor

final class APITests: XCTestCase {
    var app: Application!
    var dbManager: DatabaseManager!
    var dbPath: String!

    private func createTestDatabase() throws -> (DatabaseManager, String) {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("kopya_test_\(UUID().uuidString).db").path
        let dbManager = try DatabaseManager(databasePath: dbPath, maxEntries: 1000, backupEnabled: false)
        return (dbManager, dbPath)
    }

    override func setUpWithError() throws {
        // Initialize app for testing
        // Suppress the deprecation warning
        #if compiler(>=5.0)
            #warning("TODO: Update to use async Application.make when tests support async setup")
        #endif
        @available(*, deprecated)
        func createApplication() -> Application {
            Application(.testing)
        }

        app = createApplication()
        app.http.server.configuration.port = Int.random(in: 8080 ... 9000)
    }

    override func tearDownWithError() throws {
        // Shutdown the application
        if app != nil {
            app.shutdown()
        }

        // Clean up database file
        if let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
        }

        // Set variables to nil to ensure proper cleanup
        app = nil
        dbManager = nil
        dbPath = nil
    }

    func testHistoryEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Add test entries
        let entry1 = ClipboardEntry(content: "Test content 1", type: "public.utf8-plain-text", timestamp: Date())
        let entry2 = ClipboardEntry(content: "Test content 2", type: "public.utf8-plain-text", timestamp: Date())

        _ = try dbManager.saveEntry(entry1)
        _ = try dbManager.saveEntry(entry2)

        try setupRoutes(app, dbManager)

        // Define a response structure to match the API
        struct HistoryResponse: Content {
            let entries: [ClipboardEntryResponse]
            let total: Int
        }

        // Test without limit parameter
        try app.test(.GET, "history") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 2)
        }

        // Test with limit parameter
        try app.test(.GET, "history?limit=1") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 1)
        }
    }

    func testSearchEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Add test entries with different types
        let now = Date()
        let calendar = Calendar.current
        let entries = [
            ("Old text", "public.utf8-plain-text", calendar.date(byAdding: .hour, value: -2, to: now)!),
            ("https://test.com", "public.url", calendar.date(byAdding: .minute, value: -30, to: now)!),
            ("Recent text", "public.utf8-plain-text", calendar.date(byAdding: .minute, value: -5, to: now)!),
        ]

        for (content, type, timestamp) in entries {
            let entry = ClipboardEntry(
                id: nil,
                content: content,
                type: type,
                timestamp: timestamp
            )
            _ = try dbManager.saveEntry(entry)
        }

        try setupRoutes(app, dbManager)

        // Test type filter
        try app.test(.GET, "search?type=public.url") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 1)
            XCTAssertEqual(response.entries[0].type, "public.url")
        }

        // Test content query
        try app.test(.GET, "search?query=text") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 2)
            XCTAssertTrue(response.entries.allSatisfy { $0.content.contains("text") })
        }

        // Test without any filters
        try app.test(.GET, "search") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 3)
        }

        // Test combined filters - use explicit date range instead of relative range
        let fiveMinutesAgo = calendar.date(byAdding: .minute, value: -10, to: now)!
        let isoFormatter = ISO8601DateFormatter()
        let startDateString = isoFormatter.string(from: fiveMinutesAgo)

        try app.test(.GET, "search?type=public.utf8-plain-text&startDate=\(startDateString)") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 1)
            XCTAssertEqual(response.entries[0].content, "Recent text")
        }
    }

    func testDeleteEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Add test entries
        for i in 1 ... 5 {
            let entry = ClipboardEntry(
                id: nil,
                content: "Content \(i)",
                type: "public.utf8-plain-text",
                timestamp: Date()
            )
            _ = try dbManager.saveEntry(entry)
        }

        try setupRoutes(app, dbManager)

        // Test delete with limit
        try app.test(.DELETE, "history?limit=3") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode([String: Int].self)
            XCTAssertEqual(response["deletedCount"], 3)
            XCTAssertEqual(response["remainingCount"], 2)
        }
    }

    func testDeleteEntriesByDateRangeEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        let now = Date()
        let calendar = Calendar.current

        // Add entries with different timestamps
        let entries = [
            ("Very old entry", calendar.date(byAdding: .hour, value: -5, to: now)!),
            ("Old entry", calendar.date(byAdding: .hour, value: -4, to: now)!),
            ("Medium old entry", calendar.date(byAdding: .hour, value: -3, to: now)!),
            ("Recent entry", calendar.date(byAdding: .hour, value: -1, to: now)!),
            ("Very recent entry", calendar.date(byAdding: .minute, value: -5, to: now)!),
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

        try setupRoutes(app, dbManager)

        // Format dates for API request
        let formatter = ISO8601DateFormatter()
        let fiveHoursAgo = calendar.date(byAdding: .hour, value: -5, to: now)!
        let twoHoursAgo = calendar.date(byAdding: .hour, value: -2, to: now)!

        // Test delete with date range (start and end dates)
        let startDateStr = formatter.string(from: fiveHoursAgo)
        let endDateStr = formatter.string(from: twoHoursAgo)

        try app.test(.DELETE, "history?start=\(startDateStr)&end=\(endDateStr)") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode([String: Int].self)
            XCTAssertEqual(response["deletedCount"], 3, "Should have deleted 3 entries in the date range")
            XCTAssertEqual(response["remainingCount"], 2, "Should have 2 entries remaining")

            // Verify the remaining entries
            let remainingEntries = try dbManager.getRecentEntries()
            XCTAssertEqual(remainingEntries.count, 2)

            // The entries outside the date range should still be there
            XCTAssertTrue(remainingEntries.contains { $0.content == "Recent entry" })
            XCTAssertTrue(remainingEntries.contains { $0.content == "Very recent entry" })
        }
    }

    func testDeleteEntriesByTimeRangeEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        let now = Date()
        let calendar = Calendar.current

        // Add entries with different timestamps
        let entries = [
            ("Very old entry", calendar.date(byAdding: .hour, value: -5, to: now)!),
            ("Old entry", calendar.date(byAdding: .hour, value: -4, to: now)!),
            ("Medium old entry", calendar.date(byAdding: .hour, value: -3, to: now)!),
            ("Recent entry", calendar.date(byAdding: .hour, value: -1, to: now)!),
            ("Very recent entry", calendar.date(byAdding: .minute, value: -5, to: now)!),
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

        try setupRoutes(app, dbManager)

        // Test delete with time range (last 2 hours)
        try app.test(.DELETE, "history?range=2h") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode([String: Int].self)
            XCTAssertEqual(response["deletedCount"], 2, "Should have deleted 2 entries from the last 2 hours")
            XCTAssertEqual(response["remainingCount"], 3, "Should have 3 entries remaining")

            // Verify the remaining entries
            let remainingEntries = try dbManager.getRecentEntries()
            XCTAssertEqual(remainingEntries.count, 3)

            // The entries older than 2 hours should still be there
            XCTAssertTrue(remainingEntries.contains { $0.content == "Very old entry" })
            XCTAssertTrue(remainingEntries.contains { $0.content == "Old entry" })
            XCTAssertTrue(remainingEntries.contains { $0.content == "Medium old entry" })
        }
    }

    func testDeleteEntriesWithStartDateOnlyEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        let now = Date()
        let calendar = Calendar.current

        // Add entries with different timestamps
        let entries = [
            ("Very old entry", calendar.date(byAdding: .hour, value: -5, to: now)!),
            ("Old entry", calendar.date(byAdding: .hour, value: -4, to: now)!),
            ("Medium old entry", calendar.date(byAdding: .hour, value: -3, to: now)!),
            ("Recent entry", calendar.date(byAdding: .hour, value: -1, to: now)!),
            ("Very recent entry", calendar.date(byAdding: .minute, value: -5, to: now)!),
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

        try setupRoutes(app, dbManager)

        // Format date for API request
        let formatter = ISO8601DateFormatter()
        let threeHoursAgo = calendar.date(byAdding: .hour, value: -3, to: now)!
        let startDateStr = formatter.string(from: threeHoursAgo)

        // Test delete with start date only (should delete entries from 3 hours ago until now)
        try app.test(.DELETE, "history?start=\(startDateStr)") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode([String: Int].self)
            XCTAssertEqual(response["deletedCount"], 3, "Should have deleted 3 entries from 3 hours ago until now")
            XCTAssertEqual(response["remainingCount"], 2, "Should have 2 entries remaining")

            // Verify the remaining entries
            let remainingEntries = try dbManager.getRecentEntries()
            XCTAssertEqual(remainingEntries.count, 2)

            // The entries older than 3 hours should still be there
            XCTAssertTrue(remainingEntries.contains { $0.content == "Very old entry" })
            XCTAssertTrue(remainingEntries.contains { $0.content == "Old entry" })
        }
    }

    func testDeleteEntriesWithDateRangeAndLimitEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        let now = Date()
        let calendar = Calendar.current

        // Add entries with different timestamps
        let entries = [
            ("Very old entry", calendar.date(byAdding: .hour, value: -5, to: now)!),
            ("Old entry", calendar.date(byAdding: .hour, value: -4, to: now)!),
            ("Medium old entry", calendar.date(byAdding: .hour, value: -3, to: now)!),
            ("Recent entry", calendar.date(byAdding: .hour, value: -1, to: now)!),
            ("Very recent entry", calendar.date(byAdding: .minute, value: -5, to: now)!),
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

        try setupRoutes(app, dbManager)

        // Format dates for API request
        let formatter = ISO8601DateFormatter()
        let fiveHoursAgo = calendar.date(byAdding: .hour, value: -5, to: now)!
        let oneHourAgo = calendar.date(byAdding: .hour, value: -1, to: now)!

        let startDateStr = formatter.string(from: fiveHoursAgo)
        let endDateStr = formatter.string(from: oneHourAgo)

        // Test delete with date range and limit (should delete only 2 entries from the range)
        try app.test(.DELETE, "history?start=\(startDateStr)&end=\(endDateStr)&limit=2") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode([String: Int].self)
            XCTAssertEqual(response["deletedCount"], 2, "Should have deleted 2 entries with the limit")
            XCTAssertEqual(response["remainingCount"], 3, "Should have 3 entries remaining")

            // We can't be sure which 2 of the 4 entries in the date range were deleted due to the limit,
            // so we just check the total count
            let remainingEntries = try dbManager.getRecentEntries()
            XCTAssertEqual(remainingEntries.count, 3)
        }
    }

    func testDeleteEntryByIdEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Add test entries with specific content to easily identify them
        let testEntries = [
            "Entry to keep 1",
            "Entry to delete",
            "Entry to keep 2",
        ]

        for content in testEntries {
            let entry = ClipboardEntry(
                id: nil,
                content: content,
                type: "public.utf8-plain-text",
                timestamp: Date()
            )
            _ = try dbManager.saveEntry(entry)
        }

        try setupRoutes(app, dbManager)

        // Get all entries to find the one we want to delete
        let entries = try dbManager.getRecentEntries()
        XCTAssertEqual(entries.count, 3)

        // Find the entry with the content "Entry to delete"
        guard let entryToDelete = entries.first(where: { $0.content == "Entry to delete" }),
              let idToDelete = entryToDelete.id
        else {
            XCTFail("Could not find entry to delete or it has no ID")
            return
        }

        // Test the DELETE endpoint with the specific UUID
        try app.test(.DELETE, "history/\(idToDelete.uuidString)") { res in
            XCTAssertEqual(res.status, .ok)

            struct DeleteResponse: Codable {
                let success: Bool
                let id: String
                let message: String
            }

            let response = try res.content.decode(DeleteResponse.self)
            XCTAssertTrue(response.success)
            XCTAssertEqual(response.id, idToDelete.uuidString)
            XCTAssertEqual(response.message, "Entry deleted successfully")

            // Verify the entry is actually deleted from the database
            let remainingEntries = try dbManager.getRecentEntries()
            XCTAssertEqual(remainingEntries.count, 2)
            XCTAssertFalse(remainingEntries.contains { $0.id == idToDelete })
            XCTAssertTrue(remainingEntries.contains { $0.content == "Entry to keep 1" })
            XCTAssertTrue(remainingEntries.contains { $0.content == "Entry to keep 2" })
        }

        // Test with a non-existent UUID
        let nonExistentId = UUID()
        try app.test(.DELETE, "history/\(nonExistentId.uuidString)") { res in
            XCTAssertEqual(res.status, .notFound)

            struct DeleteResponse: Codable {
                let success: Bool
                let id: String
                let message: String
            }

            let response = try res.content.decode(DeleteResponse.self)
            XCTAssertFalse(response.success)
            XCTAssertEqual(response.id, nonExistentId.uuidString)
            XCTAssertEqual(response.message, "Entry not found")

            // Verify we still have the same 2 entries
            let remainingEntries = try dbManager.getRecentEntries()
            XCTAssertEqual(remainingEntries.count, 2)
        }

        // Test with an invalid UUID format
        try app.test(.DELETE, "history/not-a-valid-uuid") { res in
            XCTAssertEqual(res.status, .badRequest)
        }
    }

    func testPrivateModeEndpoints() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor for testing
        let clipboardMonitor = try ClipboardMonitor(maxEntries: 1000, backupEnabled: false)

        // Store the monitor in the application storage
        app.storage[ClipboardMonitorKey.self] = clipboardMonitor

        try setupRoutes(app, dbManager)

        // Test enabling private mode
        try app.test(.POST, "private/enable") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(PrivateModeResponse.self)
            XCTAssertTrue(response.success)
            XCTAssertEqual(response.message, "Private mode enabled")

            // Verify that the monitor is in private mode
            XCTAssertFalse(clipboardMonitor.isMonitoring)
        }

        // Test disabling private mode
        try app.test(.POST, "private/disable") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(PrivateModeResponse.self)
            XCTAssertTrue(response.success)
            XCTAssertEqual(response.message, "Private mode disabled")

            // Verify that the monitor is not in private mode
            XCTAssertTrue(clipboardMonitor.isMonitoring)
        }

        // Test enabling private mode with time range
        try app.test(.POST, "private/enable?range=1h") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(PrivateModeResponse.self)
            XCTAssertTrue(response.success)
            XCTAssertEqual(response.message, "Private mode enabled for 1h")

            // Verify that the monitor is in private mode
            XCTAssertFalse(clipboardMonitor.isMonitoring)

            // Verify that a timer is set
            XCTAssertNotNil(clipboardMonitor.scheduledDisableTime)
        }
    }
}
