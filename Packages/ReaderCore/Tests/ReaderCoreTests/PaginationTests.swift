import XCTest
@testable import ReaderCore

/// 分页：页区间连续无重叠、isContiguous 校验、偏移→页码。
final class PaginationTests: XCTestCase {

    /// 固定行高构造器：每行 n 个字符、行高 h。
    private func fixedLines(text: String, charsPerLine: Int, height: Double) -> [TextLine] {
        var lines: [TextLine] = []
        var start = text.startIndex
        let chars = Array(text)
        var offset = 0
        while offset < chars.count {
            let len = min(charsPerLine, chars.count - offset)
            let end = offset + len
            lines.append(TextLine(start: offset, end: end, height: height))
            offset = end
        }
        return lines
    }

    func testContiguousAcrossPages() {
        let text = String(repeating: "字", count: 300)
        let lines = fixedLines(text: text, charsPerLine: 10, height: 20)
        let r = Paginator.paginate(lines: lines, pageHeight: 100, textLength: text.count, signature: "s")
        XCTAssertTrue(r.isContiguous, "分页区间必须连续")
        XCTAssertEqual(r.pages.count, lines.count * 20 / 100) // 每页 5 行
    }

    func testFirstPageStartsAtZeroAndLastEndsAtTextLength() {
        let text = String(repeating: "a", count: 250)
        let lines = fixedLines(text: text, charsPerLine: 10, height: 10)
        let r = Paginator.paginate(lines: lines, pageHeight: 50, textLength: text.count, signature: "s")
        XCTAssertEqual(r.pages.first?.start, 0)
        XCTAssertEqual(r.pages.last?.end, text.count)
        XCTAssertEqual(r.textLength, 250)
    }

    func testAdjacentPagesNoGapNoOverlap() {
        let text = String(repeating: "好", count: 500)
        let lines = fixedLines(text: text, charsPerLine: 15, height: 18)
        let r = Paginator.paginate(lines: lines, pageHeight: 100, textLength: text.count, signature: "s")
        for i in 1..<r.pages.count {
            XCTAssertEqual(r.pages[i].start, r.pages[i - 1].end)
        }
    }

    func testEmptyLinesYieldsNoPages() {
        let r = Paginator.paginate(lines: [], pageHeight: 100, textLength: 0, signature: "s")
        XCTAssertTrue(r.pages.isEmpty)
        XCTAssertTrue(r.isContiguous)
    }

    func testSinglePageWhenContentFits() {
        let text = "短文"
        let lines = [TextLine(start: 0, end: 2, height: 20)]
        let r = Paginator.paginate(lines: lines, pageHeight: 500, textLength: 2, signature: "s")
        XCTAssertEqual(r.pages.count, 1)
        XCTAssertEqual(r.pages[0], PageRange(start: 0, end: 2, pageIndex: 0))
    }

    func testOversizedLineStillGetsAPage() {
        // 单行高度超过页高：仍保证至少一行/页，不死循环
        let lines = [TextLine(start: 0, end: 5, height: 999)]
        let r = Paginator.paginate(lines: lines, pageHeight: 10, textLength: 5, signature: "s")
        XCTAssertEqual(r.pages.count, 1)
    }

    func testPageIndexForOffset() {
        let text = String(repeating: "x", count: 200)
        let lines = fixedLines(text: text, charsPerLine: 10, height: 10)
        let r = Paginator.paginate(lines: lines, pageHeight: 50, textLength: text.count, signature: "s")
        // 每页 5 行 × 10 字 = 50 字
        XCTAssertEqual(r.pageIndex(forCharacterOffset: 0), 0)
        XCTAssertEqual(r.pageIndex(forCharacterOffset: 49), 0)
        XCTAssertEqual(r.pageIndex(forCharacterOffset: 50), 1)
        XCTAssertEqual(r.pageIndex(forCharacterOffset: 199), r.pages.count - 1)
        // 越界偏移钳制到末页/首页（跳转进度语义），空结果才是 nil
        XCTAssertEqual(r.pageIndex(forCharacterOffset: 999), r.pages.count - 1)
        XCTAssertEqual(r.pageIndex(forCharacterOffset: -1), 0)
        XCTAssertEqual(PaginationResult(pages: [], signature: "s", lineCount: 0, textLength: 0)
            .pageIndex(forCharacterOffset: 5), nil)
    }

