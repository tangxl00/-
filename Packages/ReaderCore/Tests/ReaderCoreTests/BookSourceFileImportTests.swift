//
//  BookSourceFileImportTests.swift
//  ReaderCoreTests
//
//  v1.2.3「从文件导入书源」核心层回归：
//    · 多文件合并导入（成功数汇总、跨文件去重同口径、条目编号连续、失败定位到文件）
//    · GBK 编码书源文件解码（这是最容易被误判成「不是合法 JSON」的一档）
//    · 单个文件读失败 / 编码不可识别时不影响其余文件
//

import XCTest
@testable import ReaderCore

final class BookSourceFileImportTests: XCTestCase {

    // MARK: - 夹具

    private func sourceJSON(url: String, name: String) -> String {
        """
        {
          "bookSourceUrl": "\(url)",
          "bookSourceName": "\(name)",
          "bookSourceType": 0,
          "ruleSearch": { "bookList": "class.book" }
        }
        """
    }

    /// 把一个 JSON 对象包成数组，模拟「一个文件里多个书源」
    private func sourceArrayJSON(_ items: [(url: String, name: String)]) -> String {
        "[" + items.map { sourceJSON(url: $0.url, name: $0.name) }.joined(separator: ",") + "]"
    }

    // MARK: - 1. 多文件合并导入

    func testMultiFileImportMergesCounts() {
        let drafts = [
            SourceFileDraft(
                fileName: "a.json",
                data: sourceArrayJSON([("https://f1.example.com", "文件一源A"),
                                       ("https://f2.example.com", "文件一源B")])
                    .data(using: .utf8)!
            ),
            SourceFileDraft(
                fileName: "b.txt",
                data: sourceJSON(url: "https://f3.example.com", name: "文件二源").data(using: .utf8)!
            ),
        ]

        let svc = BookSourceImportService()
        let report = svc.importFiles(drafts)

        XCTAssertEqual(report.items.count, 3, "两个文件的条目必须合并成一份报告")
        XCTAssertEqual(report.successCount, 3)
        XCTAssertEqual(report.failureCount, 0)
        XCTAssertEqual(report.usableCount, 3)
        XCTAssertEqual(report.headline, "成功 3 / 失败 0")
    }

    func testMultiFileImportNumbersItemsContinuously() {
        let drafts = [
            SourceFileDraft(fileName: "a.json",
                            data: sourceArrayJSON([("https://n1.example.com", "源1"),
                                                   ("https://n2.example.com", "源2")]).data(using: .utf8)!),
            SourceFileDraft(fileName: "b.json",
                            data: sourceArrayJSON([("https://n3.example.com", "源3"),
                                                   ("https://n4.example.com", "源4")]).data(using: .utf8)!),
        ]
        let report = BookSourceImportService().importFiles(drafts)

        XCTAssertEqual(report.items.map(\.index), [1, 2, 3, 4], "编号必须跨文件连续，不能每个文件从 1 重来")
    }

    func testMultiFileImportDeduplicatesAcrossFiles() {
        // 同一个 bookSourceUrl 出现在两个文件里：第二个必须记为 duplicate（与数组内重复同口径）
        let drafts = [
            SourceFileDraft(fileName: "a.json",
                            data: sourceJSON(url: "https://dup.example.com", name: "重复源").data(using: .utf8)!),
            SourceFileDraft(fileName: "b.json",
                            data: sourceJSON(url: "https://dup.example.com", name: "重复源").data(using: .utf8)!),
        ]
        let report = BookSourceImportService().importFiles(drafts)

        XCTAssertEqual(report.successCount, 1, "重复 URL 只能算一次成功")
        XCTAssertEqual(report.duplicateCount, 1, "后到的必须记为重复跳过，而不是失败")
        XCTAssertEqual(report.failureCount, 0, "重复不是失败")
        XCTAssertEqual(report.items[1].outcome, .duplicate)
        XCTAssertTrue(report.headline.contains("重复跳过 1"))
    }

