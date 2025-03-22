//
//  KopyaApp.swift
//  Kopya
//
//  Created by Jesse Claven on 22/03/2025.
//

import SwiftUI
import AppKit
import OSLog
import ServiceManagement
import Foundation

// Logger for the app
let logger = Logger(subsystem: "com.jesse-c.kopya", category: "App")

// Helper function to get the app version
func getAppVersion() -> String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    return "Version \(version) (\(build))"
}

// Add some test logs that will appear immediately when this file is loaded
private func logTestMessages() {
    logger.debug("TEST DEBUG: Kopya app is initializing")
    logger.info("TEST INFO: Kopya logger is working")
    logger.error("TEST ERROR: This is a test error message - no actual error")
}

// Execute test logging immediately
class LogInitializer {
    static let shared = LogInitializer()
    
    init() {
        logTestMessages()
    }
}

private let _logInitializer = LogInitializer.shared

// MARK: - Clipboard Entry
struct ClipboardEntry: Identifiable, Codable, Equatable {
    var id: UUID
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
    
    init(id: UUID = UUID(), content: String, type: String, timestamp: Date = Date()) {
        self.id = id
        self.content = content
        self.type = type
        self.timestamp = timestamp
    }
    
    static func == (lhs: ClipboardEntry, rhs: ClipboardEntry) -> Bool {
        return lhs.content == rhs.content
    }
}

// MARK: - Clipboard History Manager
class ClipboardHistoryManager: ObservableObject {
    @Published var entries: [ClipboardEntry] = []
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    var timer: Timer?
    
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
        self.lastChangeCount = NSPasteboard.general.changeCount
        
        // Load saved entries if available
        if let savedEntries = loadEntries() {
            self.entries = savedEntries
            logger.info("Loaded \(savedEntries.count) clipboard entries from storage")
        }
        
        // Start monitoring if preference is enabled
        if UserDefaults.standard.bool(forKey: "startMonitoringAtLaunch") {
            startMonitoring()
        }
    }
    
    func startMonitoring() {
        logger.info("Starting clipboard monitoring")
        
        // Check for clipboard changes every 0.5 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForClipboardChanges()
        }
    }
    
    func stopMonitoring() {
        logger.info("Stopping clipboard monitoring")
        timer?.invalidate()
        timer = nil
    }
    
    public func isMonitoringActive() -> Bool {
        return timer != nil
    }
    
    private func checkForClipboardChanges() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        
        lastChangeCount = currentChangeCount
        
        guard let types = pasteboard.types else { return }
        logger.debug("Detected clipboard change with types: \(types.map { $0.rawValue })")
        
        // Find the highest priority type that's available
        let availableType = monitoredTypes.first { type in
            types.contains(NSPasteboard.PasteboardType(type.1))
        }
        
        if let (type, rawType) = availableType,
           let clipboardString = getString(for: type, rawType: rawType) {
            
            // Create a new entry
            let newEntry = ClipboardEntry(
                content: clipboardString,
                type: type.rawValue
            )
            
            // Only add if it's not already in the list (comparing by content)
            if !entries.contains(where: { $0.content == newEntry.content }) {
                logger.info("Adding new clipboard entry of type: \(newEntry.humanReadableType)")
                
                // Add to the beginning of the array
                DispatchQueue.main.async {
                    self.addEntry(newEntry)
                }
            } else {
                // If it's already in the list, move it to the top
                if let index = entries.firstIndex(where: { $0.content == newEntry.content }) {
                    DispatchQueue.main.async {
                        let existingEntry = self.entries.remove(at: index)
                        self.addEntry(existingEntry)
                    }
                }
            }
        }
    }
    
    private func addEntry(_ entry: ClipboardEntry) {
        // Check if entry already exists to avoid duplicates
        if !entries.contains(where: { $0 == entry }) {
            entries.insert(entry, at: 0)
            saveEntries()
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
    
    // MARK: - Persistence
    
    private func saveEntries() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self.entries)
            
            // Get the application support directory
            if let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                // Create a directory for our app if it doesn't exist
                let appDir = appSupportDir.appendingPathComponent("com.jesse-c.kopya")
                
                if !FileManager.default.fileExists(atPath: appDir.path) {
                    try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
                }
                
                // Save the entries to a file
                let fileURL = appDir.appendingPathComponent("clipboard_history.json")
                try data.write(to: fileURL)
                
                logger.debug("Saved \(self.entries.count) clipboard entries to storage")
            }
        } catch {
            logger.error("Failed to save clipboard entries: \(error.localizedDescription)")
        }
    }
    
    private func loadEntries() -> [ClipboardEntry]? {
        do {
            // Get the application support directory
            if let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                // Get the directory for our app
                let appDir = appSupportDir.appendingPathComponent("com.jesse-c.kopya")
                let fileURL = appDir.appendingPathComponent("clipboard_history.json")
                
                // Check if the file exists
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let data = try Data(contentsOf: fileURL)
                    let entries = try JSONDecoder().decode([ClipboardEntry].self, from: data)
                    return entries
                }
            }
        } catch {
            logger.error("Failed to load clipboard entries: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    // MARK: - Actions
    
    func clearHistory() {
        entries.removeAll()
        saveEntries()
        logger.info("Cleared clipboard history")
    }
    
    func copyToClipboard(_ entry: ClipboardEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        
        // Handle different types differently
        if entry.type == NSPasteboard.PasteboardType.string.rawValue {
            pb.setString(entry.content, forType: .string)
            logger.info("Copied text to clipboard: \(entry.content.prefix(30))...")
        } else if entry.type == NSPasteboard.PasteboardType.URL.rawValue {
            pb.setString(entry.content, forType: .URL)
            logger.info("Copied URL to clipboard: \(entry.content)")
        } else if entry.type == NSPasteboard.PasteboardType.fileURL.rawValue {
            pb.setString(entry.content, forType: .fileURL)
            logger.info("Copied file URL to clipboard: \(entry.content)")
        } else {
            // For other types, just try to copy as string
            pb.setString(entry.content, forType: .string)
            logger.info("Copied content as string: \(entry.content.prefix(30))...")
        }
    }
    
    func deleteEntry(_ entry: ClipboardEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries.remove(at: index)
            saveEntries()
            logger.info("Deleted clipboard entry: \(entry.content.prefix(30))...")
        }
    }
}

