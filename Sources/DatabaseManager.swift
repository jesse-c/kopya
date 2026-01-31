import Foundation
import GRDB
import Logging

// MARK: - Database Management

class DatabaseManager: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let maxEntries: Int
    private let databasePath: String
    private var backupTimer: Timer?
    private let backupConfig: BackupConfig?
    private let deleter: DatabaseDeleter

    /// Create a static logger for the DatabaseManager class
    private static let logger = Logger(label: "com.jesse-c.kopya.database")

    init(databasePath: String? = nil, maxEntries: Int = 1000, backupConfig: BackupConfig? = nil) throws {
        let path = databasePath ?? "\(NSHomeDirectory())/Library/Application Support/Kopya/history.db"
        self.databasePath = path
        self.backupConfig = backupConfig

        // Ensure directory exists
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        dbQueue = try DatabaseQueue(path: path)
        self.maxEntries = maxEntries
        deleter = DatabaseDeleter(dbQueue: dbQueue)

        // Initialize database schema
        try dbQueue.write { database in
            try database.create(table: "clipboard_entries", ifNotExists: true) { table in
                table.column("id", .text).primaryKey().notNull() // UUID stored as text
                table.column("content", .text).notNull()
                table.column("type", .text).notNull()
                table.column("timestamp", .datetime).notNull()
                table.uniqueKey(["content"]) // Ensure content is unique
            }
        }

        // Clean up duplicate entries on startup
        try dbQueue.write { database in
            try database.execute(
                sql: """
                DELETE FROM clipboard_entries
                WHERE id NOT IN (
                    SELECT MAX(id)
                    FROM clipboard_entries
                    GROUP BY content
                )
                """
            )
        }

        // Setup backup timer if enabled
        if backupConfig != nil {
            setupBackupTimer()
        }
    }

    deinit {
        backupTimer?.invalidate()
    }

    private func setupBackupTimer() {
        // Schedule backups using the configured interval
        let interval = TimeInterval(backupConfig?.interval ?? 86400)
        backupTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.performBackup()
        }

        // Run an initial backup
        performBackup()
    }

    private func performBackup() {
        do {
            let backupDir = (databasePath as NSString).deletingLastPathComponent + "/backups"

            // Ensure backup directory exists
            try FileManager.default.createDirectory(
                atPath: backupDir,
                withIntermediateDirectories: true
            )

            // Create a timestamp for the backup file
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())

            // Create backup file path
            let backupFilename = (databasePath as NSString).lastPathComponent
            let backupPath = "\(backupDir)/\(backupFilename)_\(timestamp).bak"

            // Copy the database file
            try dbQueue.backup(to: DatabaseQueue(path: backupPath))

            Self.logger.info("Database backup created at \(backupPath)")

            cleanupOldBackups(backupDir: backupDir, maxBackups: backupConfig?.count ?? 2)
        } catch {
            Self.logger.error("Failed to create database backup: \(error.localizedDescription)")
        }
    }

    func cleanupOldBackups(backupDir: String, maxBackups: Int) {
        do {
            let fileManager = FileManager.default
            let backupFiles = try fileManager.contentsOfDirectory(atPath: backupDir)
                .filter { $0.hasSuffix(".bak") }
                .map { (name: $0, path: "\(backupDir)/\($0)") }
                .sorted {
                    let attr1 = try fileManager.attributesOfItem(atPath: $0.path)
                    let attr2 = try fileManager.attributesOfItem(atPath: $1.path)
                    let date1 = attr1[.creationDate] as? Date ?? Date.distantPast
                    let date2 = attr2[.creationDate] as? Date ?? Date.distantPast
                    return date1 < date2
                }
                .map(\.name)

            if backupFiles.count > maxBackups {
                // Delete oldest backups
                for index in 0 ..< (backupFiles.count - maxBackups) {
                    let fileToDelete = "\(backupDir)/\(backupFiles[index])"
                    try fileManager.removeItem(atPath: fileToDelete)
                    Self.logger.info("Deleted old backup: \(fileToDelete)")
                }
            }
        } catch {
            Self.logger.error("Failed to clean up old backups: \(error.localizedDescription)")
        }
    }

    func saveEntry(_ entry: ClipboardEntry) throws -> Bool {
        try dbQueue.write { database in
            // Check if content already exists
            let existingCount =
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM clipboard_entries WHERE content = ?",
                    arguments: [entry.content]
                ) ?? 0

            if existingCount == 0 {
                // Insert new entry
                var entry = entry
                if entry.id == nil {
                    entry.id = UUID()
                }
                try entry.insert(database)

                // Clean up old entries if we exceed the limit
                let totalCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM clipboard_entries") ?? 0
                if totalCount > maxEntries {
                    try database.execute(
                        sql: """
                        DELETE FROM clipboard_entries
                        WHERE id NOT IN (
                            SELECT id FROM clipboard_entries
                            ORDER BY timestamp DESC
                            LIMIT ?
                        )
                        """,
                        arguments: [maxEntries]
                    )
                }

                return true
            } else {
                // Update timestamp of existing entry to mark it as most recent
                try database.execute(
                    sql: """
                    UPDATE clipboard_entries
                    SET timestamp = ?
                    WHERE content = ?
                    """,
                    arguments: [entry.timestamp, entry.content]
                )

                return false
            }
        }
    }

    func searchEntries(
        type: String? = nil,
        query: String? = nil,
        startDate: Date? = nil, endDate: Date? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) throws -> [ClipboardEntry] {
        try dbQueue.read { database in
            var sql = "SELECT * FROM clipboard_entries"
            var conditions: [String] = []
            var arguments: [DatabaseValueConvertible] = []

            if let type {
                // Handle common type aliases
                let typeCondition: String
                switch type.lowercased() {
                case "url":
                    typeCondition = "type LIKE '%url%'"
                case "text", "textual":
                    typeCondition = "type LIKE '%text%' OR type LIKE '%rtf%'"
                default:
                    typeCondition = "type = ?"
                    arguments.append(type)
                }
                conditions.append(typeCondition)
            }

            if let query {
                conditions.append("content LIKE ?")
                arguments.append("%\(query)%")
            }

            if let startDate {
                conditions.append("timestamp >= ?")
                arguments.append(startDate)
            }

            if let endDate {
                conditions.append("timestamp <= ?")
                arguments.append(endDate)
            }

            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }

            sql += " ORDER BY timestamp DESC"

            if let limit {
                sql += " LIMIT ?"
                arguments.append(limit)

                if let offset {
                    sql += " OFFSET ?"
                    arguments.append(offset)
                }
            }
            // Note: offset without limit is ignored for proper pagination semantics

            return try ClipboardEntry.fetchAll(database, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    func getRecentEntries(limit: Int? = nil, offset: Int? = nil, startDate: Date? = nil, endDate: Date? = nil) throws
        -> [ClipboardEntry] {
        try searchEntries(startDate: startDate, endDate: endDate, limit: limit, offset: offset)
    }

    func getEntryCount() throws -> Int {
        try dbQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM clipboard_entries") ?? 0
        }
    }

    // MARK: - Delete Operations

    /// Delete entries matching the specified criteria
    func deleteEntries(
        type: String? = nil,
        query: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        range: String? = nil,
        limit: Int? = nil
    ) throws -> (deletedCount: Int, remainingCount: Int) {
        try deleter.deleteEntries(
            type: type,
            query: query,
            startDate: startDate,
            endDate: endDate,
            range: range,
            limit: limit
        )
    }

    /// Delete all entries from the database
    func deleteAllEntries() throws {
        try deleter.deleteAllEntries()
    }

    /// Delete a specific entry by its UUID
    func deleteEntryById(_ id: UUID) throws -> Bool {
        try deleter.deleteEntryById(id)
    }
}
