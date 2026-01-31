import AppKit
import Foundation
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
