import XCTest
@testable import Kopya

final class DateRangeTests: XCTestCase {
    let referenceDate = ISO8601DateFormatter().date(from: "2025-03-13T12:00:00Z")!
    
    func testMinutesFormat() throws {
        // Test valid minutes format
        let range = DateRange.parseRelative("5m", relativeTo: referenceDate)
        XCTAssertNotNil(range)
        
        if let range = range {
            let calendar = Calendar.current
            let diff = calendar.dateComponents([.minute], from: range.start, to: range.end)
            XCTAssertEqual(diff.minute, 5)
            XCTAssertEqual(range.start, referenceDate)
        }
    }
    
    func testHoursFormat() throws {
        // Test valid hours format
        let range = DateRange.parseRelative("2h", relativeTo: referenceDate)
        XCTAssertNotNil(range)
        
        if let range = range {
            let calendar = Calendar.current
            let diff = calendar.dateComponents([.hour], from: range.start, to: range.end)
            XCTAssertEqual(diff.hour, 2)
            XCTAssertEqual(range.start, referenceDate)
        }
    }
    
    func testDaysFormat() throws {
        // Test valid days format
        let range = DateRange.parseRelative("3d", relativeTo: referenceDate)
        XCTAssertNotNil(range)
        
        if let range = range {
            let calendar = Calendar.current
            let diff = calendar.dateComponents([.day], from: range.start, to: range.end)
            XCTAssertEqual(diff.day, 3)
            XCTAssertEqual(range.start, referenceDate)
        }
    }
    
    func testInvalidFormats() throws {
        // Test invalid formats
        XCTAssertNil(DateRange.parseRelative(""))
        XCTAssertNil(DateRange.parseRelative("5"))
        XCTAssertNil(DateRange.parseRelative("m5"))
        XCTAssertNil(DateRange.parseRelative("5x"))
        XCTAssertNil(DateRange.parseRelative("5 m"))
        XCTAssertNil(DateRange.parseRelative("-5m"))
        XCTAssertNil(DateRange.parseRelative("5minutes"))
    }
    
    func testZeroValues() throws {
        // Test zero values
        XCTAssertNil(DateRange.parseRelative("0m"))
        XCTAssertNil(DateRange.parseRelative("0h"))
        XCTAssertNil(DateRange.parseRelative("0d"))
    }
    
    func testLargeValues() throws {
        // Test large values
        let range = DateRange.parseRelative("1000m", relativeTo: referenceDate)
        XCTAssertNotNil(range)
        
        if let range = range {
            let calendar = Calendar.current
            let diff = calendar.dateComponents([.minute], from: range.start, to: range.end)
            XCTAssertEqual(diff.minute, 1000)
            XCTAssertEqual(range.start, referenceDate)
        }
    }
    
    func testCombinedTimeFormat() throws {
        // Test combined time format (hours and minutes)
        let range = DateRange.parseRelative("1h30m", relativeTo: referenceDate)
        XCTAssertNotNil(range)
        
        if let range = range {
            let calendar = Calendar.current
            let diffMinutes = calendar.dateComponents([.minute], from: range.start, to: range.end)
            XCTAssertEqual(diffMinutes.minute, 90) // 1h30m = 90 minutes
            
            // Alternative verification using seconds
            let diffSeconds = calendar.dateComponents([.second], from: range.start, to: range.end)
            XCTAssertEqual(diffSeconds.second, 5400) // 1h30m = 5400 seconds
            
            XCTAssertEqual(range.start, referenceDate)
        }
    }
    
    func testCombinedTimeFormatWithZeroMinutes() throws {
        // Test combined time format with zero minutes
        let range = DateRange.parseRelative("2h0m", relativeTo: referenceDate)
        XCTAssertNotNil(range)
        
        if let range = range {
            let calendar = Calendar.current
            let diffHours = calendar.dateComponents([.hour], from: range.start, to: range.end)
            XCTAssertEqual(diffHours.hour, 2)
            XCTAssertEqual(range.start, referenceDate)
        }
    }
}
