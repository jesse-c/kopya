// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import AppKit

// MARK: - Clipboard History
struct ClipboardEntry {
    let content: String
    let type: NSPasteboard.PasteboardType
    let timestamp: Date
    
    var isTextual: Bool {
        [.string, .URL, .fileURL, .rtf].contains(type)
    }
}

// MARK: - Clipboard Monitoring
@available(macOS 13.0, *)
class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var history: [ClipboardEntry] = []
    private var lastContent: String?
    private var lastChangeCount: Int = 0
    
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
    
    init() {
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
                   let clipboardString = getString(for: type, rawType: rawType),
                   clipboardString != lastContent {
                    lastContent = clipboardString
                    let entry = ClipboardEntry(
                        content: clipboardString,
                        type: type,
                        timestamp: Date()
                    )
                    history.append(entry)
                    print("\nStored new clipboard content:")
                    print("  Type: \(rawType)")
                    print("  Content: \(clipboardString)")
                    
                    // Print additional info for non-textual content
                    if !entry.isTextual {
                        print("  Size: \(clipboardString.count) bytes")
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

// Create a background thread for monitoring
Thread.detachNewThread {
    _ = ClipboardMonitor()
}

// Keep main thread running
RunLoop.main.run()
