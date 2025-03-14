import Foundation
import AppKit
import GRDB
import Vapor

// MARK: - API Models
struct HistoryResponse: Content {
    let entries: [ClipboardEntryResponse]
    let total: Int
}

struct ClipboardEntryResponse: Content {
    let id: UUID
    let content: String
    let type: String
    let timestamp: Date
    let isTextual: Bool
    
    init(from entry: ClipboardEntry) {
        self.id = entry.id ?? UUID()
        self.content = entry.content
        self.type = entry.type
        self.timestamp = entry.timestamp
        self.isTextual = entry.isTextual
    }
}

// MARK: - Clipboard History
struct ClipboardEntry: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clipboard_entries"
    
    var id: UUID?
    let content: String
    let type: String  // Store as string since NSPasteboard.PasteboardType isn't Codable
    let timestamp: Date
    
    var isTextual: Bool {
        [
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.URL.rawValue,
            NSPasteboard.PasteboardType.fileURL.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue
        ].contains(type)
    }
    
    init(id: UUID? = nil, content: String, type: String, timestamp: Date) {
        self.id = id ?? UUID()
        self.content = content
        self.type = type
        self.timestamp = timestamp
    }
    
    // Override database encoding to ensure proper UUID format
    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id?.uuidString
        container["content"] = content
        container["type"] = type
        container["timestamp"] = timestamp
    }
    
    // Override database decoding to handle UUID format
    init(row: Row) throws {
        if let uuidString = row["id"] as String? {
            self.id = UUID(uuidString: uuidString)
        }
        self.content = row["content"]
        self.type = row["type"]
        self.timestamp = row["timestamp"]
    }
}

