import AppKit
import ArgumentParser
import Foundation
import Logging
import ServiceManagement
import Vapor

let logger = Logger(label: "com.jesse-c.kopya")

// MARK: - Main

@main
struct Kopya: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A clipboard manager for macOS",
        version: Version.version
    )

    @ArgumentParser.Option(
        name: [.customShort("p"), .long], help: "Port to run the server on (overrides config value)"
    )
    var port: Int?

    @ArgumentParser.Option(
        name: [.customShort("m"), .long],
        help: "Maximum number of clipboard entries to store (overrides config value)"
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
            backupConfig: configManager.config.backup
        )

        // Create clipboard monitor
        let clipboardMonitor = try ClipboardMonitor(
            maxEntries: maxEntries,
            backupConfig: configManager.config.backup
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
