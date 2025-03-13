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
    let id: Int64
    let content: String
    let type: String
    let timestamp: Date
    let isTextual: Bool
    
    init(from entry: ClipboardEntry) {
        self.id = entry.id ?? 0
        self.content = entry.content
        self.type = entry.type
        self.timestamp = entry.timestamp
        self.isTextual = entry.isTextual
    }
}

// MARK: - Clipboard History
struct ClipboardEntry: Codable, FetchableRecord, PersistableRecord {
    let id: Int64?
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
}

// MARK: - Database Management
class DatabaseManager: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let maxEntries: Int
    
    init(maxEntries: Int = 1000) throws {
        self.maxEntries = maxEntries
        
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: true)
        let dbPath = appSupport.appendingPathComponent("Kopya").appendingPathComponent("clipboard.sqlite")
        
        // Create directory if needed
        try fileManager.createDirectory(at: dbPath.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
        
        dbQueue = try DatabaseQueue(path: dbPath.path)
        
        // Setup database schema
        try migrator.migrate(dbQueue)
        
        // Initial cleanup of any duplicates from previous runs
        try cleanupDuplicates()
    }
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("createClipboardEntries") { db in
            try db.create(table: "clipboardEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("content", .text).notNull()
                t.column("type", .text).notNull()
                t.column("timestamp", .datetime).notNull()
            }
            
            // Create index for timestamp column
            try db.create(index: "clipboardEntry_timestamp_idx",
                         on: "clipboardEntry",
                         columns: ["timestamp"])
            
            // Create index for content for faster duplicate checking
            try db.create(index: "clipboardEntry_content_idx",
                         on: "clipboardEntry",
                         columns: ["content"])
        }
        
        return migrator
    }
    
    private func cleanupDuplicates() throws {
        try dbQueue.write { db in
            // Delete all but the most recent entry for each unique content
            try db.execute(sql: """
                DELETE FROM clipboardEntry
                WHERE id NOT IN (
                    SELECT MAX(id)
                    FROM clipboardEntry
                    GROUP BY content
                )
            """)
            
            // Ensure we're within maxEntries limit
            let count = try ClipboardEntry.fetchCount(db)
            if count > maxEntries {
                let deleteCount = count - maxEntries
                try ClipboardEntry
                    .order(Column("timestamp"))
                    .limit(deleteCount)
                    .deleteAll(db)
                print("Cleaned up \(deleteCount) old entries during initialization")
            }
        }
    }
    
    func saveEntry(_ entry: ClipboardEntry) throws -> Bool {
        try dbQueue.write { db in
            // Check if this exact content already exists
            let exists = try ClipboardEntry
                .filter(Column("content") == entry.content)
                .fetchCount(db) > 0
            
            // Only insert if it's not a duplicate
            if !exists {
                // Insert new entry
                try entry.insert(db)
                
                // Get count of entries
                let count = try ClipboardEntry.fetchCount(db)
                
                // If we exceed maxEntries, delete oldest entries
                if count > maxEntries {
                    let deleteCount = count - maxEntries
                    try ClipboardEntry
                        .order(Column("timestamp"))
                        .limit(deleteCount)
                        .deleteAll(db)
                    
                    print("Cleaned up \(deleteCount) old entries")
                }
                return true
            } else {
                // Update timestamp of existing entry to mark it as most recent
                try db.execute(sql: """
                    UPDATE clipboardEntry
                    SET timestamp = ?
                    WHERE content = ?
                    """,
                    arguments: [entry.timestamp, entry.content])
                return false
            }
        }
    }
    
    func getRecentEntries(limit: Int? = nil) throws -> [ClipboardEntry] {
        try dbQueue.read { db in
            var query = ClipboardEntry.order(Column("timestamp").desc)
            if let limit = limit {
                query = query.limit(limit)
            }
            return try query.fetchAll(db)
        }
    }
    
    func deleteEntries(limit: Int? = nil) throws -> Int {
        try dbQueue.write { db in
            if let limit = limit {
                // Delete the oldest entries
                return try ClipboardEntry
                    .order(Column("timestamp"))
                    .limit(limit)
                    .deleteAll(db)
            } else {
                // Delete all entries
                return try ClipboardEntry.deleteAll(db)
            }
        }
    }
    
    func getEntryCount() throws -> Int {
        try dbQueue.read { db in
            try ClipboardEntry.fetchCount(db)
        }
    }
}

// MARK: - API Routes
func setupRoutes(_ app: Application, _ dbManager: DatabaseManager) throws {
    // GET /history?limit=100
    app.get("history") { req -> HistoryResponse in
        let limit = try? req.query.get(Int.self, at: "limit")
        let entries = try dbManager.getRecentEntries(limit: limit)
        return HistoryResponse(
            entries: entries.map(ClipboardEntryResponse.init),
            total: try dbManager.getEntryCount()
        )
    }
    
    // DELETE /history?limit=100
    app.delete("history") { req -> Response in
        let limit = try? req.query.get(Int.self, at: "limit")
        let deletedCount = try dbManager.deleteEntries(limit: limit)
        let remainingCount = try dbManager.getEntryCount()
        
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
        
        startMonitoring()
    }
    
    private func startMonitoring() {
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
                            let isNewEntry = try dbManager.saveEntry(entry)
                            let entryCount = try dbManager.getEntryCount()
                            
                            if isNewEntry {
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
print("Starting Kopya clipboard manager...")

// Create a shared database manager
let dbManager = try DatabaseManager(maxEntries: 1000)

// Configure and start Vapor server
let app = try Application(.detect())
try setupRoutes(app, dbManager)

// Start the web server in a background thread
Thread.detachNewThread {
    do {
        try app.run()
    } catch {
        print("Error starting web server:", error)
        exit(1)
    }
}

// Create a background thread for clipboard monitoring
Thread.detachNewThread {
    do {
        _ = try ClipboardMonitor(maxEntries: 1000)
    } catch {
        print("Error initializing ClipboardMonitor:", error)
        exit(1)
    }
}

// Keep main thread running
RunLoop.main.run()
