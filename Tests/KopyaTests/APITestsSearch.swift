import GRDB
@testable import Kopya
import Vapor
import XCTest
import XCTVapor

final class APITestsSearch: XCTestCase {
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

    func testSearchEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Add test entries with different types
        let now = Date()
        let calendar = Calendar.current
        let entries = try [
            ("Old text", "public.utf8-plain-text", XCTUnwrap(calendar.date(byAdding: .hour, value: -2, to: now))),
            ("https://test.com", "public.url", XCTUnwrap(calendar.date(byAdding: .minute, value: -30, to: now))),
            (
                "Recent text",
                "public.utf8-plain-text",
                XCTUnwrap(calendar.date(byAdding: .minute, value: -5, to: now))
            ),
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

        try setupRoutes(app, dbManager, configManager)

        // Define a response structure to match the API
        struct HistoryResponse: Content {
            let entries: [ClipboardEntryResponse]
            let total: Int
        }

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
        let fiveMinutesAgo = try XCTUnwrap(calendar.date(byAdding: .minute, value: -10, to: now))
        let isoFormatter = ISO8601DateFormatter()
        let startDateString = isoFormatter.string(from: fiveMinutesAgo)

        try app.test(.GET, "search?type=public.utf8-plain-text&startDate=\(startDateString)") { res in
            XCTAssertEqual(res.status, .ok)

            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 1)
            XCTAssertEqual(response.entries[0].content, "Recent text")
        }
    }
}