// Class to handle hiding the main window
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusBarController: StatusBarController?
    @AppStorage("hideDockIcon") private var hideDockIcon = true
    @AppStorage("launchAtLogin") private var isLaunchAtLoginEnabled = false
    @AppStorage("startMonitoringAtLaunch") private var startMonitoringAtLaunch = true
    private var clipboardManager: ClipboardHistoryManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.debug("Application did finish launching")
        
        // Set the activation policy based on user preference
        updateDockIconVisibility()
        
        // Check launch at login status
        checkLaunchAtLoginStatus()
        
        // Initialize clipboard manager
        clipboardManager = ClipboardHistoryManager()
        
        // Start monitoring if enabled
        if startMonitoringAtLaunch {
            clipboardManager?.startMonitoring()
        }
        
        // Create the status bar controller
        statusBarController = StatusBarController(
            openPreferences: {
                NotificationCenter.default.post(name: Notification.Name("OpenPreferencesWindow"), object: nil)
            },
            clipboardManager: clipboardManager!
        )
        
        // Set up to intercept window creation
        NSApp.windows.forEach { window in
            window.delegate = self
        }
        
        // Set up notification for window creation
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowCreation(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        
        // Add About menu item
        setupApplicationMenu()
        
        logger.debug("App initialization complete")
    }
    
    private func updateDockIconVisibility() {
        // Set activation policy based on preference
        let activationPolicy: NSApplication.ActivationPolicy = self.hideDockIcon ? .accessory : .regular
        NSApp.setActivationPolicy(activationPolicy)
        logger.debug("Set activation policy to \(self.hideDockIcon ? "accessory (dock icon hidden)" : "regular (dock icon visible)")")
    }
    
    private func checkLaunchAtLoginStatus() {
        // Check if the app is registered to launch at login
        let status = SMAppService.mainApp.status
        let isRegistered = status == .enabled
        if isRegistered != self.isLaunchAtLoginEnabled {
            // Sync the app storage value with the actual status
            self.isLaunchAtLoginEnabled = isRegistered
            logger.debug("Updated launch at login preference to match system status: \(isRegistered)")
        }
    }
    
    @objc func handleWindowCreation(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            // Only hide non-preferences windows
            if window.title != "Preferences" && window.title != "About Kopya" {
                // Hide the window
                window.alphaValue = 0
                window.isOpaque = false
                window.hasShadow = false
                
                // Close the window after a short delay
                DispatchQueue.main.async {
                    window.close()
                }
                
                logger.debug("Intercepted and closed window: \(window.title)")
            }
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        logger.debug("Window will close: \(String(describing: (notification.object as? NSWindow)?.title))")
    }
    
    @objc func openPreferencesFromKeyboard() {
        logger.debug("Opening preferences window via keyboard shortcut")
        NotificationCenter.default.post(name: Notification.Name("OpenPreferencesWindow"), object: nil)
    }
    
    private func setupApplicationMenu() {
        if let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu {
            // Create the About menu item
            let aboutMenuItem = NSMenuItem(
                title: "About Kopya",
                action: #selector(handleAboutMenuItem),
                keyEquivalent: ""
            )
            aboutMenuItem.target = self
            
            // Insert at the beginning of the menu
            appMenu.insertItem(aboutMenuItem, at: 0)
            
            // Add a separator after the About item
            appMenu.insertItem(NSMenuItem.separator(), at: 1)
            
            logger.debug("Added About menu item to application menu")
        }
    }
    
    @objc private func handleAboutMenuItem() {
        logger.debug("About menu item selected")
        NotificationCenter.default.post(name: Notification.Name("OpenAboutWindow"), object: nil)
    }
}

