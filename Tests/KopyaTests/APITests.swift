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
        let dbManager = try DatabaseManager(databasePath: dbPath, maxEntries: 1000)
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
}
