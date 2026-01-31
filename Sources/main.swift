import AppKit
import ArgumentParser
import Foundation
import GRDB
import Logging
import ServiceManagement
import TOMLKit
import Vapor

let logger = Logger(label: "com.jesse-c.kopya")

// MARK: - API Models

struct HistoryResponse: Content {
    let entries: [ClipboardEntryResponse]
    let total: Int
}

struct ClipboardEntryResponse: Content {
    let id: UUID
    let content: String
    let type: String
    let humanReadableType: String?
    let timestamp: Date
    let isTextual: Bool

    init(from entry: ClipboardEntry) {
        id = entry.id ?? UUID()
        content = entry.content
        type = entry.type
        humanReadableType = entry.humanReadableType
        timestamp = entry.timestamp
        isTextual = entry.isTextual
    }
}

struct DeleteByIdResponse: Content {
    let success: Bool
    let id: String
    let message: String
}

struct PrivateModeResponse: Content {
    let success: Bool
    let message: String
}

struct PrivateModeStatusResponse: Content {
    let privateMode: Bool
    let timerActive: Bool
    let scheduledDisableTime: String?
    let remainingTime: String?
}

// MARK: - Clipboard History

struct ClipboardEntry: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clipboard_entries"

    var id: UUID?
    let content: String
    let type: String // Store as string since NSPasteboard.PasteboardType isn't Codable
    let timestamp: Date

    var isTextual: Bool {
        [
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.URL.rawValue,
            NSPasteboard.PasteboardType.fileURL.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue,
        ].contains(type)
    }

    var humanReadableType: String {
        switch type {
        case NSPasteboard.PasteboardType.string.rawValue:
            return "Text"
        case NSPasteboard.PasteboardType.URL.rawValue:
            return "URL"
        case NSPasteboard.PasteboardType.fileURL.rawValue:
            return "File URL"
        case NSPasteboard.PasteboardType.rtf.rawValue:
            return "RTF"
        case NSPasteboard.PasteboardType.pdf.rawValue:
            return "PDF"
        case NSPasteboard.PasteboardType.png.rawValue:
            return "PNG"
        case NSPasteboard.PasteboardType.tiff.rawValue:
            return "TIFF"
        default:
            // Extract the format from UTI if possible
            let components = type.components(separatedBy: ".")
            if components.count > 1, let lastComponent = components.last {
                return lastComponent.uppercased()
            }
            return type
        }
    }

    init(id: UUID? = nil, content: String, type: String, timestamp: Date) {
        self.id = id ?? UUID()
        self.content = content
        self.type = type
        self.timestamp = timestamp
    }

    /// Override database encoding to ensure proper UUID format
    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id?.uuidString
        container["content"] = content
        container["type"] = type
        container["timestamp"] = timestamp
    }

    /// Override database decoding to handle UUID format
    init(row: Row) throws {
        if let uuidString = row["id"] as String? {
            id = UUID(uuidString: uuidString)
        }
        content = row["content"]
        type = row["type"]
        timestamp = row["timestamp"]
    }
}

// MARK: - Database Management

