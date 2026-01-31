import GRDB
@testable import Kopya
import Vapor
import XCTest
import XCTVapor

/// Define response structures to match the API
struct ErrorResponse: Content {
    let reason: String
}

final class APITestsHistory: XCTestCase {
    var app: Application!
    var dbManager: DatabaseManager!
    var dbPath: String!
    var configManager: ConfigManager!

    private func createTestDatabase() throws -> (DatabaseManager, String) {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("kopya_test_\(UUID().uuidString).db").path
        let dbManager = try DatabaseManager(databasePath: dbPath, maxEntries: 1000)
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

        let testConfigPath = URL(fileURLWithPath: "./Tests/KopyaTests/test_config.toml").standardizedFileURL
        let fileManager = FileManager.default
        let configPath: URL
        if fileManager.fileExists(atPath: testConfigPath.path) {
            configPath = testConfigPath
        } else {
            fatalError("test_config.toml not found at \(testConfigPath.path)")
        }
        configManager = try ConfigManager(configFile: configPath)
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

        try setupRoutes(app, dbManager, configManager)

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

    func testHistoryEndpointWithOffset() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Add test entries in a specific order
        let entries = [
            "First entry",
            "Second entry",
            "Third entry",
            "Fourth entry",
            "Fifth entry",
        ]

        for content in entries {
            let entry = ClipboardEntry(content: content, type: "public.utf8-plain-text", timestamp: Date())
            _ = try dbManager.saveEntry(entry)
            // Small delay to ensure different timestamps
            Thread.sleep(forTimeInterval: 0.01)
        }

        try setupRoutes(app, dbManager, configManager)

        // Define a response structure to match the API
        struct HistoryResponse: Content {
            let entries: [ClipboardEntryResponse]
            let total: Int
        }

        // Test without offset (should return all entries, most recent first)
        try app.test(.GET, "history") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 5)
            XCTAssertEqual(response.total, 5)
            // Most recent entry should be first (Fifth entry)
            XCTAssertEqual(response.entries[0].content, "Fifth entry")
        }

        // Test with offset=0 without limit (should return 400 Bad Request)
        try app.test(.GET, "history?offset=0") { res in
            XCTAssertEqual(res.status.code, 400)
            // Verify the error message
            let body = try res.content.decode(ErrorResponse.self)
            XCTAssertEqual(body.reason, "The 'offset' parameter requires 'limit' parameter for proper pagination")
        }

        // Test with offset=1 without limit (should return 400 Bad Request)
        try app.test(.GET, "history?offset=1") { res in
            XCTAssertEqual(res.status.code, 400)
            // Verify the error message
            let body = try res.content.decode(ErrorResponse.self)
            XCTAssertEqual(body.reason, "The 'offset' parameter requires 'limit' parameter for proper pagination")
        }

        // Test with offset=2 without limit (should return 400 Bad Request)
        try app.test(.GET, "history?offset=2") { res in
            XCTAssertEqual(res.status.code, 400)
            // Verify the error message
            let body = try res.content.decode(ErrorResponse.self)
            XCTAssertEqual(body.reason, "The 'offset' parameter requires 'limit' parameter for proper pagination")
        }

        // Test with offset=4 without limit (should return 400 Bad Request)
        try app.test(.GET, "history?offset=4") { res in
            XCTAssertEqual(res.status.code, 400)
            // Verify the error message
            let body = try res.content.decode(ErrorResponse.self)
            XCTAssertEqual(body.reason, "The 'offset' parameter requires 'limit' parameter for proper pagination")
        }

        // Test with offset=5 without limit (should return 400 Bad Request)
        try app.test(.GET, "history?offset=5") { res in
            XCTAssertEqual(res.status.code, 400)
            // Verify the error message
            let body = try res.content.decode(ErrorResponse.self)
            XCTAssertEqual(body.reason, "The 'offset' parameter requires 'limit' parameter for proper pagination")
        }

        // Test with offset=10 without limit (should return 400 Bad Request)
        try app.test(.GET, "history?offset=10") { res in
            XCTAssertEqual(res.status.code, 400)
            // Verify the error message
            let body = try res.content.decode(ErrorResponse.self)
            XCTAssertEqual(body.reason, "The 'offset' parameter requires 'limit' parameter for proper pagination")
        }

        // Test combining offset with limit (proper pagination)
        try app.test(.GET, "history?offset=1&limit=2") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 2)
            XCTAssertEqual(response.total, 5)
            // Should get "Fourth entry" and "Third entry"
            XCTAssertEqual(response.entries[0].content, "Fourth entry")
            XCTAssertEqual(response.entries[1].content, "Third entry")
        }

        // Test offset=0 with limit (first page)
        try app.test(.GET, "history?offset=0&limit=2") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 2)
            XCTAssertEqual(response.total, 5)
            // Should get "Fifth entry" and "Fourth entry"
            XCTAssertEqual(response.entries[0].content, "Fifth entry")
            XCTAssertEqual(response.entries[1].content, "Fourth entry")
        }

        // Test offset=2 with limit (second page)
        try app.test(.GET, "history?offset=2&limit=2") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 2)
            XCTAssertEqual(response.total, 5)
            // Should get "Third entry" and "Second entry"
            XCTAssertEqual(response.entries[0].content, "Third entry")
            XCTAssertEqual(response.entries[1].content, "Second entry")
        }

        // Test offset=4 with limit (last entry)
        try app.test(.GET, "history?offset=4&limit=2") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 1) // Only 1 entry remaining
            XCTAssertEqual(response.total, 5)
            XCTAssertEqual(response.entries[0].content, "First entry")
        }

        // Test offset beyond available entries with limit
        try app.test(.GET, "history?offset=5&limit=2") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 0) // No entries available
            XCTAssertEqual(response.total, 5)
        }

        // Test edge case: offset with limit that exceeds available entries
        try app.test(.GET, "history?offset=3&limit=5") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 2) // Only 2 entries available after offset=3
            XCTAssertEqual(response.total, 5)
            XCTAssertEqual(response.entries[0].content, "Second entry")
            XCTAssertEqual(response.entries[1].content, "First entry")
        }
    }
}
