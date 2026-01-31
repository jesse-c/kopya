import GRDB
@testable import Kopya
import XCTest

final class DatabaseManagerTestsBackup: XCTestCase {
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

    func testCleanOldBackupsWithManyFiles() throws {
        // Create a temporary directory for backup testing
        let tempDir = FileManager.default.temporaryDirectory
        let backupDir = tempDir.appendingPathComponent("kopya_backup_test_\(UUID().uuidString)")

        // Create backup directory
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // Create mock backup files with different creation dates
        let fileManager = FileManager.default
        let baseDate = Date()
        let calendar = Calendar.current

        // Create 10 backup files with different timestamps
        for index in 1 ... 10 {
            let fileName = "history_backup_\(String(format: "%02d", index)).bak"
            let filePath = backupDir.appendingPathComponent(fileName)

            // Create file with mock content
            try "mock backup content \(index)".write(to: filePath, atomically: true, encoding: .utf8)

            // Set creation date (older files first)
            let fileDate = calendar.date(byAdding: .hour, value: -(10 - index), to: baseDate)!
            try fileManager.setAttributes([.creationDate: fileDate], ofItemAtPath: filePath.path)
        }

        // Verify we have 10 files
        let initialFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasSuffix(".bak") }
        XCTAssertEqual(initialFiles.count, 10, "Should have 10 backup files initially")

        // Create a database manager
        let tempDbPath = backupDir.appendingPathComponent("test.db").path
        let dbManager = try DatabaseManager(databasePath: tempDbPath, maxEntries: 100)

        // Test cleanup logic with max 5 backups - this should delete 5 oldest files
        dbManager.cleanupOldBackups(backupDir: backupDir.path, maxBackups: 5)

