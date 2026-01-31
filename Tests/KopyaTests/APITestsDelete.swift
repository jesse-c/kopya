import GRDB
@testable import Kopya
import Vapor
import XCTest
import XCTVapor

final class APITestsDeleteById: XCTestCase {
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

        try setupRoutes(app, dbManager, configManager)

        // Get all entries to find the one we want to delete
        let entries = try dbManager.getRecentEntries()
        XCTAssertEqual(entries.count, 3)

        // Find the entry with the content "Entry to delete"
        guard let entryToDelete = entries.first(where: { $0.content == "Entry to delete" }),
              let idToDelete = entryToDelete.id else {
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
}
