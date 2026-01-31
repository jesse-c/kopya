import Foundation

// MARK: - Database Configuration Structs

/// Configuration for database backups
struct BackupConfig: Codable {
    var interval: Int
    var count: Int
}

/// Configuration for Kopya application
struct KopyaConfig: Codable {
    var runAtLogin: Bool
    var maxEntries: Int
    var port: Int
    var backup: BackupConfig?
    var filter: Bool
    var filters: [String]?
}