        // Verify only 5 files remain
        let remainingFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasSuffix(".bak") }
            .sorted()
        XCTAssertEqual(remainingFiles.count, 5, "Should have 5 backup files after cleanup")

        // Verify the newest files remain (files 6-10)
        XCTAssertTrue(remainingFiles.contains("history_backup_06.bak"))
        XCTAssertTrue(remainingFiles.contains("history_backup_07.bak"))
        XCTAssertTrue(remainingFiles.contains("history_backup_08.bak"))
        XCTAssertTrue(remainingFiles.contains("history_backup_09.bak"))
        XCTAssertTrue(remainingFiles.contains("history_backup_10.bak"))

        // Verify oldest files were deleted (files 1-5)
        XCTAssertFalse(remainingFiles.contains("history_backup_01.bak"))
        XCTAssertFalse(remainingFiles.contains("history_backup_02.bak"))
        XCTAssertFalse(remainingFiles.contains("history_backup_03.bak"))
        XCTAssertFalse(remainingFiles.contains("history_backup_04.bak"))
        XCTAssertFalse(remainingFiles.contains("history_backup_05.bak"))

        // Clean up test directory
        try fileManager.removeItem(at: backupDir)
    }

    func testCleanOldBackupsWithExactlyMaxFiles() throws {
        // Create a temporary directory for backup testing
        let tempDir = FileManager.default.temporaryDirectory
        let backupDir = tempDir.appendingPathComponent("kopya_backup_test_exact_\(UUID().uuidString)")

        // Create backup directory
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let fileManager = FileManager.default

        // Create exactly 3 backup files
        for index in 1 ... 3 {
            let fileName = "history_backup_\(index).bak"
            let filePath = backupDir.appendingPathComponent(fileName)
            try "mock backup content \(index)".write(to: filePath, atomically: true, encoding: .utf8)
        }

        // Verify we have 3 files
        let initialFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasSuffix(".bak") }
        XCTAssertEqual(initialFiles.count, 3, "Should have 3 backup files initially")

        // Create a database manager
        let tempDbPath = backupDir.appendingPathComponent("test.db").path
        let dbManager = try DatabaseManager(databasePath: tempDbPath, maxEntries: 100)

        // Test cleanup with max 3 backups - should not delete any files
        dbManager.cleanupOldBackups(backupDir: backupDir.path, maxBackups: 3)

        // Verify all 3 files still remain
        let remainingFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasSuffix(".bak") }
        XCTAssertEqual(remainingFiles.count, 3, "Should still have 3 backup files after cleanup")

        // Clean up test directory
        try fileManager.removeItem(at: backupDir)
    }

    func testCleanOldBackupsWithFewerThanMaxFiles() throws {
        // Create a temporary directory for backup testing
        let tempDir = FileManager.default.temporaryDirectory
        let backupDir = tempDir.appendingPathComponent("kopya_backup_test_fewer_\(UUID().uuidString)")

        // Create backup directory
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let fileManager = FileManager.default

        // Create only 2 backup files
        for index in 1 ... 2 {
            let fileName = "history_backup_\(index).bak"
            let filePath = backupDir.appendingPathComponent(fileName)
            try "mock backup content \(index)".write(to: filePath, atomically: true, encoding: .utf8)
        }

        // Verify we have 2 files
        let initialFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasSuffix(".bak") }
        XCTAssertEqual(initialFiles.count, 2, "Should have 2 backup files initially")

        // Create a database manager
        let tempDbPath = backupDir.appendingPathComponent("test.db").path
        let dbManager = try DatabaseManager(databasePath: tempDbPath, maxEntries: 100)

        // Test cleanup with max 5 backups - should not delete any files
        dbManager.cleanupOldBackups(backupDir: backupDir.path, maxBackups: 5)

        // Verify all 2 files still remain
        let remainingFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasSuffix(".bak") }
        XCTAssertEqual(remainingFiles.count, 2, "Should still have 2 backup files after cleanup")

        // Clean up test directory
        try fileManager.removeItem(at: backupDir)
    }

    func testCleanOldBackupsWithNoBackupFiles() throws {
        // Create a temporary directory for backup testing
        let tempDir = FileManager.default.temporaryDirectory
        let backupDir = tempDir.appendingPathComponent("kopya_backup_test_empty_\(UUID().uuidString)")

        // Create backup directory
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let fileManager = FileManager.default

        // Create some non-backup files to ensure they're not affected
        let nonBackupFile = backupDir.appendingPathComponent("other_file.txt")
        try "not a backup".write(to: nonBackupFile, atomically: true, encoding: .utf8)

        // Verify we have no .bak files
        let initialBackupFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasSuffix(".bak") }
        XCTAssertEqual(initialBackupFiles.count, 0, "Should have no backup files initially")

        // Create a database manager
        let tempDbPath = backupDir.appendingPathComponent("test.db").path
        let dbManager = try DatabaseManager(databasePath: tempDbPath, maxEntries: 100)

        // Test cleanup - should not throw error or affect non-backup files
        dbManager.cleanupOldBackups(backupDir: backupDir.path, maxBackups: 3)

        // Verify no .bak files exist and other file is unaffected
        let remainingBackupFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasSuffix(".bak") }
        XCTAssertEqual(remainingBackupFiles.count, 0, "Should still have no backup files")

        let allFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
        XCTAssertTrue(allFiles.contains("other_file.txt"), "Non-backup file should remain")

        // Clean up test directory
        try fileManager.removeItem(at: backupDir)
    }

    func testCleanOldBackupsWithMixedFileTypes() throws {
        // Create a temporary directory for backup testing
        let tempDir = FileManager.default.temporaryDirectory
        let backupDir = tempDir.appendingPathComponent("kopya_backup_test_mixed_\(UUID().uuidString)")

        // Create backup directory
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let fileManager = FileManager.default
        let baseDate = Date()
        let calendar = Calendar.current

        // Create 5 backup files and 3 non-backup files
        for index in 1 ... 5 {
            let fileName = "history_backup_\(index).bak"
            let filePath = backupDir.appendingPathComponent(fileName)
            try "backup content \(index)".write(to: filePath, atomically: true, encoding: .utf8)

            // Set creation date
            let fileDate = try XCTUnwrap(calendar.date(byAdding: .minute, value: -index, to: baseDate))
            try fileManager.setAttributes([.creationDate: fileDate], ofItemAtPath: filePath.path)
        }

        // Create non-backup files
        for index in 1 ... 3 {
            let fileName = "other_file_\(index).txt"
            let filePath = backupDir.appendingPathComponent(fileName)
            try "other content \(index)".write(to: filePath, atomically: true, encoding: .utf8)
        }

        // Verify initial state
        let initialBackupFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasSuffix(".bak") }
        let initialOtherFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { !$0.hasSuffix(".bak") && !$0.hasSuffix(".db") }

        XCTAssertEqual(initialBackupFiles.count, 5, "Should have 5 backup files initially")
        XCTAssertEqual(initialOtherFiles.count, 3, "Should have 3 non-backup files initially")

        // Create a database manager
        let tempDbPath = backupDir.appendingPathComponent("test.db").path
        let dbManager = try DatabaseManager(databasePath: tempDbPath, maxEntries: 100)

        // Test cleanup with max 2 backups - should delete 3 oldest backup files
        dbManager.cleanupOldBackups(backupDir: backupDir.path, maxBackups: 2)

        // Verify results
        let remainingBackupFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { $0.hasSuffix(".bak") }
            .sorted()
        let remainingOtherFiles = try fileManager.contentsOfDirectory(atPath: backupDir.path)
            .filter { !$0.hasSuffix(".bak") && !$0.hasSuffix(".db") }

        XCTAssertEqual(remainingBackupFiles.count, 2, "Should have 2 backup files after cleanup")
        XCTAssertEqual(remainingOtherFiles.count, 3, "Should still have 3 non-backup files")

        // Verify the newest backup files remain
        XCTAssertTrue(remainingBackupFiles.contains("history_backup_1.bak"))
        XCTAssertTrue(remainingBackupFiles.contains("history_backup_2.bak"))

        // Clean up test directory
        try fileManager.removeItem(at: backupDir)
    }
}
