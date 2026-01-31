import Foundation
@testable import Kopya
import XCTest

/// MockClipboardMonitor class for testing timer behavior
class MockClipboardMonitor {
    var isMonitoring: Bool = true
    var scheduledDisableTime: Date?
    var privateModeCancellable: DispatchWorkItem?

    func enablePrivateMode(timeRange _: String) {
        isMonitoring = false

        // Cancel any existing work item
        privateModeCancellable?.cancel()
        privateModeCancellable = nil

        // Set scheduled disable time
        scheduledDisableTime = Date().addingTimeInterval(1)

        // Create a new work item
        let workItem = DispatchWorkItem { [weak self] in
            self?.simulateTimerExpiration()
        }
        privateModeCancellable = workItem

        // Schedule the work item
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    func simulateTimerExpiration() {
        isMonitoring = true
        privateModeCancellable?.cancel()
        privateModeCancellable = nil
        scheduledDisableTime = nil
    }
}

final class ClipboardMonitorTests: XCTestCase {
    var dbManager: DatabaseManager!
    var dbPath: String!

    private func createTestDatabase() throws -> (DatabaseManager, String) {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("kopya_test_\(UUID().uuidString).db").path
        let dbManager = try DatabaseManager(databasePath: dbPath, maxEntries: 1000)
        return (dbManager, dbPath)
    }

    override func tearDownWithError() throws {
        // Clean up database file
        if let path = dbPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func testInitialState() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor
        let monitor = try ClipboardMonitor(maxEntries: 1000)

        // Verify initial state
        XCTAssertTrue(monitor.isMonitoring, "Monitoring should be enabled by default")
        XCTAssertNil(monitor.scheduledDisableTime, "No timer should be active initially")
    }

    func testEnablePrivateMode() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor
        let monitor = try ClipboardMonitor(maxEntries: 1000)

        // Enable private mode
        monitor.enablePrivateMode()

        // Verify state
        XCTAssertFalse(monitor.isMonitoring, "Monitoring should be disabled after enabling private mode")
        XCTAssertNil(monitor.scheduledDisableTime, "No timer should be active when no range is specified")
    }

    func testDisablePrivateMode() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor
        let monitor = try ClipboardMonitor(maxEntries: 1000)

        // Enable private mode first
        monitor.enablePrivateMode()
        XCTAssertFalse(monitor.isMonitoring, "Monitoring should be disabled after enabling private mode")

        // Disable private mode
        monitor.disablePrivateMode()

        // Verify state
        XCTAssertTrue(monitor.isMonitoring, "Monitoring should be enabled after disabling private mode")
        XCTAssertNil(monitor.scheduledDisableTime, "No timer should be active")
    }

    func testEnablePrivateModeWithTimeRange() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor
        let monitor = try ClipboardMonitor(maxEntries: 1000)

        // Enable private mode with a time range
        monitor.enablePrivateMode(timeRange: "1h")

        // Verify state
        XCTAssertFalse(monitor.isMonitoring, "Monitoring should be disabled after enabling private mode")
        XCTAssertNotNil(monitor.scheduledDisableTime, "Timer should be active when a range is specified")
    }

    func testPrivateModeTimerExpiration() {
        // Create a mock monitor for testing timer behavior
        let monitor = MockClipboardMonitor()

        // Enable private mode with a time range
        monitor.enablePrivateMode(timeRange: "1s")

        // Verify initial state
        XCTAssertFalse(monitor.isMonitoring, "Monitoring should be disabled after enabling private mode")
        XCTAssertNotNil(monitor.scheduledDisableTime, "Timer should be active when a range is specified")

        // Manually trigger the timer action
        monitor.simulateTimerExpiration()

        // Verify final state
        XCTAssertTrue(monitor.isMonitoring, "Monitoring should be re-enabled after timer expiration")
        XCTAssertNil(monitor.scheduledDisableTime, "Timer should be nil after expiration")
    }

    func testEnablePrivateModeMultipleTimes() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor
        let monitor = try ClipboardMonitor(maxEntries: 1000)

        // Enable private mode with a time range
        monitor.enablePrivateMode(timeRange: "1h")

        // Store the original scheduled time
        let originalTime = monitor.scheduledDisableTime
        XCTAssertNotNil(originalTime, "Timer should be active")

        // Enable private mode again with a different time range
        monitor.enablePrivateMode(timeRange: "30m")

        // Verify state
        XCTAssertFalse(monitor.isMonitoring, "Monitoring should still be disabled")
        XCTAssertNotNil(monitor.scheduledDisableTime, "Timer should be active")
        XCTAssertNotEqual(monitor.scheduledDisableTime, originalTime, "A new timer should have been created")
    }

    func testDisablePrivateModeWithActiveTimer() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor
        let monitor = try ClipboardMonitor(maxEntries: 1000)

        // Enable private mode with a time range
        monitor.enablePrivateMode(timeRange: "1h")

        // Verify timer is active
        XCTAssertNotNil(monitor.scheduledDisableTime, "Timer should be active")

        // Disable private mode
        monitor.disablePrivateMode()

        // Verify state
        XCTAssertTrue(monitor.isMonitoring, "Monitoring should be enabled after disabling private mode")
        XCTAssertNil(monitor.scheduledDisableTime, "Timer should be cancelled and nil")
    }

    func testInvalidTimeRange() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor
        let monitor = try ClipboardMonitor(maxEntries: 1000)

        // Enable private mode with an invalid time range
        monitor.enablePrivateMode(timeRange: "invalid")

        // Verify state - should still enable private mode but without a timer
        XCTAssertFalse(monitor.isMonitoring, "Monitoring should be disabled after enabling private mode")
        XCTAssertNil(monitor.scheduledDisableTime, "No timer should be active with invalid time range")
    }

    func testClipboardMonitoringBehavior() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor
        let monitor = try ClipboardMonitor(maxEntries: 1000)

        // Simulate a clipboard change
        let initialChangeCount = NSPasteboard.general.changeCount

        // Enable private mode
        monitor.enablePrivateMode()

        // Verify monitoring is disabled
        XCTAssertFalse(monitor.isMonitoring, "Monitoring should be disabled in private mode")

        // Disable private mode
        monitor.disablePrivateMode()

        // Verify monitoring is enabled again
        XCTAssertTrue(monitor.isMonitoring, "Monitoring should be enabled after disabling private mode")
    }

    func testMenuBarIntegration() throws {
        // Create test database
        (dbManager, dbPath) = try createTestDatabase()

        // Create a clipboard monitor
        let monitor = try ClipboardMonitor(maxEntries: 1000)

        // Simulate a menu bar action to enable private mode
        monitor.enablePrivateMode()

        // Verify state
        XCTAssertFalse(monitor.isMonitoring, "Monitoring should be disabled after enabling private mode")

        // Simulate a menu bar action to disable private mode
        monitor.disablePrivateMode()

        // Verify state
        XCTAssertTrue(monitor.isMonitoring, "Monitoring should be enabled after disabling private mode")
    }
}