    func testConveniencePaginateWithApproximateMeasurer() {
        let text = String(repeating: "中文内容。", count: 60) // 300 字符
        let m = ApproximateMeasurer()
        let r = Paginator.paginate(
            text: text, width: 300, pageHeight: 400, lineHeight: 20,
            signature: "sig-1", measurer: m
        )
        XCTAssertFalse(r.pages.isEmpty)
        XCTAssertTrue(r.isContiguous)
        XCTAssertEqual(r.signature, "sig-1")
        XCTAssertEqual(r.textLength, text.count)
        // CJK 因子 1.0：300 宽 → 每行约 15 字
        XCTAssertEqual(r.lineCount, 20)
    }

    func testApproximateMeasurerASCIIHalfWidth() {
        let m = ApproximateMeasurer(cjkWidthFactor: 1.0, asciiWidthFactor: 0.5)
        // 宽度按「点」计：字符宽 = 因子 × 行高。行高 10 → ASCII 5pt、CJK 10pt。
        // width=100 → ASCII 每行 20 字，CJK 每行 10 字
        let ascii = String(repeating: "a", count: 40)
        let lines = m.lines(in: ascii, width: 100, lineHeight: 10)
        XCTAssertEqual(lines.count, 2)
        let cjk = String(repeating: "字", count: 20)
        let lines2 = m.lines(in: cjk, width: 100, lineHeight: 10)
        XCTAssertEqual(lines2.count, 2)
    }

    func testApproximateMeasurerRespectsNewlines() {
        let m = ApproximateMeasurer()
        let text = "aaaa\nbbbb\ncc"
        let lines = m.lines(in: text, width: 100, lineHeight: 10)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].start, 0)
        XCTAssertEqual(lines[1].start, 5)
        XCTAssertEqual(lines[2].start, 10)
        XCTAssertEqual(lines.last?.end, 12)
    }

    func testPageRangeLengthAndEquality() {
        let p = PageRange(start: 3, end: 9, pageIndex: 2)
        XCTAssertEqual(p.length, 6)
        XCTAssertEqual(p, PageRange(start: 3, end: 9, pageIndex: 2))
    }

    func testLayoutSignatureChangeRepaints() {
        // 签名不同 → UI 判定需要重排；签名相同 → 复用分页结果
        let m = ApproximateMeasurer()
        let text = String(repeating: "字", count: 100)
        let r1 = Paginator.paginate(text: text, width: 300, pageHeight: 400, lineHeight: 20, signature: "A", measurer: m)
        let r2 = Paginator.paginate(text: text, width: 300, pageHeight: 400, lineHeight: 20, signature: "B", measurer: m)
        XCTAssertNotEqual(r1.signature, r2.signature)
        // 宽度变化 → 行数变化
        let r3 = Paginator.paginate(text: text, width: 150, pageHeight: 400, lineHeight: 20, signature: "A", measurer: m)
        XCTAssertGreaterThan(r3.lineCount, r1.lineCount)
    }

    func testPaginationResultIsContiguousDetectsBroken() {
        // 人造断裂区间：isContiguous 必须能识别
        let broken = PaginationResult(
            pages: [PageRange(start: 0, end: 10, pageIndex: 0), PageRange(start: 20, end: 30, pageIndex: 1)],
            signature: "s", lineCount: 3, textLength: 30
        )
        XCTAssertFalse(broken.isContiguous)
    }
}
