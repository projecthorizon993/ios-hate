import XCTest
@testable import LumaFrame

final class LumaFrameTests: XCTestCase {
    func testBuiltInPresetCatalogContainsStarterLooks() {
        XCTAssertEqual(ColorGradePreset.builtIns.count, 10)
        XCTAssertTrue(ColorGradePreset.builtIns.contains { $0.name == "Cinematic" })
    }

    func testNeutralGradeDoesNotChangeSourceSettings() {
        let grade = GradeSettings.neutral
        XCTAssertEqual(grade.contrast, 1)
        XCTAssertEqual(grade.saturation, 1)
    }
}
