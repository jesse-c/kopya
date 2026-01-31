import AppKit
import Foundation
import Logging
import Vapor

// MARK: - Storage Key

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
                "Private mode will automatically disable after \(rangeStr) at \(scheduledDisableTime!.formatted())"
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
                            timestamp: Date()
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

    // MARK: - GetString Helper Methods

    private func getString(for type: NSPasteboard.PasteboardType, rawType: String) -> String? {
        let rawPBType = NSPasteboard.PasteboardType(rawType)

        switch type {
        case .string:
            return getStringValue(for: rawPBType)
        case .fileURL:
            return getFileURLValue(for: rawPBType)
        case .URL:
            return getURLValue(for: rawPBType)
        case .rtf:
            return getRTFValue(for: rawPBType)
        case .pdf, .png, .tiff:
            return getBinaryDataValue(for: rawPBType, rawType: rawType)
        default:
            return "<\(rawType) data>"
        }
    }

    /// Get string value for .string type
    private func getStringValue(for rawPBType: NSPasteboard.PasteboardType) -> String? {
        pasteboard.string(forType: rawPBType)
    }

    /// Get file URL value for .fileURL type
    private func getFileURLValue(for rawPBType: NSPasteboard.PasteboardType) -> String? {
        if let urls = pasteboard.propertyList(forType: rawPBType) as? [String] {
            return urls.joined(separator: "\n")
        }
        return pasteboard.propertyList(forType: rawPBType) as? String
    }

    /// Get URL value for .URL type
    private func getURLValue(for rawPBType: NSPasteboard.PasteboardType) -> String? {
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
    }

    /// Get RTF value for .rtf type
    private func getRTFValue(for rawPBType: NSPasteboard.PasteboardType) -> String? {
        // First try to get RTF as plain text
        if let string = pasteboard.string(forType: rawPBType) {
            return string
        }
        // If that fails, show the RTF data size
        if let data = pasteboard.data(forType: rawPBType) {
            return "<rtf content: \(data.count) bytes>"
        }
        return "<rtf data>"
    }

    /// Get binary data value for .pdf, .png, .tiff types
    private func getBinaryDataValue(for rawPBType: NSPasteboard.PasteboardType, rawType: String) -> String? {
        if let data = pasteboard.data(forType: rawPBType) {
            return "<\(rawType) data: \(data.count) bytes>"
        }
        return "<\(rawType) data>"
    }
}