    func testMultiFileImportRespectsExistingURLs() {
        let drafts = [
            SourceFileDraft(fileName: "a.json",
                            data: sourceJSON(url: "https://existing.example.com", name: "已存在").data(using: .utf8)!)
        ]
        let svc = BookSourceImportService(existingURLs: ["https://existing.example.com"])
        let report = svc.importFiles(drafts)

        XCTAssertEqual(report.duplicateCount, 1)
        XCTAssertEqual(report.successCount, 0)
        XCTAssertEqual(report.items.first?.outcome, .duplicate)
    }

    func testEachItemCarriesFileOrigin() {
        let drafts = [
            SourceFileDraft(fileName: "good.json",
                            data: sourceJSON(url: "https://ok.example.com", name: "好源").data(using: .utf8)!),
            SourceFileDraft(fileName: "bad.json",
                            data: Data(#"{"bookSourceName":"缺地址"}"#.utf8)),
        ]
        let report = BookSourceImportService().importFiles(drafts)

        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(report.items[0].originDescription, "文件：good.json")
        XCTAssertEqual(report.items[1].originDescription, "文件：bad.json")
        XCTAssertEqual(report.items[1].outcome, .failed)
        XCTAssertEqual(report.failureCount, 1, "缺 bookSourceUrl 的文件必须计入失败")
        XCTAssertTrue(report.items[1].reason?.contains("bookSourceUrl") == true,
                      "失败原因必须点明缺哪个字段，实际：\(report.items[1].reason ?? "nil")")
    }

    func testOriginSummariesGroupPerFile() {
        let drafts = [
            SourceFileDraft(fileName: "a.json",
                            data: sourceArrayJSON([("https://s1.example.com", "源1"),
                                                   ("https://s2.example.com", "源2")]).data(using: .utf8)!),
            SourceFileDraft(fileName: "b.json",
                            data: Data("not json at all".utf8)),
        ]
        let report = BookSourceImportService().importFiles(drafts)

        let summaries = report.originSummaries
        XCTAssertEqual(summaries.count, 2, "两个文件必须给出两组小结")
        XCTAssertEqual(summaries[0].origin, "文件：a.json")
        XCTAssertEqual(summaries[0].successCount, 2)
        XCTAssertEqual(summaries[0].line, "成功 2 / 失败 0")
        XCTAssertEqual(summaries[1].origin, "文件：b.json")
        XCTAssertEqual(summaries[1].failureCount, 1)
        XCTAssertEqual(summaries[1].line, "成功 0 / 失败 1")
    }

    // MARK: - 2. GBK 编码

    func testGBKEncodedSourceFileIsDecoded() throws {
        // 用 GBK 字节构造一个合法书源 JSON：源名是中文，UTF-8 解码会失败，
        // 只有走 GBK 分支才能拿到可解析文本。
        let json = sourceJSON(url: "https://gbk.example.com", name: "本地书源")
        var data = Data(json.utf8)
        // 把 UTF-8 编码的那段中文换成 GBK 字节，其余部分保持不变
        let utf8Name = "本地书源".data(using: .utf8)!
        let gbkName = Data([0xB1, 0xBE, 0xB5, 0xD8, 0xCA, 0xE9, 0xD4, 0xB4]) // 本地书源
        let range = data.range(of: utf8Name)
        XCTAssertNotNil(range, "夹具构造失败：JSON 里找不到中文源名")
        if let range { data.replaceSubrange(range, with: gbkName) }

        // 前提校验：这份字节确实不是合法 UTF-8，否则测的就不是 GBK 分支
        XCTAssertNil(String(data: data, encoding: .utf8), "夹具必须是非法 UTF-8，否则测不到 GBK 分支")

        let decoded = try BookSourceImportService.decodeFileData(data)
        XCTAssertEqual(decoded.encoding, .gbk, "必须靠 GBK 分支解出来")
        XCTAssertTrue(decoded.text.contains("本地书源"), "GBK 中文源名必须正确解码，实际：\(decoded.text)")

        let report = BookSourceImportService().importFiles([
            SourceFileDraft(fileName: "gbk书源.json", data: data)
        ])
        XCTAssertEqual(report.successCount, 1, "GBK 文件必须能正常导入")
        XCTAssertEqual(report.items.first?.sourceName, "本地书源", "源名不能是乱码")
    }

    func testUTF8FileDecodesWithoutFallback() throws {
        let data = Data(sourceJSON(url: "https://utf8.example.com", name: "中文书源").utf8)
        let decoded = try BookSourceImportService.decodeFileData(data)

        XCTAssertEqual(decoded.encoding, .utf8, "合法 UTF-8 不应触发 GBK 探测")
        XCTAssertTrue(decoded.notes.isEmpty, "UTF-8 不需要编码提示")
        XCTAssertTrue(decoded.text.contains("中文书源"))
    }

    func testEmptyFileIsReportedNotCrashing() {
        let report = BookSourceImportService().importFiles([
            SourceFileDraft(fileName: "empty.json", data: Data())
        ])

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.outcome, .failed)
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertTrue(report.items.first?.reason?.contains("文件为空") == true,
                      "0 字节必须给出明确原因，实际：\(report.items.first?.reason ?? "nil")")
    }

    // MARK: - 3. 读失败容错

    func testReadFailureDoesNotBlockOtherFiles() {
        let drafts = [
            SourceFileDraft(fileName: "good.json",
                            data: sourceJSON(url: "https://survivor.example.com", name: "幸存源").data(using: .utf8)!),
            SourceFileDraft(fileName: "denied.json", data: nil, readError: "没有读取权限"),
        ]
        let report = BookSourceImportService().importFiles(drafts)

        XCTAssertEqual(report.successCount, 1, "一个文件读失败不能拖死整批")
        XCTAssertEqual(report.failureCount, 1, "读失败必须计入失败")
        XCTAssertEqual(report.items[1].originDescription, "文件：denied.json")
        XCTAssertTrue(report.items[1].reason?.contains("没有读取权限") == true)
        XCTAssertTrue(report.items[1].reason?.contains("denied.json") == true,
                      "读失败原因要能让用户定位到哪个文件")
    }

    func testMixedBatchStillImportsValidSources() {
        // 真实场景：用户多选几个文件，其中夹一个不是书源的 JSON
        let drafts = [
            SourceFileDraft(fileName: "valid.json",
                            data: sourceJSON(url: "https://valid.example.com", name: "有效源").data(using: .utf8)!),
            SourceFileDraft(fileName: "other.json",
                            data: Data(#"{"hello":"world"}"#.utf8)),
            SourceFileDraft(fileName: "valid2.txt",
                            data: sourceJSON(url: "https://valid2.example.com", name: "有效源2").data(using: .utf8)!),
        ]
        let report = BookSourceImportService().importFiles(drafts)

        XCTAssertEqual(report.successCount, 2)
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertEqual(report.items.count, 3)
        XCTAssertEqual(report.usableCount, 2)
        XCTAssertTrue(report.items[1].reason?.contains("bookSourceUrl") == true)
    }

    func testEmptyDraftListYieldsEmptyReport() {
        let report = BookSourceImportService().importFiles([])
        XCTAssertEqual(report.items.count, 0)
        XCTAssertEqual(report.successCount, 0)
        XCTAssertEqual(report.failureCount, 0)
        XCTAssertEqual(report.headline, "成功 0 / 失败 0")
    }

    // MARK: - 4. 与单文本入口口径一致

    func testFileImportMatchesPayloadImportForSameContent() {
        let text = sourceArrayJSON([("https://c1.example.com", "同源1"),
                                    ("https://c2.example.com", "同源2")])

        let viaPayload = BookSourceImportService()
            .importPayload(ImportPayload(text: text, originDescription: "手动粘贴"))
        let viaFile = BookSourceImportService()
            .importFiles([SourceFileDraft(fileName: "same.json", data: Data(text.utf8))])

        XCTAssertEqual(viaFile.successCount, viaPayload.successCount)
        XCTAssertEqual(viaFile.failureCount, viaPayload.failureCount)
        XCTAssertEqual(viaFile.duplicateCount, viaPayload.duplicateCount)
        XCTAssertEqual(viaFile.items.map(\.outcome), viaPayload.items.map(\.outcome),
                       "文件入口与粘贴入口对同一内容必须给出相同判定")
    }
}
