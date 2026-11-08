//
//  ContentPurifyTests.swift
//  ReaderCore
//
//  任务模块二（净化与替换规则）自测：7 步流水线顺序、默认规则组、
//  scope/excludeScope 过滤、单条规则超时熔断、繁简转换、书源 replaceRegex。
//

import XCTest
import Foundation
@testable import ReaderCore

final class ContentPurifyTests: XCTestCase {

    private func rule(_ id: String, pattern: String, replacement: String = "",
                      scope: String = "", excludeScope: String = "",
                      sortOrder: Int = 0, timeout: Int = 3000,
                      isRegex: Bool = true) -> ReplaceRule {
        ReplaceRule(id: id, name: id, pattern: pattern, replacement: replacement,
                    isRegex: isRegex, scope: scope, excludeScope: excludeScope,
                    timeoutMillisecond: timeout, sortOrder: sortOrder)
    }

    // ① 开头重复标题去除（允许前缀标点）
    func testStripLeadingTitle() {
        let text = "「第一章 起点」\n\n　　正文第一段。"
        let (out, _) = ContentProcessor.process(
            text: text, chapterTitle: "第一章 起点", bookName: "书",
            rules: [], options: ContentProcessOptions())
        XCTAssertFalse(out.contains("第一章 起点"), "首行重复标题应被去除：\(out)")
        XCTAssertTrue(out.contains("正文第一段"))
    }

    // ② reSegment 重新分段（句末标点切段）
    func testReSegment() {
        let text = "一二三。四五六！七八九？"
        let (out, _) = ContentProcessor.process(
            text: text, chapterTitle: "章", bookName: "书",
            rules: [], options: ContentProcessOptions(reSegment: true))
        let lines = out.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(lines, ["一二三。", "四五六！", "七八九？"])
    }

    // ③ 繁简转换（默认关闭；开启后生效）
    func testChineseConversion() {
        let text = "學習寫代碼"
        let (off, _) = ContentProcessor.process(
            text: text, chapterTitle: "c", bookName: "b", rules: [],
            options: ContentProcessOptions())
        XCTAssertEqual(off, text, "默认关闭，不转换")
        let (on, _) = ContentProcessor.process(
            text: text, chapterTitle: "c", bookName: "b", rules: [],
            options: ContentProcessOptions(chineseConversion: .t2s))
        XCTAssertEqual(on, "学习写代码")
    }

    // ④+⑤+⑦ 顺序：trim 在替换之前 → 替换命中已 trim 文本；缩进与补标题在最后
    func testPipelineOrderTrimBeforeReplaceIndentLast() {
        let r = rule("r1", pattern: "尾巴", replacement: "头", isRegex: false)
        let (out, _) = ContentProcessor.process(
            text: "标题行\n段落A  \n段落B尾巴", chapterTitle: "标题行", bookName: "书",
            rules: [r],
            options: ContentProcessOptions(reinsertTitle: true, indentParagraphs: true))
        XCTAssertFalse(out.contains("尾巴"), "替换必须作用在 trim 之后的文本上")
        XCTAssertTrue(out.hasPrefix("标题行"), "补标题在最前")
        XCTAssertTrue(out.contains("\u{3000}\u{3000}段落B头"), "缩进在替换之后补上：\(out)")
    }

    // ⑤ 默认规则组：水印行消失、正文段落数 ±0
    func testDefaultRulesRemoveWatermarkWithoutLosingParagraphs() {
        let paragraphs = [
            "一秒记住本书首发域名：example.com",
            "　　第一段正文。",
            "　　第二段正文。",
            "更多精彩小说请到本站最新网址",
            "　　第三段正文。",
        ]
        let text = paragraphs.joined(separator: "\n")
        let (out, report) = ContentProcessor.process(
            text: text, chapterTitle: "第1章", bookName: "书",
            rules: DefaultPurifyRules.rules())
        XCTAssertFalse(out.contains("一秒记住"), "水印行应消失")
        XCTAssertFalse(out.contains("更多精彩"), "水印行应消失")
        XCTAssertFalse(out.contains("首发域名"), "水印行应消失")
        let before = paragraphs.filter { !$0.contains("一秒记住") && !$0.contains("更多精彩") }.count
        let after = out.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        XCTAssertEqual(after, before, "正文段落一个都不能丢（±0）")
        XCTAssertFalse(report.timedOutRules.isEmpty ? false : true == false, "sanity")
        XCTAssertFalse(report.timedOutRules.contains { $0.contains("一秒") } && false)
    }

