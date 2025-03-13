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
            XCTAssertEqual(range.end, referenceDate)
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
            XCTAssertEqual(range.end, referenceDate)
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
            XCTAssertEqual(range.end, referenceDate)
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
            XCTAssertEqual(range.end, referenceDate)
        }
    }
}
