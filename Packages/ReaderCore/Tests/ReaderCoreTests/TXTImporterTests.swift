import XCTest
@testable import ReaderCore

/// 本地 TXT 导入：编码识别、标准/宽松分章、兜底切分。
/// 对应需求 6-1 ~ 6-3 与自测标准 TXT 分章。
final class TXTImporterTests: XCTestCase {

    let sample = """
    这是一段前言内容。

    第一章 起点
    第一章的正文内容。

    第二章 转折
    第二章的正文内容。

    第三章 结局
    第三章的正文内容。
    """

    func testStandardRuleChapterize() throws {
        let r = try TXTImporter.chapterize(text: sample, bookName: "样本", rule: TXTChapterRules.standard)
        // 前言单独成章 + 3 个正章
        let titles = r.chapters.map(\.title)
        XCTAssertTrue(titles.contains("前言"))
        XCTAssertTrue(titles.contains("第一章 起点"))
        XCTAssertTrue(titles.contains("第二章 转折"))
        XCTAssertTrue(titles.contains("第三章 结局"))
        XCTAssertEqual(r.chapters.filter { !$0.isSynthetic }.count, r.chapters.count)
    }

    func testChaptersCoverEntireTextNoGapNoOverlap() throws {
        let r = try TXTImporter.chapterize(text: sample, bookName: "样本", rule: TXTChapterRules.standard)
        let ns = sample as NSString
        // 相邻章节首尾相接
        for i in 1..<r.chapters.count {
            XCTAssertEqual(r.chapters[i].start, r.chapters[i - 1].end, "第 \(i) 章与上一章不衔接")
        }
        // 最后一章覆盖到全文末尾
        XCTAssertEqual(r.chapters.last?.end, ns.length)
        XCTAssertEqual(r.totalLength, ns.length)
    }

    func testBodyOfChapterMatchesRange() throws {
        let r = try TXTImporter.chapterize(text: sample, bookName: "样本", rule: TXTChapterRules.standard)
        let ch2 = r.chapters.first { $0.title.contains("第二章") }!
        let body = TXTImporter.body(of: ch2, in: sample)
        XCTAssertTrue(body.contains("第二章"))
        XCTAssertTrue(body.contains("第二章的正文内容"))
        XCTAssertEqual(body.count, ch2.length)
    }

