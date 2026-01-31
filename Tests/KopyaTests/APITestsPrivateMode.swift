import GRDB
@testable import Kopya
import Vapor
import XCTest
import XCTVapor

final class APITestsPrivateMode: XCTestCase {
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

    func testPrivateModeEndpoints() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor for testing
        let clipboardMonitor = try ClipboardMonitor(maxEntries: 1000)

        // Store the monitor in the application storage
        app.storage[ClipboardMonitorKey.self] = clipboardMonitor

        try setupRoutes(app, dbManager, configManager)

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