// Class to manage the status bar menu
class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var clipboardManager: ClipboardHistoryManager
    
    init(openPreferences: @escaping () -> Void, clipboardManager: ClipboardHistoryManager) {
        self.clipboardManager = clipboardManager
        super.init()
        setupStatusBar()
    }
    
    private func setupStatusBar() {
        // Create the status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Set the icon
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Kopya")
        }
        
        // Create the menu
        updateMenu()
        
        logger.debug("Status bar icon initialized")
    }
    
    func updateMenu() {
        let menu = NSMenu()
        
        // Monitoring toggle
        let monitoringItem = NSMenuItem(
            title: "Monitoring Clipboard",
            action: #selector(toggleMonitoring(_:)),
            keyEquivalent: ""
        )
        monitoringItem.state = clipboardManager.isMonitoringActive() ? .on : .off
        menu.addItem(monitoringItem)
        
        // Clear history
        menu.addItem(NSMenuItem(
            title: "Clear History",
            action: #selector(clearHistory(_:)),
            keyEquivalent: ""
        ))
        
        menu.addItem(NSMenuItem.separator())
        
        // Preferences
        menu.addItem(NSMenuItem(
            title: "Preferences...",
            action: #selector(openPreferences(_:)),
            keyEquivalent: ","
        ))
        
        // About
        menu.addItem(NSMenuItem(
            title: "About Kopya",
            action: #selector(openAbout(_:)),
            keyEquivalent: ""
        ))
        
        menu.addItem(NSMenuItem.separator())
        
        // Version info
        let versionItem = NSMenuItem(title: getAppVersion(), action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        ))
        
        statusItem?.menu = menu
    }
    
    // MARK: - Menu Actions
    
    @objc private func toggleMonitoring(_ sender: NSMenuItem) {
        if clipboardManager.isMonitoringActive() {
            clipboardManager.stopMonitoring()
        } else {
            clipboardManager.startMonitoring()
        }
        updateMenu()
    }
    
    @objc private func clearHistory(_ sender: NSMenuItem) {
        clipboardManager.clearHistory()
        updateMenu()
    }
    
    @objc private func openPreferences(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: Notification.Name("OpenPreferencesWindow"), object: nil)
    }
    
    @objc private func openAbout(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: Notification.Name("OpenAboutWindow"), object: nil)
    }
    
    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
}

// Class to handle opening the preferences window
class PreferencesWindowManager: ObservableObject {
    static let shared = PreferencesWindowManager()
    
    @Published var shouldOpenPreferences = false
    
    init() {
        // Listen for notifications to open preferences window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenPreferences),
            name: Notification.Name("OpenPreferencesWindow"),
            object: nil
        )
    }
    
    @objc private func handleOpenPreferences() {
        logger.debug("PreferencesWindowManager received notification to open preferences")
        shouldOpenPreferences = true
    }
}

// Class to handle opening the about window
class AboutWindowManager: ObservableObject {
    static let shared = AboutWindowManager()
    
    @Published var shouldOpenAbout = false
    
