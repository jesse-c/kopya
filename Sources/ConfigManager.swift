import Foundation
import Logging
import TOMLKit

// MARK: - Configuration Management

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
                        "Failed to parse filter pattern '\(pattern)' to Regex: \(error.localizedDescription)"
                    )
                    return nil
                }
            }
            Self.logger.notice("Compiled \(compiledFilterPatterns.count) filter patterns to Regex objects")
        } else {
            compiledFilterPatterns = []
        }
    }

    // MARK: - Config Loading Helper Methods

    /// Validate and extract a boolean value from a TOML table
    private static func validateAndExtractBool(table: TOMLTable, key: String, required: Bool = true) throws -> Bool? {
        if let value = table[key] {
            guard let boolValue = value.bool else {
                throw NSError(
                    domain: "ConfigManager",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Expected boolean for '\(key)'"]
                )
            }
            return boolValue
        } else if required {
            throw NSError(
                domain: "ConfigManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Missing '\(key)' in config"]
            )
        }
        return nil
    }

    /// Validate and extract an integer value from a TOML table
    private static func validateAndExtractInt(table: TOMLTable, key: String, required: Bool = true) throws -> Int? {
        if let value = table[key] {
            // Try to get integer value - TOMLValue needs to be accessed differently
            if let intValue = value.int {
                return intValue
            }
            throw NSError(
                domain: "ConfigManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Expected integer for '\(key)'"]
            )
        } else if required {
            throw NSError(
                domain: "ConfigManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Missing '\(key)' in config"]
            )
        }
        return nil
    }

    /// Validate and extract a string value from a TOML table
    private static func validateAndExtractString(
        table: TOMLTable,
        key: String,
        required: Bool = true
    ) throws -> String? {
        if let value = table[key] {
            guard let stringValue = value.string else {
                throw NSError(
                    domain: "ConfigManager",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Expected string for '\(key)'"]
                )
            }
            return stringValue
        } else if required {
            throw NSError(
                domain: "ConfigManager",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Missing '\(key)' in config"]
            )
        }
        return nil
    }

    /// Validate and extract a string array from a TOML table
    private static func validateAndExtractStringArray(table: TOMLTable, key: String) throws -> [String]? {
        guard let value = table[key] else { return nil }

        guard let array = value.array else {
            throw NSError(
                domain: "ConfigManager",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Expected array for '\(key)'"]
            )
        }

        let strings = array.compactMap { $0.string }
        if strings.count != array.count {
            throw NSError(
                domain: "ConfigManager",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "All items in '\(key)' must be strings"]
            )
        }
        return strings
    }

    /// Extract backup configuration from TOML table
    private static func extractBackupConfig(from toml: TOMLTable, configTable: inout TOMLTable) throws {
        guard let backupValue = toml["backup"] else {
            throw NSError(
                domain: "ConfigManager", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Missing 'backup' in config"]
            )
        }

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
    }

    private static func loadConfig(from fileURL: URL) throws -> KopyaConfig {
        do {
            // Check if file exists
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                logger.error("Config file not found at \(fileURL.path)")
                throw NSError(
                    domain: "ConfigManager", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Config file not found at \(fileURL.path)"]
                )
            }

            // Read the file content
            let fileContent = try String(contentsOf: fileURL, encoding: .utf8)

            // Parse TOML
            let toml = try TOMLTable(string: fileContent)

            // Create a new table with keys that match our KopyaConfig struct properties
            var configTable = TOMLTable()

            // Extract and validate run-at-login
            if let runAtLoginValue = toml["run-at-login"] {
                configTable["runAtLogin"] = runAtLoginValue
            } else {
                Self.logger.error("Missing 'run-at-login' in config")
                throw NSError(
                    domain: "ConfigManager", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Missing 'run-at-login' in config"]
                )
            }

            // Extract and validate max-entries
            if let maxEntriesValue = toml["max-entries"] {
                configTable["maxEntries"] = maxEntriesValue
            } else {
                Self.logger.error("Missing 'max-entries' in config")
                throw NSError(
                    domain: "ConfigManager", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Missing 'max-entries' in config"]
                )
            }

            // Extract and validate port
            if let portValue = toml["port"] {
                configTable["port"] = portValue
            } else {
                Self.logger.error("Missing 'port' in config")
                throw NSError(
                    domain: "ConfigManager", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Missing 'port' in config"]
                )
            }

            // Extract and validate backup
            try extractBackupConfig(from: toml, configTable: &configTable)

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
                "TOML Parse Error: Line \(error.source.begin.line), Column \(error.source.begin.column)"
            )
            throw NSError(
                domain: "ConfigManager", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to parse config: \(error.localizedDescription)",
                ]
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
