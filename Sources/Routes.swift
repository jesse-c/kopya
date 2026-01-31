import AppKit
import Foundation
import Vapor

// MARK: - API Routes

func setupRoutes(_ app: Application, _ dbManager: DatabaseManager, _: ConfigManager) throws {
    registerHistoryRoute(app: app, dbManager: dbManager)
    registerSearchRoute(app: app, dbManager: dbManager)
    registerDeleteRoutes(app: app, dbManager: dbManager)
    registerPrivateModeRoutes(app: app)
}

// MARK: - Route Registration Helpers

/// Register GET /history endpoint
private func registerHistoryRoute(app: Application, dbManager: DatabaseManager) {
    // GET /history?range=1h&limit=100&offset=10
    // Note: offset parameter requires limit parameter for proper pagination semantics
    app.get("history") { req -> HistoryResponse in
        let limit = try? req.query.get(Int.self, at: "limit")
        let offset = try? req.query.get(Int.self, at: "offset")
        _ = try? req.query.get(String.self, at: "range")

        // Validate that offset is not provided without limit
        if offset != nil, limit == nil {
            throw Abort(.badRequest, reason: "The 'offset' parameter requires 'limit' parameter for proper pagination")
        }

        // Handle date range
        let (startDate, endDate) = parseDateRangeParams(req: req)

        let entries = try dbManager.getRecentEntries(
            limit: limit,
            offset: offset,
            startDate: startDate,
            endDate: endDate
        )

        // Get total count separately to ensure accurate count even with limit (and offset)
        let totalCount = try dbManager.getEntryCount()

        return HistoryResponse(entries: entries.map(ClipboardEntryResponse.init), total: totalCount)
    }
}

/// Register GET /search endpoint
private func registerSearchRoute(app: Application, dbManager: DatabaseManager) {
    // GET /search?type=url&query=example&range=1h
    app.get("search") { req -> HistoryResponse in
        let type = try? req.query.get(String.self, at: "type")
        let query = try? req.query.get(String.self, at: "query")
        let range = try? req.query.get(String.self, at: "range")
        let limit = try? req.query.get(Int.self, at: "limit")

        // Handle date range
        var startDate: Date?
        var endDate: Date?

        // Check for explicit start and end dates
        if let startDateStr = try? req.query.get(String.self, at: "startDate") {
            let formatter = ISO8601DateFormatter()
            startDate = formatter.date(from: startDateStr)
        }

        if let endDateStr = try? req.query.get(String.self, at: "endDate") {
            let formatter = ISO8601DateFormatter()
            endDate = formatter.date(from: endDateStr)
        }

        // If explicit dates aren't provided, try using the range parameter
        if let rangeStr = range, startDate == nil, endDate == nil {
            // Try relative format first
            if let dateRange = DateRange.parseRelative(rangeStr) {
                startDate = dateRange.start
                endDate = dateRange.end
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
}

/// Register DELETE /history and DELETE /history/:id endpoints
private func registerDeleteRoutes(app: Application, dbManager: DatabaseManager) {
    // DELETE /history?limit=100
    app.delete("history") { req -> Response in
        let limit = try? req.query.get(Int.self, at: "limit")
        let startDate = try? req.query.get(String.self, at: "start")
        let endDate = try? req.query.get(String.self, at: "end")
        let range = try? req.query.get(String.self, at: "range")
        let formatter = ISO8601DateFormatter()
        let (deletedCount, remainingCount) = try dbManager.deleteEntries(
            startDate: startDate.flatMap { formatter.date(from: $0) },
            endDate: endDate.flatMap { formatter.date(from: $0) }, range: range, limit: limit
        )
        let response = Response(status: .ok)
        try response.content.encode([
            "deletedCount": deletedCount,
            "remainingCount": remainingCount,
        ])
        return response
    }

    // DELETE /history/:id
    app.delete("history", ":id") { req -> Response in
        guard let idString = req.parameters.get("id"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid UUID format")
        }

        let success = try dbManager.deleteEntryById(id)
        let status: HTTPStatus = success ? .ok : .notFound
        let response = Response(status: status)

        let responseData = DeleteByIdResponse(
            success: success,
            id: idString,
            message: success ? "Entry deleted successfully" : "Entry not found"
        )

        try response.content.encode(responseData)

        return response
    }
}

/// Register private mode endpoints
private func registerPrivateModeRoutes(app: Application) {
    // POST /private/enable
    app.post("private", "enable") { req -> PrivateModeResponse in
        let range = try? req.query.get(String.self, at: "range")

        // Access the shared clipboard monitor instance
        guard let monitor = req.application.storage[ClipboardMonitorKey.self] else {
            throw Abort(.internalServerError, reason: "Clipboard monitor not available")
        }

        monitor.enablePrivateMode(timeRange: range)

        return PrivateModeResponse(
            success: true,
            message: "Private mode enabled" + (range != nil ? " for \(range!)" : "")
        )
    }

    // POST /private/disable
    app.post("private", "disable") { req -> PrivateModeResponse in
        // Access the shared clipboard monitor instance
        guard let monitor = req.application.storage[ClipboardMonitorKey.self] else {
            throw Abort(.internalServerError, reason: "Clipboard monitor not available")
        }

        monitor.disablePrivateMode()

        return PrivateModeResponse(
            success: true,
            message: "Private mode disabled"
        )
    }

    // GET /private/status
    app.get("private", "status") { req -> PrivateModeStatusResponse in
        // Access the shared clipboard monitor instance
        guard let monitor = req.application.storage[ClipboardMonitorKey.self] else {
            throw Abort(.internalServerError, reason: "Clipboard monitor not available")
        }

        let scheduledDisableTime = monitor.scheduledDisableTime
        let timerActive = scheduledDisableTime != nil

        // Calculate remaining time in a human-readable format if timer is active
        var remainingTimeString: String?
        if timerActive, let disableTime = scheduledDisableTime {
            let remainingSeconds = Int(disableTime.timeIntervalSinceNow)
            if remainingSeconds > 0 {
                let minutes = remainingSeconds / 60
                let seconds = remainingSeconds % 60
                if minutes > 0 {
                    remainingTimeString = "\(minutes)m \(seconds)s"
                } else {
                    remainingTimeString = "\(seconds)s"
                }
            } else {
                remainingTimeString = "0s (timer about to fire)"
            }
        }

        return PrivateModeStatusResponse(
            privateMode: !monitor.isMonitoring,
            timerActive: timerActive,
            scheduledDisableTime: scheduledDisableTime?.formatted(),
            remainingTime: remainingTimeString
        )
    }
}

// MARK: - Route Helper Functions

/// Parse date range parameters from request
private func parseDateRangeParams(req: Request) -> (startDate: Date?, endDate: Date?) {
    let range = try? req.query.get(String.self, at: "range")

    // Handle date range
    var startDate: Date?
    var endDate: Date?

    if let rangeStr = range, startDate == nil, endDate == nil {
        // Try relative format first
        if let dateRange = DateRange.parseRelative(rangeStr) {
            startDate = dateRange.start
            endDate = dateRange.end
        }
    }

    return (startDate, endDate)
}
