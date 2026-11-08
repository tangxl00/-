import XCTest
@testable import ReaderCore

/// 阅读设置：钳制、排版签名、主题/字体枚举。
final class SettingsTests: XCTestCase {

    func testDefaults() {
        let d = ReadingSettings.default
        XCTAssertEqual(d.fontSize, 17)
        XCTAssertEqual(d.lineSpacing, 1.5)
        XCTAssertEqual(d.theme, .lightPaper)
        XCTAssertEqual(d.font, .system)
    }

    func testClampedPullsAllIntoRange() {
        let s = ReadingSettings(
            fontSize: 99, lineSpacing: 9.9, paragraphSpacing: -5,
            horizontalMargin: 500, firstLineIndent: -3
        )
        let c = s.clamped()
        XCTAssertTrue(ReadingSettings.fontSizeRange.contains(c.fontSize))
        XCTAssertTrue(ReadingSettings.lineSpacingRange.contains(c.lineSpacing))
        XCTAssertTrue(ReadingSettings.paragraphSpacingRange.contains(c.paragraphSpacing))
        XCTAssertTrue(ReadingSettings.horizontalMarginRange.contains(c.horizontalMargin))
        XCTAssertTrue(ReadingSettings.firstLineIndentRange.contains(c.firstLineIndent))
    }

    func testClampedKeepsValidValues() {
        let s = ReadingSettings(fontSize: 20, lineSpacing: 1.8, paragraphSpacing: 12, horizontalMargin: 24, firstLineIndent: 2)
        XCTAssertEqual(s.clamped(), s)
    }

    func testFontSizeRange() {
        XCTAssertEqual(ReadingSettings.fontSizeRange.lowerBound, 12)
        XCTAssertEqual(ReadingSettings.fontSizeRange.upperBound, 32)
    }

    func testLineSpacingRange() {
        XCTAssertEqual(ReadingSettings.lineSpacingRange.lowerBound, 1.0)
        XCTAssertEqual(ReadingSettings.lineSpacingRange.upperBound, 2.5)
    }

    func testLayoutSignatureChangesWithLayoutParams() {
        let base = ReadingSettings.default
        XCTAssertNotEqual(base.layoutSignature, ReadingSettings(fontSize: 24).layoutSignature)
        XCTAssertNotEqual(base.layoutSignature, ReadingSettings(lineSpacing: 2.0).layoutSignature)
        XCTAssertNotEqual(base.layoutSignature, ReadingSettings(paragraphSpacing: 20).layoutSignature)
        XCTAssertNotEqual(base.layoutSignature, ReadingSettings(horizontalMargin: 32).layoutSignature)
        XCTAssertNotEqual(base.layoutSignature, ReadingSettings(firstLineIndent: 0).layoutSignature)
        XCTAssertNotEqual(base.layoutSignature, ReadingSettings(font: .serif).layoutSignature)
    }

    func testLayoutSignatureIgnoresTheme() {
        // 主题只换配色不改排版 → 签名必须一致（换主题不重排）
        let a = ReadingSettings.default
        let b = ReadingSettings(theme: .darkNight)
        XCTAssertEqual(a.layoutSignature, b.layoutSignature)
    }

    func testLayoutSignatureStableForSameSettings() {
        XCTAssertEqual(ReadingSettings.default.layoutSignature, ReadingSettings.default.layoutSignature)
    }

    func testThemePalette() {
        for theme in ReaderTheme.allCases {
            XCTAssertFalse(theme.backgroundHex.isEmpty)
            XCTAssertFalse(theme.textHex.isEmpty)
        }
        XCTAssertTrue(ReaderTheme.darkNight.isDark)
        XCTAssertFalse(ReaderTheme.lightPaper.isDark)
    }

    func testPresetsCoverFullRange() {
        // 预设档位必须覆盖钳制区间的两端
        XCTAssertEqual(ReadingSettingsPresets.fontSizes.first, ReadingSettings.fontSizeRange.lowerBound)
        XCTAssertEqual(ReadingSettingsPresets.fontSizes.last, ReadingSettings.fontSizeRange.upperBound)
        XCTAssertEqual(ReadingSettingsPresets.lineSpacings.first, ReadingSettings.lineSpacingRange.lowerBound)
        XCTAssertEqual(ReadingSettingsPresets.lineSpacings.last, ReadingSettings.lineSpacingRange.upperBound)
    }

    func testCodableRoundTrip() throws {
        let s = ReadingSettings(fontSize: 21, lineSpacing: 1.7, paragraphSpacing: 8, horizontalMargin: 16, firstLineIndent: 2, font: .rounded, theme: .darkNight)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ReadingSettings.self, from: data)
        XCTAssertEqual(back, s)
    }
}