class DatabaseManager: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let maxEntries: Int
    private let databasePath: String
    private var backupTimer: Timer?
    private let backupConfig: BackupConfig?

    init(databasePath: String? = nil, maxEntries: Int = 1000, backupConfig: BackupConfig? = nil) throws {
        let path = databasePath ?? "\(NSHomeDirectory())/Library/Application Support/Kopya/history.db"
        self.databasePath = path
        self.backupConfig = backupConfig

        // Ensure directory exists
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
        )

        dbQueue = try DatabaseQueue(path: path)
        self.maxEntries = maxEntries

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
                """,
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
                withIntermediateDirectories: true,
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

            logger.info("Database backup created at \(backupPath)")

            cleanupOldBackups(backupDir: backupDir, maxBackups: backupConfig?.count ?? 2)
        } catch {
            logger.error("Failed to create database backup: \(error.localizedDescription)")
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
                    logger.info("Deleted old backup: \(fileToDelete)")
                }
            }
        } catch {
            logger.error("Failed to clean up old backups: \(error.localizedDescription)")
        }
    }

    func saveEntry(_ entry: ClipboardEntry) throws -> Bool {
        try dbQueue.write { database in
            // Check if content already exists
            let existingCount =
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM clipboard_entries WHERE content = ?",
                    arguments: [entry.content],
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
                        arguments: [maxEntries],
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
                    arguments: [entry.timestamp, entry.content],
                )

                return false
            }
        }
    }

    func searchEntries(
        type: String? = nil,
        query: String? = nil,
        startDate: Date? = nil, endDate: Date? = nil,
        limit: Int? = nil, offset: Int? = nil,
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

    func deleteEntries(
        type: String? = nil,
        query: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        range: String? = nil,
        limit: Int? = nil,
    ) throws -> (
        deletedCount: Int, remainingCount: Int,
    ) {
        try dbQueue.write { database in
            let totalCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM clipboard_entries") ?? 0

            // Process range parameter if provided
            var effectiveStartDate = startDate
            var effectiveEndDate = endDate

            if let rangeStr = range, startDate == nil, endDate == nil {
                // For backward compatibility with tests, we need to handle range differently
                // in the delete operation compared to other operations
                if let dateRange = DateRange.parseRelative(rangeStr) {
                    // For delete operations with range, we want to delete entries from now back to the past
                    // This is the opposite of what parseRelative now does (which is from now forward)
                    let now = Date()
                    let timeInterval = dateRange.end.timeIntervalSince(dateRange.start)
                    effectiveStartDate = now.addingTimeInterval(-timeInterval)
                    effectiveEndDate = now
                }
            }

            // Build the SQL query based on the parameters
            var sql: String
            var arguments: [DatabaseValueConvertible] = []
            var conditions: [String] = []

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

            if let startDate = effectiveStartDate {
                conditions.append("timestamp >= ?")
                arguments.append(startDate)
            }

            if let endDate = effectiveEndDate {
                conditions.append("timestamp <= ?")
                arguments.append(endDate)
            }

            // Construct the WHERE clause for conditions
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

            if let limit {
                // If we have a limit, we need to use a subquery to get the IDs to delete
                if !conditions.isEmpty {
                    // With conditions and limit
                    sql = """
                    DELETE FROM clipboard_entries
                    WHERE id IN (
                        SELECT id FROM clipboard_entries
                        \(whereClause)
                        ORDER BY timestamp DESC
                        LIMIT ?
                    )
                    """
                    arguments.append(limit)
                } else {
                    // Just limit, no conditions
                    sql = """
                    DELETE FROM clipboard_entries
                    WHERE id IN (
                        SELECT id FROM clipboard_entries
                        ORDER BY timestamp DESC
                        LIMIT ?
                    )
                    """
                    arguments.append(limit)
                }
            } else if !conditions.isEmpty {
                // Only conditions, no limit
                sql = "DELETE FROM clipboard_entries \(whereClause)"
            } else {
                // No conditions at all, delete everything
                sql = "DELETE FROM clipboard_entries"
            }

            try database.execute(sql: sql, arguments: StatementArguments(arguments))

            let remainingCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM clipboard_entries") ?? 0
            return (totalCount - remainingCount, remainingCount)
        }
    }

    func deleteAllEntries() throws {
        try dbQueue.write { database in
            try database.execute(sql: "DELETE FROM clipboard_entries")
        }
    }

    func deleteEntryById(_ id: UUID) throws -> Bool {
        try dbQueue.write { database in
            // Check if the entry exists
            let exists =
                try ClipboardEntry
                    .filter(Column("id") == id.uuidString)
                    .fetchCount(database) > 0

            guard exists else {
                return false // Entry not found
            }

            // Delete the entry
            try ClipboardEntry
                .filter(Column("id") == id.uuidString)
                .deleteAll(database)

            return true // Entry deleted successfully
        }
    }
}

// MARK: - Configuration Management

struct BackupConfig: Codable {
    var interval: Int
    var count: Int
}

struct KopyaConfig: Codable {
    var runAtLogin: Bool
    var maxEntries: Int
    var port: Int
    var backup: BackupConfig?
    var filter: Bool
    var filters: [String]?
}

class ConfigManager {
    private let configFile: URL
    private(set) var config: KopyaConfig

    /// Cache for compiled regex patterns
    private var compiledFilterPatterns: [Regex<Substring>]

    /// Create a static logger for the ConfigManager class
    private static let logger = Logger(label: "com.jesse-c.kopya.config")

    init(configFile: URL? = nil) throws {
        // Use provided config file or default to user's home directory
        if let configFile {
            self.configFile = configFile
        } else {
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            self.configFile = homeDirectory.appendingPathComponent(".config/kopya/config.toml")
        }

        // Load config - will throw an error if file doesn't exist
        config = try Self.loadConfig(from: self.configFile)
        Self.logger.info("Loaded config from \(self.configFile.path)")

        // Compile filter patterns once at startup
        if config.filter, let patterns = config.filters, !patterns.isEmpty {
            compiledFilterPatterns = patterns.compactMap { pattern in
                do {
                    return try Regex(pattern)
                } catch {
                    Self.logger.error(
                        "Failed to parse filter pattern '\(pattern)' to Regex: \(error.localizedDescription)",
                    )
                    return nil
                }
            }
            Self.logger.notice("Compiled \(compiledFilterPatterns.count) filter patterns to Regex objects")
        } else {
            compiledFilterPatterns = []
        }
    }

    private static func loadConfig(from fileURL: URL) throws -> KopyaConfig {
        do {
            // Check if file exists
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                logger.error("Config file not found at \(fileURL.path)")
                throw NSError(
                    domain: "ConfigManager", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Config file not found at \(fileURL.path)"],
                )
            }

            // Read the file content
            let fileContent = try String(contentsOf: fileURL, encoding: .utf8)

            // Parse TOML
            let toml = try TOMLTable(string: fileContent)

            // Create a new table with keys that match our KopyaConfig struct properties
            let configTable = TOMLTable()

            // Extract and validate run-at-login
            if let runAtLoginValue = toml["run-at-login"] {
                configTable["runAtLogin"] = runAtLoginValue
            } else {
                Self.logger.error("Missing 'run-at-login' in config")
                throw NSError(
                    domain: "ConfigManager", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Missing 'run-at-login' in config"],
                )
            }

            // Extract and validate max-entries
            if let maxEntriesValue = toml["max-entries"] {
                configTable["maxEntries"] = maxEntriesValue
            } else {
                Self.logger.error("Missing 'max-entries' in config")
                throw NSError(
                    domain: "ConfigManager", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Missing 'max-entries' in config"],
                )
            }

            // Extract and validate port
            if let portValue = toml["port"] {
                configTable["port"] = portValue
            } else {
                Self.logger.error("Missing 'port' in config")
                throw NSError(
                    domain: "ConfigManager", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Missing 'port' in config"],
                )
            }

            // Extract and validate backup
            if let backupValue = toml["backup"] {
                // If backup is enabled, create a BackupConfig with interval and count
                if let backupEnabled = backupValue.bool, backupEnabled {
                    let backupTable = TOMLTable()

                    // Extract backup-interval (optional, defaults to 86400 seconds/24 hours)
                    if let backupIntervalValue = toml["backup-interval"] {
                        backupTable["interval"] = backupIntervalValue
                    } else {
                        backupTable["interval"] = TOMLValue(86400)
                        Self.logger.info("Missing 'backup-interval' in config, defaulting to 86400 seconds (24 hours).")
                    }

                    // Extract backup-count (optional, defaults to 2)
                    if let backupCountValue = toml["backup-count"] {
                        backupTable["count"] = backupCountValue
                    } else {
                        backupTable["count"] = TOMLValue(2)
                        Self.logger.info("Missing 'backup-count' in config, defaulting to 2.")
                    }

                    configTable["backup"] = backupTable
                }
                // If backup is disabled, don't add 'backup' field to the table at all
            } else {
                Self.logger.error("Missing 'backup' in config")
                throw NSError(
                    domain: "ConfigManager", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Missing 'backup' in config"],
                )
            }

            // Extract filter (optional, defaults to false)
            if let filterValue = toml["filter"] {
                configTable["filter"] = filterValue
            } else {
                // Default to false if missing
                configTable["filter"] = TOMLValue(false)
                Self.logger.info("Missing 'filter' in config, defaulting to false.")
            }

            // Extract filters
            if let filtersArray = toml["filters"] {
                configTable["filters"] = filtersArray
            } else if let filterEnabled = toml["filter"]?.bool, filterEnabled {
                // Empty array if filter is enabled but no patterns specified
                configTable["filters"] = TOMLValue([])
                Self.logger.info("Missing 'filters' in config, no patterns will be applied.")
            }

            // Decode the table to our KopyaConfig struct
            let decoder = TOMLDecoder()
            return try decoder.decode(KopyaConfig.self, from: configTable)

        } catch let error as TOMLParseError {
            Self.logger.error(
                "TOML Parse Error: Line \(error.source.begin.line), Column \(error.source.begin.column)",
            )
            throw NSError(
                domain: "ConfigManager", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to parse config: \(error.localizedDescription)",
                ],
            )
        } catch {
            Self.logger.error("Error loading config: \(error.localizedDescription)")
            throw error
        }
    }

    /// Parse string patterns into Swift Regex objects directly
    func getFilterRegexPatterns() -> [Regex<Substring>] {
        compiledFilterPatterns
    }

    /// Check if content should be filtered based on filter patterns
    func shouldFilter(_ content: String) -> Bool {
        // No patterns means no filtering
        guard !compiledFilterPatterns.isEmpty else {
            return false
        }

        // Check if content matches any of the filter patterns
        for pattern in compiledFilterPatterns where content.contains(pattern) {
            return true
        }

        return false
    }
}

// MARK: - Date Helpers

struct DateRange {
    let start: Date
    let end: Date

    static func parseRelative(_ input: String, relativeTo now: Date = Date()) -> DateRange? {
        // Handle combined time formats like "1h30m"
        if input.contains("h"), input.contains("m") {
            // Split by 'h' to get hours and minutes parts
            let parts = input.split(separator: "h")
            if parts.count == 2, let hours = Int(parts[0]), hours > 0 {
                // Get the minutes part (remove the 'm' at the end)
                let minutesPart = parts[1]
                if minutesPart.hasSuffix("m"), let minutes = Int(minutesPart.dropLast()) {
                    // Calculate total seconds
                    let totalSeconds = (hours * 3600) + (minutes * 60)

                    // For time ranges, we want to calculate forward from now to now + duration
                    let end = now.addingTimeInterval(Double(totalSeconds))

                    return DateRange(start: now, end: end)
                }
            }
            return nil
        }

        // Original implementation for single unit formats
        // Parse number and unit
        guard let number = Int(String(input.dropLast())),
              let unit = input.last else {
            return nil
        }

        guard number > 0 else {
            return nil
        }

        let calendar = Calendar.current
        var components = DateComponents()

        switch unit {
        case "s":
            components.second = number
        case "m":
            components.minute = number
        case "h":
            components.hour = number
        case "d":
            components.day = number
        default:
            return nil
        }

        guard let end = calendar.date(byAdding: components, to: now) else {
            return nil
        }

        return DateRange(start: now, end: end)
    }
}

// MARK: - API Routes

func setupRoutes(_ app: Application, _ dbManager: DatabaseManager, _: ConfigManager) throws {
    // GET /history?range=1h&limit=100&offset=10
    // Note: offset parameter requires limit parameter for proper pagination semantics
    app.get("history") { req -> HistoryResponse in
        let limit = try? req.query.get(Int.self, at: "limit")
        let offset = try? req.query.get(Int.self, at: "offset")
        let range = try? req.query.get(String.self, at: "range")

        // Validate that offset is not provided without limit
        if offset != nil, limit == nil {
            throw Abort(.badRequest, reason: "The 'offset' parameter requires 'limit' parameter for proper pagination")
        }

        // Handle date range
        var startDate: Date?
        var endDate: Date?

        if let rangeStr = range, startDate == nil, endDate == nil {
            // Try relative format first
            if let dateRange = DateRange.parseRelative(rangeStr) {
                startDate = dateRange.start
                endDate = dateRange.end
            }
        }

        let entries = try dbManager.getRecentEntries(
            limit: limit,
            offset: offset,
            startDate: startDate,
            endDate: endDate,
        )

        // Get total count separately to ensure accurate count even with limit (and offset)
        let totalCount = try dbManager.getEntryCount()

        return HistoryResponse(entries: entries.map(ClipboardEntryResponse.init), total: totalCount)
    }

    // GET /search?type=url&query=example&range=1h
    app.get("search") { req -> HistoryResponse in
        let type = try? req.query.get(String.self, at: "type")
        let query = try? req.query.get(String.self, at: "query")
        let range = try? req.query.get(String.self, at: "range")
        let limit = try? req.query.get(Int.self, at: "limit")

        // Handle date range
        var startDate: Date?
        var endDate: Date?

        // Check for explicit start and end dates
        if let startDateStr = try? req.query.get(String.self, at: "startDate") {
            let formatter = ISO8601DateFormatter()
            startDate = formatter.date(from: startDateStr)
        }

        if let endDateStr = try? req.query.get(String.self, at: "endDate") {
            let formatter = ISO8601DateFormatter()
            endDate = formatter.date(from: endDateStr)
        }

        // If explicit dates aren't provided, try using the range parameter
        if let rangeStr = range, startDate == nil, endDate == nil {
            // Try relative format first
            if let dateRange = DateRange.parseRelative(rangeStr) {
                startDate = dateRange.start
                endDate = dateRange.end
            }
        }

        let entries = try dbManager.searchEntries(
            type: type,
            query: query,
            startDate: startDate,
            endDate: endDate,
            limit: limit,
        )
        return HistoryResponse(entries: entries.map(ClipboardEntryResponse.init), total: entries.count)
    }

    // DELETE /history?limit=100
    app.delete("history") { req -> Response in
        let limit = try? req.query.get(Int.self, at: "limit")
        let startDate = try? req.query.get(String.self, at: "start")
        let endDate = try? req.query.get(String.self, at: "end")
        let range = try? req.query.get(String.self, at: "range")
        let formatter = ISO8601DateFormatter()
        let (deletedCount, remainingCount) = try dbManager.deleteEntries(
            startDate: startDate.flatMap { formatter.date(from: $0) },
            endDate: endDate.flatMap { formatter.date(from: $0) }, range: range, limit: limit,
        )
        let response = Response(status: .ok)
        try response.content.encode([
            "deletedCount": deletedCount,
            "remainingCount": remainingCount,
        ])
        return response
    }

    // DELETE /history/:id
    app.delete("history", ":id") { req -> Response in
        guard let idString = req.parameters.get("id"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid UUID format")
        }

        let success = try dbManager.deleteEntryById(id)
        let status: HTTPStatus = success ? .ok : .notFound
        let response = Response(status: status)

        let responseData = DeleteByIdResponse(
            success: success,
            id: idString,
            message: success ? "Entry deleted successfully" : "Entry not found",
        )

        try response.content.encode(responseData)

        return response
    }

    // Private mode endpoints
    app.post("private", "enable") { req -> PrivateModeResponse in
        let range = try? req.query.get(String.self, at: "range")

        // Access the shared clipboard monitor instance
        guard let monitor = req.application.storage[ClipboardMonitorKey.self] else {
            throw Abort(.internalServerError, reason: "Clipboard monitor not available")
        }

        monitor.enablePrivateMode(timeRange: range)

        return PrivateModeResponse(
            success: true,
            message: "Private mode enabled" + (range != nil ? " for \(range!)" : ""),
        )
    }

    app.post("private", "disable") { req -> PrivateModeResponse in
        // Access the shared clipboard monitor instance
        guard let monitor = req.application.storage[ClipboardMonitorKey.self] else {
            throw Abort(.internalServerError, reason: "Clipboard monitor not available")
        }

        monitor.disablePrivateMode()

        return PrivateModeResponse(
            success: true,
            message: "Private mode disabled",
        )
    }

    app.get("private", "status") { req -> PrivateModeStatusResponse in
        // Access the shared clipboard monitor instance
        guard let monitor = req.application.storage[ClipboardMonitorKey.self] else {
            throw Abort(.internalServerError, reason: "Clipboard monitor not available")
        }

        let scheduledDisableTime = monitor.scheduledDisableTime
        let timerActive = scheduledDisableTime != nil

        // Calculate remaining time in a human-readable format if timer is active
        var remainingTimeString: String?
        if timerActive, let disableTime = scheduledDisableTime {
            let remainingSeconds = Int(disableTime.timeIntervalSinceNow)
            if remainingSeconds > 0 {
                let minutes = remainingSeconds / 60
                let seconds = remainingSeconds % 60
                if minutes > 0 {
                    remainingTimeString = "\(minutes)m \(seconds)s"
                } else {
                    remainingTimeString = "\(seconds)s"
                }
            } else {
                remainingTimeString = "0s (timer about to fire)"
            }
        }

        return PrivateModeStatusResponse(
            privateMode: !monitor.isMonitoring,
            timerActive: timerActive,
            scheduledDisableTime: scheduledDisableTime?.formatted(),
            remainingTime: remainingTimeString,
        )
    }
}

/// Storage key for the clipboard monitor
struct ClipboardMonitorKey: StorageKey {
    typealias Value = ClipboardMonitor
}

// MARK: - Clipboard Monitoring

@available(macOS 13.0, *)
class ClipboardMonitor: @unchecked Sendable {
    private let pasteboard = NSPasteboard.general
    private var lastContent: String?
    private var lastChangeCount: Int
    private let dbManager: DatabaseManager
    private(set) var isMonitoring: Bool = true
    private(set) var scheduledDisableTime: Date?
    private var privateModeCancellable: DispatchWorkItem?

    /// Types in order of priority
    private let monitoredTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.URL, "public.url"),
        (.fileURL, "public.file-url"),
        (.rtf, "public.rtf"), // Prioritize RTF over plain text
        (.string, "public.utf8-plain-text"),
        (.pdf, "com.adobe.pdf"),
        (.png, "public.png"),
        (.tiff, "public.tiff"),
    ]

    init(maxEntries: Int = 1000, backupConfig: BackupConfig? = nil) throws {
        dbManager = try DatabaseManager(maxEntries: maxEntries, backupConfig: backupConfig)
        lastChangeCount = NSPasteboard.general.changeCount
        isMonitoring = true

        // Print initial stats without processing current clipboard content
        let entryCount = try dbManager.getEntryCount()
        logger.notice("Database initialized with \(entryCount) entries")
        logger.notice("Maximum entries set to: \(maxEntries)")
    }

    func enablePrivateMode(timeRange: String? = nil) {
        // Cancel any existing timer
        privateModeCancellable?.cancel()
        privateModeCancellable = nil
        scheduledDisableTime = nil

        // Enable private mode
        isMonitoring = false
        logger.notice("Private mode enabled - clipboard monitoring disabled")

        // If a time range is provided, schedule automatic disable
        if let rangeStr = timeRange, let dateRange = DateRange.parseRelative(rangeStr) {
            let timeInterval = dateRange.end.timeIntervalSince(dateRange.start)

            // Store the scheduled disable time
            scheduledDisableTime = Date().addingTimeInterval(timeInterval)

            logger.notice(
                "Private mode will automatically disable after \(rangeStr) at \(scheduledDisableTime!.formatted())",
            )

            // Create a cancellable work item for disabling private mode
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }

                logger.notice("Private mode timer fired - clipboard monitoring resumed")
                disablePrivateMode()
            }

            // Store the work item so it can be cancelled if needed
            privateModeCancellable = workItem

            // Schedule the work item to run after the specified time interval
            DispatchQueue.global().asyncAfter(deadline: .now() + timeInterval, execute: workItem)
        }
    }

    func disablePrivateMode() {
        // Cancel any existing timer
        privateModeCancellable?.cancel()
        privateModeCancellable = nil
        scheduledDisableTime = nil

        // Disable private mode
        isMonitoring = true
        logger.notice("Private mode disabled - clipboard monitoring resumed")
    }

    func startMonitoring(configManager: ConfigManager) {
        // Start polling the pasteboard
        while true {
            autoreleasepool {
                let currentChangeCount = pasteboard.changeCount
                guard currentChangeCount != lastChangeCount else {
                    Thread.sleep(forTimeInterval: 0.5)
                    return
                }

                lastChangeCount = currentChangeCount

                // Skip processing if in private mode
                guard isMonitoring else {
                    Thread.sleep(forTimeInterval: 0.5)
                    return
                }

                guard let types = pasteboard.types else { return }
                logger.notice("Detected clipboard change!")
                logger.notice("Available types: \(types.map(\.rawValue))")

                // Find the highest priority type that's available
                let availableType = monitoredTypes.first { type in
                    types.contains(NSPasteboard.PasteboardType(type.1))
                }

                if let (type, rawType) = availableType,
                   let clipboardString = getString(for: type, rawType: rawType) {
                    // Only process if content has actually changed
                    if clipboardString != lastContent {
                        lastContent = clipboardString

                        // Check if content should be filtered based on regex patterns
                        if configManager.config.filter,
                           configManager.shouldFilter(clipboardString) {
                            logger.notice("Content matched filter pattern")
                            return
                        }

                        let entry = ClipboardEntry(
                            id: nil,
                            content: clipboardString,
                            type: type.rawValue,
                            timestamp: Date(),
                        )

                        do {
                            let saved = try dbManager.saveEntry(entry)
                            let entryCount = try dbManager.getEntryCount()

                            if saved {
                                logger.notice("Stored new clipboard content: \(entry.humanReadableType)")
                            } else {
                                logger.notice("Updated existing clipboard content: \(entry.humanReadableType)")
                            }
                            logger.notice("Content: \(clipboardString)")

                            // Print additional info for non-textual content
                            if !entry.isTextual {
                                logger.notice("Size: \(clipboardString.count) bytes")
                            }

                            logger.notice("Current entries in database: \(entryCount)")
                        } catch {
                            logger.error("Error saving clipboard entry: \(error)")
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private func getString(for type: NSPasteboard.PasteboardType, rawType: String) -> String? {
        let rawPBType = NSPasteboard.PasteboardType(rawType)

        switch type {
        case .string:
            return pasteboard.string(forType: rawPBType)
        case .fileURL:
            if let urls = pasteboard.propertyList(forType: rawPBType) as? [String] {
                return urls.joined(separator: "\n")
            }
            return pasteboard.propertyList(forType: rawPBType) as? String
        case .URL:
            // First try to get the URL directly
            if let urlString = pasteboard.propertyList(forType: rawPBType) as? String {
                return urlString
            }
            // Then try string type for URLs
            if let text = pasteboard.string(forType: .string),
               text.lowercased().hasPrefix("http") {
                return text
            }
            return nil
        case .rtf:
            // First try to get RTF as plain text
            if let string = pasteboard.string(forType: rawPBType) {
                return string
            }
            // If that fails, show the RTF data size
            if let data = pasteboard.data(forType: rawPBType) {
                return "<rtf content: \(data.count) bytes>"
            }
            return "<rtf data>"
        case .pdf, .png, .tiff:
            if let data = pasteboard.data(forType: rawPBType) {
                return "<\(rawType) data: \(data.count) bytes>"
            }
            return "<\(rawType) data>"
        default:
            return "<\(rawType) data>"
        }
    }
}

// MARK: - Main

@main
struct Kopya: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A clipboard manager for macOS",
        version: Version.version,
    )

    @ArgumentParser.Option(
        name: [.customShort("p"), .long], help: "Port to run the server on (overrides config value)",
    )
    var port: Int?

    @ArgumentParser.Option(
        name: [.customShort("m"), .long],
        help: "Maximum number of clipboard entries to store (overrides config value)",
    )
    var maxEntries: Int?

    mutating func run() async throws {
        logger.notice("Starting Kopya clipboard manager...")

        // Load configuration
        let configManager: ConfigManager
        do {
            configManager = try ConfigManager()
        } catch {
            logger.error("Failed to load configuration: \(error.localizedDescription)")
            logger.error("Make sure the config file exists at ~/.config/kopya/config.toml")
            Foundation.exit(1)
        }

        // Use CLI arguments to override config values if provided
        let port = port ?? configManager.config.port
        let maxEntries = maxEntries ?? configManager.config.maxEntries

        // Apply run at login setting from config
        try syncRunAtLoginWithConfig(configManager.config.runAtLogin)

        // Create a signal source for handling interrupts
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            logger.notice("Received termination signal (SIGINT). Shutting down...")
            Foundation.exit(0)
        }
        sigintSource.resume()

        // Create a signal source for handling termination
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            logger.notice("Received termination signal (SIGTERM). Shutting down...")
            Foundation.exit(0)
        }
        sigtermSource.resume()

        // Ignore the signals at the process level so the dispatch sources can handle them
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        // Create database manager
        let dbManager = try DatabaseManager(
            maxEntries: maxEntries,
            backupConfig: configManager.config.backup,
        )

        // Create clipboard monitor
        let clipboardMonitor = try ClipboardMonitor(
            maxEntries: maxEntries,
            backupConfig: configManager.config.backup,
        )

        // Configure and start Vapor server
        var env = try Environment.detect()
        env.commandInput.arguments = []

        let app = try await Application.make(env)

        app.http.server.configuration.port = port
        app.http.server.configuration.serverName = "kopya"
        app.http.server.configuration.backlog = 256
        app.http.server.configuration.reuseAddress = false

        // Store the clipboard monitor in the application storage for access in routes
        app.storage[ClipboardMonitorKey.self] = clipboardMonitor

        try setupRoutes(app, dbManager, configManager)

        // Start the Vapor server in a background task
        Task {
            try await app.execute()
        }

        // Start monitoring clipboard in the main thread
        clipboardMonitor.startMonitoring(configManager: configManager)
    }

    /// Function to sync run-at-login setting with config
    private func syncRunAtLoginWithConfig(_ enabled: Bool) throws {
        // Check current status
        let currentStatus = SMAppService.mainApp.status
        let isCurrentlyEnabled = currentStatus == .enabled

        // Only make changes if necessary
        if enabled, !isCurrentlyEnabled {
            logger.notice("Config specifies run at login: enabling...")
            try SMAppService.mainApp.register()
            logger.notice("Successfully enabled run at login")
        } else if !enabled, isCurrentlyEnabled {
            logger.notice("Config specifies no run at login: disabling...")
            try SMAppService.mainApp.unregister()
            logger.notice("Successfully disabled run at login")
        } else {
            logger.debug("Run at login already set to \(enabled), no change needed")
        }
    }
}
