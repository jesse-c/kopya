import Foundation
import GRDB
import Logging

// MARK: - Database Delete Operations Helper

/// Helper struct for building SQL delete conditions
enum DeleteConditionBuilder {
    /// Build SQL conditions for delete queries
    static func buildConditions(
        type: String?,
        query: String?,
        startDate: Date?,
        endDate: Date?,
        arguments: inout [DatabaseValueConvertible]
    ) -> [String] {
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

        if let startDate {
            conditions.append("timestamp >= ?")
            arguments.append(startDate)
        }

        if let endDate {
            conditions.append("timestamp <= ?")
            arguments.append(endDate)
        }

        return conditions
    }

    /// Process date range parameter for delete operations
    static func processDateRange(
        range: String?,
        startDate: Date?,
        endDate: Date?
    ) -> (startDate: Date?, endDate: Date?) {
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

        return (effectiveStartDate, effectiveEndDate)
    }
}

/// Helper class for performing delete operations on clipboard entries
class DatabaseDeleter {
    private static let logger = Logger(label: "com.jesse-c.kopya.database.deleter")

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Delete entries matching the specified criteria
    func deleteEntries(
        type: String? = nil,
        query: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        range: String? = nil,
        limit: Int? = nil
    ) throws -> (deletedCount: Int, remainingCount: Int) {
        try dbQueue.write { database in
            let totalCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM clipboard_entries") ?? 0

            // Process range parameter if provided
            let (effectiveStartDate, effectiveEndDate) = DeleteConditionBuilder.processDateRange(
                range: range,
                startDate: startDate,
                endDate: endDate
            )

            // Build the SQL query based on the parameters
            var sql: String
            var arguments: [DatabaseValueConvertible] = []
            let conditions = DeleteConditionBuilder.buildConditions(
                type: type,
                query: query,
                startDate: effectiveStartDate,
                endDate: effectiveEndDate,
                arguments: &arguments
            )

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

    /// Delete all entries from the database
    func deleteAllEntries() throws {
        try dbQueue.write { database in
            try database.execute(sql: "DELETE FROM clipboard_entries")
        }
    }

    /// Delete a specific entry by its UUID
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