    init() {
        // Listen for notifications to open about window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenAbout),
            name: Notification.Name("OpenAboutWindow"),
            object: nil
        )
    }
    
    @objc private func handleOpenAbout() {
        logger.debug("AboutWindowManager received notification to open about window")
        shouldOpenAbout = true
    }
}

// About window view
struct AboutWindowView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.on.clipboard")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .foregroundColor(.blue)
            
            Text("Kopya")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text(getAppVersion())
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding()
        .frame(width: 300, height: 200)
    }
}

@main
struct KopyaApp: App {
    @AppStorage("launchAtLogin") private var isLaunchAtLoginEnabled = false
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var preferencesManager = PreferencesWindowManager.shared
    @StateObject private var aboutManager = AboutWindowManager.shared
    
    init() {
        logger.debug("KopyaApp initializing")
    }
    
    var body: some Scene {
        // Empty scene that won't create a visible window
        EmptyScene()
        
        // About window as a separate scene
        WindowGroup("About Kopya", id: "about") {
            AboutWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 300, height: 200)
        .onChange(of: aboutManager.shouldOpenAbout) { oldValue, newValue in
            if newValue {
                openWindow(id: "about")
                // Reset the flag after a short delay to avoid state update during view update
                DispatchQueue.main.async {
                    aboutManager.shouldOpenAbout = false
                }
            }
        }
        
        // Preferences window as a separate scene
        WindowGroup("Preferences", id: "preferences") {
            PreferencesView()
        }
        .defaultSize(width: 450, height: 250)
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
        .commands {
            // Add keyboard shortcuts
            CommandGroup(after: .appSettings) {
                Button("Preferences...") {
                    openWindow(id: "preferences")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .onChange(of: preferencesManager.shouldOpenPreferences) { oldValue, newValue in
            if newValue {
                openWindow(id: "preferences")
                // Reset the flag after a short delay to avoid state update during view update
                DispatchQueue.main.async {
                    preferencesManager.shouldOpenPreferences = false
                }
            }
        }
    }
}

// A completely empty scene to replace the default window
struct EmptyScene: Scene {
    var body: some Scene {
        WindowGroup(id: "empty") {
            EmptyView()
        }
    }
}

// Preferences window implementation
struct PreferencesView: View {
    @AppStorage("launchAtLogin") private var isLaunchAtLoginEnabled = false
    @AppStorage("hideDockIcon") private var hideDockIcon = true
    @AppStorage("startMonitoringAtLaunch") private var startMonitoringAtLaunch = true
    @State private var needsRestart = false
    @State private var selectedTab = "general"
    
    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralPreferencesView(
                isLaunchAtLoginEnabled: $isLaunchAtLoginEnabled,
                hideDockIcon: $hideDockIcon,
                startMonitoringAtLaunch: $startMonitoringAtLaunch,
                needsRestart: $needsRestart
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }
            .tag("general")
            
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag("about")
        }
        .frame(width: 450, height: 250)
        .onAppear {
            logger.debug("PreferencesView appeared")
            // Reset the restart flag when preferences are opened
            needsRestart = false
        }
    }
}

// General preferences tab
struct GeneralPreferencesView: View {
    @Binding var isLaunchAtLoginEnabled: Bool
    @Binding var hideDockIcon: Bool
    @Binding var startMonitoringAtLaunch: Bool
    @Binding var needsRestart: Bool
    
    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $isLaunchAtLoginEnabled)
                    .onChange(of: isLaunchAtLoginEnabled) { oldValue, newValue in
                        toggleLaunchAtLogin(enabled: newValue)
                    }
                
                Toggle("Hide dock icon", isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { oldValue, newValue in
                        needsRestart = true
                    }
                
                if needsRestart {
                    Text("Restart required for this change to take effect")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } header: {
                Text("General")
            }
            
            Section {
                Toggle("Start monitoring at launch", isOn: $startMonitoringAtLaunch)
            } header: {
                Text("Clipboard")
            }
        }
        .padding()
    }
    
    private func toggleLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                logger.info("Enabling launch at login")
                try SMAppService.mainApp.register()
                logger.info("Successfully enabled launch at login")
            } else {
                logger.info("Disabling launch at login")
                try SMAppService.mainApp.unregister()
                logger.info("Successfully disabled launch at login")
            }
        } catch {
            logger.error("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)")
        }
    }
}

// About view showing app name and version
struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.on.clipboard")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .foregroundColor(.blue)
            
            Text("Kopya")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text(getAppVersion())
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
