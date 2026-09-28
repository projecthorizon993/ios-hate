import XCTest
@testable import LumaFrame

/// Lean tests for the parts of Step 0 that have arithmetic in them. Camera probing is
/// verified on device via the report, not here.
final class ReportTextTests: XCTestCase {

    // MARK: - Rendering

    func testInfoEntryHasNoMarker() {
        let line = ReportText.entryLine(ReportEntry("back camera count", "3"))
        XCTAssertEqual(line, "  back camera count: 3")
    }

    func testSeverityMarkersAreGreppable() {
        XCTAssertEqual(ReportText.entryLine(ReportEntry("RAW available", "yes", .good)),
                       "  + RAW available: yes")
        XCTAssertEqual(ReportText.entryLine(ReportEntry("ANE usage", "no", .warn)),
                       "  ! ANE usage: no")
        XCTAssertEqual(ReportText.entryLine(ReportEntry("session", "crashed", .fail)),
                       "  x session: crashed")
    }

    func testRenderIncludesHeaderSectionsAndLog() {
        let report = CapabilityReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            platform: "iOS 17.5 (iPhone14,5)",
            summary: "back cameras: 3",
            sections: [
                ReportSection("Device", [ReportEntry("model", "iPhone")]),
                ReportSection("Camera discovery", [ReportEntry("back camera count", "3")])
            ]
        )

        let text = ReportText.render(report, logLines: ["ml #1 gpu 4.10ms"])

        XCTAssertTrue(text.hasPrefix("LumaFrame Capability Report"))
        XCTAssertTrue(text.contains("platform: iOS 17.5 (iPhone14,5)"))
        XCTAssertTrue(text.contains("summary: back cameras: 3"))
        XCTAssertTrue(text.contains("== Device =="))
        XCTAssertTrue(text.contains("== Camera discovery =="))
        XCTAssertTrue(text.contains("  model: iPhone"))
        XCTAssertTrue(text.contains("== Recent log (1 lines) =="))
        XCTAssertTrue(text.contains("ml #1 gpu 4.10ms"))
    }

    func testRenderOmitsLogSectionWhenEmpty() {
        let report = CapabilityReport(generatedAt: Date(), platform: "iOS", summary: "", sections: [])
        XCTAssertFalse(ReportText.render(report, logLines: []).contains("Recent log"))
    }

    // MARK: - Formatting

    func testShutterFormatsAsFractionBelowOneSecond() {
        XCTAssertEqual(ReportFormat.shutter(0.0083333), "1/120")
        XCTAssertEqual(ReportFormat.shutter(0.5), "1/2")
        XCTAssertEqual(ReportFormat.shutter(1.5), "1.5s")
        XCTAssertEqual(ReportFormat.shutter(0), "n/a")
    }

    func testNumberDropsTrailingZeroesButKeepsDecimals() {
        XCTAssertEqual(ReportFormat.number(400), "400")
        XCTAssertEqual(ReportFormat.number(1.25), "1.25")
        XCTAssertEqual(ReportFormat.number(0), "0")
    }

    func testFourCCRendersControlBytesAsHex() {
        XCTAssertEqual(ReportFormat.fourCC(0x42413831), "BA81")
        // Non-printable bytes must not leak into the report as raw characters.
        XCTAssertFalse(ReportFormat.fourCC(0x000000FF).contains("\u{FF}"))
    }
}