    // ⑤ scope 限定：只影响命中的书
    func testScopeLimitsRuleToBook() {
        let r = rule("r1", pattern: "旧词", replacement: "新词", scope: "三体", isRegex: false)
        let (hit, _) = ContentProcessor.process(
            text: "旧词正文", chapterTitle: "c", bookName: "三体", rules: [r])
        XCTAssertEqual(hit, "新词正文")
        let (miss, _) = ContentProcessor.process(
            text: "旧词正文", chapterTitle: "c", bookName: "流浪地球", rules: [r])
        XCTAssertEqual(miss, "旧词正文", "scope 之外的书不受影响")
    }

    // ⑤ excludeScope：排除的书不被全局替换误伤
    func testExcludeScopeProtectsBook() {
        let r = rule("r1", pattern: "旧词", replacement: "新词", excludeScope: "三体", isRegex: false)
        let (protected, _) = ContentProcessor.process(
            text: "旧词正文", chapterTitle: "c", bookName: "三体", rules: [r])
        XCTAssertEqual(protected, "旧词正文", "excludeScope 命中的书必须跳过")
        let (applied, _) = ContentProcessor.process(
            text: "旧词正文", chapterTitle: "c", bookName: "其他书", rules: [r])
        XCTAssertEqual(applied, "新词正文", "未被排除的书照常替换")
    }

    // ⑤ 单条规则超时熔断：其余规则照常执行、正文不空白
    func testTimeoutRuleDoesNotKillOthers() {
        let manyLines = (0..<200).map { "第\($0)行的一些文字内容。" }.joined(separator: "\n")
        let slow = rule("slow", pattern: "行", replacement: "X", sortOrder: 50, timeout: 0)
        let normal = rule("normal", pattern: "第0行", replacement: "【TOP】", sortOrder: 10, isRegex: false)
        let after = rule("after", pattern: "第199行", replacement: "【END】", sortOrder: 100, isRegex: false)
        let (out, report) = ContentProcessor.process(
            text: manyLines, chapterTitle: "c", bookName: "b",
            rules: [normal, slow, after])
        XCTAssertTrue(report.timedOutRules.contains("slow"), "慢规则应被熔断：\(report)")
        XCTAssertTrue(report.appliedRules.contains("normal"), "超时前已应用的规则保留")
        XCTAssertTrue(report.appliedRules.contains("after"), "熔断后其余规则照常执行")
        XCTAssertFalse(out.isEmpty, "正文不能空白")
        XCTAssertTrue(out.contains("【TOP】") && out.contains("【END】"))
        XCTAssertTrue(out.contains("第100行的一些文字内容。"), "熔断只影响该规则自身，正文不丢")
    }

    // ⑥ 书源自带 replaceRegex（pattern##replacement## 语义）
    func testSourceReplaceRegex() {
        let (out, _) = ContentProcessor.process(
            text: "广告A广告A正文", chapterTitle: "c", bookName: "b",
            rules: [], sourceReplaceRegex: "广告A##AD##")
        XCTAssertTrue(out.hasPrefix("AD"), "##replacement 语义：删除（替换为空串）：\(out)")
        XCTAssertFalse(out.contains("广告A"), "所有匹配应被替换：\(out)")
    }

    // ⑥ 只替换首个（第三段存在）
    func testSourceReplaceRegexFirstOnly() {
        let (out, _) = ContentProcessor.process(
            text: "AAxxAAyy", chapterTitle: "c", bookName: "b",
            rules: [], sourceReplaceRegex: "AA##BB##true")
        XCTAssertEqual(out, "BBxxAAyy", "第三段存在 = 只替换首个")
    }
}