// MARK: - Database Management
class DatabaseManager: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let maxEntries: Int
    
    init(databasePath: String? = nil, maxEntries: Int = 1000) throws {
        let path = databasePath ?? "\(NSHomeDirectory())/Library/Application Support/Kopya/history.db"
        
        // Ensure directory exists
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        
        self.dbQueue = try DatabaseQueue(path: path)
        self.maxEntries = maxEntries
        
        // Initialize database schema
        try dbQueue.write { db in
            try db.create(table: "clipboard_entries", ifNotExists: true) { t in
                t.column("id", .text).primaryKey().notNull()  // UUID stored as text
                t.column("content", .text).notNull()
                t.column("type", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.uniqueKey(["content"])  // Ensure content is unique
            }
        }
        
        // Clean up duplicate entries on startup
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM clipboard_entries
                WHERE id NOT IN (
                    SELECT MAX(id)
                    FROM clipboard_entries
                    GROUP BY content
                )
                """)
        }
    }
    
    func saveEntry(_ entry: ClipboardEntry) throws -> Bool {
        try dbQueue.write { db in
            // Check if content already exists
            let existingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_entries WHERE content = ?", arguments: [entry.content]) ?? 0
            
            if existingCount == 0 {
                // Insert new entry
                var entry = entry
                if entry.id == nil {
                    entry.id = UUID()
                }
                try entry.insert(db)
                
                // Clean up old entries if we exceed the limit
                let totalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_entries") ?? 0
                if totalCount > maxEntries {
                    try db.execute(sql: """
                        DELETE FROM clipboard_entries
                        WHERE id NOT IN (
                            SELECT id FROM clipboard_entries
                            ORDER BY timestamp DESC
                            LIMIT ?
                        )
                        """,
                        arguments: [maxEntries])
                }
                
                return true
            } else {
                // Update timestamp of existing entry to mark it as most recent
                try db.execute(sql: """
                    UPDATE clipboard_entries
                    SET timestamp = ?
                    WHERE content = ?
                    """,
                    arguments: [entry.timestamp, entry.content])
                
                return false
            }
        }
    }
    
    func searchEntries(type: String? = nil, query: String? = nil, startDate: Date? = nil, endDate: Date? = nil, limit: Int? = nil) throws -> [ClipboardEntry] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM clipboard_entries"
            var conditions: [String] = []
            var arguments: [DatabaseValueConvertible] = []
            
            if let type = type {
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
            
            if let query = query {
                conditions.append("content LIKE ?")
                arguments.append("%\(query)%")
            }
            
            if let startDate = startDate {
                conditions.append("timestamp >= ?")
                arguments.append(startDate)
            }
            
            if let endDate = endDate {
                conditions.append("timestamp <= ?")
                arguments.append(endDate)
            }
            
            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            
            sql += " ORDER BY timestamp DESC"
            
            if let limit = limit {
                sql += " LIMIT ?"
                arguments.append(limit)
            }
            
            return try ClipboardEntry.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }
    
    func getRecentEntries(limit: Int? = nil, startDate: Date? = nil, endDate: Date? = nil) throws -> [ClipboardEntry] {
        try searchEntries(startDate: startDate, endDate: endDate, limit: limit)
    }
    
    func getEntryCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_entries") ?? 0
        }
    }
    
    func deleteAllEntries() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clipboard_entries")
        }
    }
    
    func deleteEntries(limit: Int? = nil) throws -> (deletedCount: Int, remainingCount: Int) {
        try dbQueue.write { db in
            let totalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_entries") ?? 0
            
            if let limit = limit {
                try db.execute(sql: """
                    DELETE FROM clipboard_entries
                    WHERE id IN (
                        SELECT id
                        FROM clipboard_entries
                        ORDER BY timestamp DESC
                        LIMIT ?
                    )
                    """,
                    arguments: [limit])
            } else {
                try db.execute(sql: "DELETE FROM clipboard_entries")
            }
            
            let remainingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_entries") ?? 0
            return (totalCount - remainingCount, remainingCount)
        }
    }
}

// MARK: - Date Helpers
struct DateRange {
    let start: Date
    let end: Date
    
    static func parseRelative(_ input: String, relativeTo now: Date = Date()) -> DateRange? {
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
        case "m":
            components.minute = -number
        case "h":
            components.hour = -number
        case "d":
            components.day = -number
        default:
            return nil
        }
        
        guard let start = calendar.date(byAdding: components, to: now) else {
            return nil
        }
        
        return DateRange(start: start, end: now)
    }
}

// MARK: - API Routes
func setupRoutes(_ app: Application, _ dbManager: DatabaseManager) throws {
    // GET /history?range=1h&limit=100
    app.get("history") { req -> HistoryResponse in
        let limit = try? req.query.get(Int.self, at: "limit")
        let range = try? req.query.get(String.self, at: "range")
        
        // Handle date range
        var startDate: Date?
        var endDate: Date?
        
        if let rangeStr = range {
            // Try relative format first
            if let dateRange = DateRange.parseRelative(rangeStr) {
                startDate = dateRange.start
                endDate = dateRange.end
            } else {
                // Try explicit ISO8601 dates
                let formatter = ISO8601DateFormatter()
                startDate = (try? req.query.get(String.self, at: "start")).flatMap { formatter.date(from: $0) }
                endDate = (try? req.query.get(String.self, at: "end")).flatMap { formatter.date(from: $0) }
            }
        }
        
        let entries = try dbManager.getRecentEntries(
            limit: limit,
            startDate: startDate,
            endDate: endDate
        )
        return HistoryResponse(entries: entries.map(ClipboardEntryResponse.init), total: entries.count)
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
        
        if let rangeStr = range {
            // Try relative format first
            if let dateRange = DateRange.parseRelative(rangeStr) {
                startDate = dateRange.start
                endDate = dateRange.end
            } else {
                // Try explicit ISO8601 dates
                let formatter = ISO8601DateFormatter()
                startDate = (try? req.query.get(String.self, at: "start")).flatMap { formatter.date(from: $0) }
                endDate = (try? req.query.get(String.self, at: "end")).flatMap { formatter.date(from: $0) }
            }
        }
        
        let entries = try dbManager.searchEntries(
            type: type,
            query: query,
            startDate: startDate,
            endDate: endDate,
            limit: limit
        )
        return HistoryResponse(entries: entries.map(ClipboardEntryResponse.init), total: entries.count)
    }
    
    // DELETE /history?limit=100
    app.delete("history") { req -> Response in
        let limit = try? req.query.get(Int.self, at: "limit")
        let (deletedCount, remainingCount) = try dbManager.deleteEntries(limit: limit)
        let response = Response(status: .ok)
        try response.content.encode([
            "deletedCount": deletedCount,
            "remainingCount": remainingCount
        ])
        return response
    }
}

// MARK: - Clipboard Monitoring
@available(macOS 13.0, *)
class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var lastContent: String?
    private var lastChangeCount: Int
    private let dbManager: DatabaseManager
    
    // Types in order of priority
    private let monitoredTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.URL, "public.url"),
        (.fileURL, "public.file-url"),
        (.rtf, "public.rtf"),        // Prioritize RTF over plain text
        (.string, "public.utf8-plain-text"),
        (.pdf, "com.adobe.pdf"),
        (.png, "public.png"),
        (.tiff, "public.tiff")
    ]
    
    init(maxEntries: Int = 1000) throws {
        self.dbManager = try DatabaseManager(maxEntries: maxEntries)
        self.lastChangeCount = NSPasteboard.general.changeCount
        
        // Print initial stats without processing current clipboard content
        let entryCount = try dbManager.getEntryCount()
        print("Database initialized with \(entryCount) entries")
        print("Maximum entries set to: \(maxEntries)")
    }
    
    func startMonitoring() {
        // Start polling the pasteboard
        while true {
            autoreleasepool {
                let currentChangeCount = pasteboard.changeCount
                guard currentChangeCount != lastChangeCount else {
                    Thread.sleep(forTimeInterval: 0.5)
                    return
                }
                
                lastChangeCount = currentChangeCount
                
                guard let types = pasteboard.types else { return }
                print("\nDetected clipboard change!")
                print("Available types:", types.map { $0.rawValue })
                
                // Find the highest priority type that's available
                let availableType = monitoredTypes.first { type in
                    types.contains(NSPasteboard.PasteboardType(type.1))
                }
                
                if let (type, rawType) = availableType,
                   let clipboardString = getString(for: type, rawType: rawType) {
                    // Only process if content has actually changed
                    if clipboardString != lastContent {
                        lastContent = clipboardString
                        let entry = ClipboardEntry(
                            id: nil,
                            content: clipboardString,
                            type: type.rawValue,
                            timestamp: Date()
                        )
                        
                        do {
                            let saved = try dbManager.saveEntry(entry)
                            let entryCount = try dbManager.getEntryCount()
                            
                            if saved {
                                print("\nStored new clipboard content:")
                            } else {
                                print("\nUpdated existing clipboard content:")
                            }
                            print("  Type: \(rawType)")
                            print("  Content: \(clipboardString)")
                            
                            // Print additional info for non-textual content
                            if !entry.isTextual {
                                print("  Size: \(clipboardString.count) bytes")
                            }
                            
                            print("  Current entries in database: \(entryCount)")
                        } catch {
                            print("Error saving clipboard entry:", error)
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
struct Kopya {
    static func main() async throws {
        print("Starting Kopya clipboard manager...")
        
        let maxEntries = 1000
        let dbManager = try DatabaseManager(maxEntries: maxEntries)
        
        // Configure and start Vapor server
        let app = try await Application.make(.detect())
        try setupRoutes(app, dbManager)
        
        // Start clipboard monitoring in a background task
        Task.detached {
            try await app.execute()
        }
        
        // Start monitoring clipboard in the main thread
        try ClipboardMonitor(maxEntries: maxEntries).startMonitoring()
    }
}
