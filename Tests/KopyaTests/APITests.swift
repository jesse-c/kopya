import XCTest
import Vapor
@testable import Kopya
import XCTVapor
import GRDB

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
        app = try Application(.testing)
        app.http.server.configuration.port = Int.random(in: 8080...9000)
    }
    
    override func tearDownWithError() throws {
        app.shutdown()
        app = nil
        
        // Clean up database file
        if let path = dbPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
    
    func testHistoryEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()
        try setupRoutes(app, dbManager)
        
        // Add test entries
        let entries = [
            ("Test content 1", "public.utf8-plain-text", Date()),
            ("https://example.com", "public.url", Date()),
            ("Test content 2", "public.utf8-plain-text", Date())
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
        
        // Test basic history endpoint
        try app.test(.GET, "history") { res in
            XCTAssertEqual(res.status, .ok)
            
            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 3)
            XCTAssertEqual(response.total, 3)
        }
        
        // Test with limit
        try app.test(.GET, "history?limit=2") { res in
            XCTAssertEqual(res.status, .ok)
            
            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 2)
            XCTAssertEqual(response.total, 3)
        }
    }
    
    func testSearchEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()
        try setupRoutes(app, dbManager)
        
        // Add test entries with different types
        let now = Date()
        let calendar = Calendar.current
        let entries = [
            ("Old text", "public.utf8-plain-text", calendar.date(byAdding: .hour, value: -2, to: now)!),
            ("https://test.com", "public.url", calendar.date(byAdding: .minute, value: -30, to: now)!),
            ("Recent text", "public.utf8-plain-text", calendar.date(byAdding: .minute, value: -5, to: now)!)
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
        
        // Test relative time range
        try app.test(.GET, "search?range=1h") { res in
            XCTAssertEqual(res.status, .ok)
            
            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 2)
        }
        
        // Test combined filters
        try app.test(.GET, "search?type=public.utf8-plain-text&range=1h") { res in
            XCTAssertEqual(res.status, .ok)
            
            let response = try res.content.decode(HistoryResponse.self)
            XCTAssertEqual(response.entries.count, 1)
            XCTAssertEqual(response.entries[0].content, "Recent text")
        }
    }
    
    func testDeleteEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()
        try setupRoutes(app, dbManager)
        
        // Add test entries
        for i in 1...5 {
            let entry = ClipboardEntry(
                id: nil,
                content: "Content \(i)",
                type: "public.utf8-plain-text",
                timestamp: Date()
            )
            _ = try dbManager.saveEntry(entry)
        }
        
        // Test delete with limit
        try app.test(.DELETE, "history?limit=3") { res in
            XCTAssertEqual(res.status, .ok)
            
            let response = try res.content.decode([String: Int].self)
            XCTAssertEqual(response["deletedCount"], 3)
            XCTAssertEqual(response["remainingCount"], 2)
        }
    }
    
    func testDeleteEntryByIdEndpoint() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()
        try setupRoutes(app, dbManager)
        
        // Add test entries with specific content to easily identify them
        let testEntries = [
            "Entry to keep 1",
            "Entry to delete",
            "Entry to keep 2"
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