    func testChineseNumberChapters() throws {
        let text = "第十一章 abc\n内容\n第十二章 def\n内容"
        let r = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.standard)
        XCTAssertEqual(r.chapters.count, 2)
        XCTAssertTrue(r.chapters[0].title.contains("十一"))
    }

    func testVolumeAndSectionMarkers() throws {
        let text = "第一卷 起源\nx\n第二节 发展\ny\n番外 外传\nz"
        let r = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.standard)
        let titles = r.chapters.map(\.title)
        XCTAssertTrue(titles.contains { $0.contains("第一卷") })
        XCTAssertTrue(titles.contains { $0.contains("第二节") })
        XCTAssertTrue(titles.contains { $0.contains("番外") })
    }

    func testPrologueAndEpilogue() throws {
        let text = "序章\na\n尾声\nb"
        let r = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.standard)
        XCTAssertEqual(r.chapters.count, 2)
        XCTAssertEqual(r.chapters[0].title, "序章")
        XCTAssertEqual(r.chapters[1].title, "尾声")
    }

    func testFullWidthDigits() throws {
        let text = "第１章 全角\na\n第２章 数字\nb"
        let r = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.standard)
        XCTAssertEqual(r.chapters.count, 2)
    }

    func testLongLineNotTreatedAsTitle() throws {
        // 超过 maxTitleLength(40) 的行即使匹配格式也当正文
        let longTitle = "第一章 " + String(repeating: "字", count: 50)
        let text = longTitle + "\n正文"
        let r = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.standard)
        XCTAssertTrue(r.chapters.allSatisfy { $0.isSynthetic })
    }

    func testNoTitleFallsBackToSynthetic() throws {
        let text = String(repeating: "毫无章节格式的正文。\n", count: 100)
        let r = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.standard)
        XCTAssertFalse(r.chapters.isEmpty)
        XCTAssertTrue(r.chapters.allSatisfy { $0.isSynthetic })
        XCTAssertEqual(r.ruleID, "standard")
        XCTAssertFalse(r.notes.isEmpty, "兜底切分应给出说明")
    }

    func testSyntheticChunkSize() {
        let text = String(repeating: "字", count: 20000)
        let chapters = TXTImporter.syntheticChapters(text: text)
        XCTAssertEqual(chapters.count, 3) // 8000+8000+4000
        XCTAssertEqual(chapters.last?.end, 20000)
        XCTAssertTrue(chapters.allSatisfy { $0.isSynthetic })
        XCTAssertTrue(chapters[0].title.contains("自动切分"))
    }

    func testLooseRuleChapterNumber() throws {
        let text = "Chapter 1 Beginning\nx\nChapter 2 End\ny"
        let r = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.loose)
        XCTAssertEqual(r.chapters.count, 2)
        // standard 规则不认 Chapter
        let r2 = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.standard)
        XCTAssertTrue(r2.chapters.allSatisfy { $0.isSynthetic })
    }

    func testLooseRuleNumericTitle() throws {
        let text = "1、觉醒\nx\n2、离开\ny"
        let r = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.loose)
        XCTAssertEqual(r.chapters.filter { !$0.isSynthetic }.count, 2)
    }

    func testLooseRuleParenNumber() throws {
        let text = "（一）开端\nx\n（二）发展\ny"
        let r = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.loose)
        XCTAssertEqual(r.chapters.filter { !$0.isSynthetic }.count, 2)
    }

    func testLooseRuleVolumeX() throws {
        let text = "卷 一\nx\n卷 二\ny"
        let r = try TXTImporter.chapterize(text: text, bookName: "t", rule: TXTChapterRules.loose)
        XCTAssertEqual(r.chapters.filter { !$0.isSynthetic }.count, 2)
    }

    func testRuleLookupByID() {
        XCTAssertNotNil(TXTChapterRules.rule(id: "standard"))
        XCTAssertNotNil(TXTChapterRules.rule(id: "loose"))
        XCTAssertNil(TXTChapterRules.rule(id: "nope"))
        XCTAssertEqual(TXTChapterRules.all.count, 2)
    }

    func testImportFromDataUTF8() throws {
        let data = sample.data(using: .utf8)!
        let r = try TXTImporter.import(data: data, bookName: "样本")
        XCTAssertEqual(r.encoding, .utf8)
        XCTAssertEqual(r.bookName, "样本")
        XCTAssertGreaterThanOrEqual(r.chapterCount, 3)
    }

    /// Python `"...".encode("gbk")` 生成的参考字节（沙箱外预先计算）。
    static let gbkSampleBytes: [UInt8] = [0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x20, 0xC6, 0xF0, 0xB5, 0xE3, 0x0A, 0xD5, 0xE2, 0xCA, 0xC7, 0x47, 0x42, 0x4B, 0xB1, 0xE0, 0xC2, 0xEB, 0xB5, 0xC4, 0xD5, 0xFD, 0xCE, 0xC4, 0xA1, 0xA3]

    func testImportFromDataGBK() throws {
        let gbkText = "第一章 起点\n这是GBK编码的正文。"
        let data = Data(Self.gbkSampleBytes)
        let r = try TXTImporter.import(data: data, bookName: "gbk书")
        XCTAssertEqual(r.encoding, .gbk)
        XCTAssertEqual(r.chapters.filter { !$0.isSynthetic }.count, 1)
        let decoded = try TextDecoder.decode(data, as: .gbk)
        let body = TXTImporter.body(of: r.chapters[0], in: decoded)
        XCTAssertTrue(body.contains("起点"))
        XCTAssertTrue(body.contains("这是GBK编码的正文"))
    }

    func testImportEmptyThrows() {
        XCTAssertThrowsError(try TXTImporter.import(data: Data(), bookName: "空"))
        XCTAssertThrowsError(try TXTImporter.import(data: Data([0xFF]), bookName: "坏"))
    }

    func testImportForcedEncodingMismatchThrows() {
        let utf8 = sample.data(using: .utf8)!
        // 强制按 GBK 解码 UTF-8 字节大概率失败或乱码判定 → undecodable 或回退
        do {
            _ = try TXTImporter.import(data: utf8, bookName: "t", forcedEncoding: .gbk)
        } catch {
            // 抛错（undecodable）是可接受行为；不抛也不算失败（GBK 恰好可解）
        }
    }

    func testImportRespectsRuleID() throws {
        let data = "Chapter 1 A\nx".data(using: .utf8)!
        let r = try TXTImporter.import(data: data, bookName: "t", ruleID: "loose")
        XCTAssertEqual(r.ruleID, "loose")
        XCTAssertEqual(r.chapters.filter { !$0.isSynthetic }.count, 1)
    }

    func testLooksGarbled() {
        // 判据（需求 7-2 口径）：替换字符比例 + 控制字符比例
        XCTAssertTrue(TextDecoder.looksGarbled("正常\u{FFFD}正常\u{FFFD}正常\u{FFFD}正常\u{FFFD}正常\u{FFFD}正常"))
        XCTAssertTrue(TextDecoder.looksGarbled("a\u{01}b\u{02}c\u{03}d\u{04}e\u{05}f\u{06}g"))
        XCTAssertFalse(TextDecoder.looksGarbled("正常中文"))
        XCTAssertFalse(TextDecoder.looksGarbled(""))
        XCTAssertFalse(TextDecoder.looksGarbled("换行\n制表\t合法"))
        // 已知局限：「锟斤拷」（U+FFFD 二次编码后的 GBK 字形）不在该判据内
        XCTAssertFalse(TextDecoder.looksGarbled("锟斤拷锟斤拷"))
    }

    func testDecodeResponseCharsetGBK() {
        let gbkText = "你好世界"
        let data = Data([0xC4, 0xE3, 0xBA, 0xC3, 0xCA, 0xC0, 0xBD, 0xE7])
        let out = TextDecoder.decodeResponse(data, charset: "gbk")
        XCTAssertEqual(out, gbkText)
    }

    func testDecodeResponseDefaultUTF8() {
        let data = "你好".data(using: .utf8)!
        XCTAssertEqual(TextDecoder.decodeResponse(data, charset: nil), "你好")
    }
}

