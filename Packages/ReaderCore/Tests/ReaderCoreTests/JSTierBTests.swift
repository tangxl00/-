//
//  JSTierBTests.swift
//  ReaderCore
//
//  任务模块一（JS 规则兼容层 · Tier B 降级兼容）核心链路自测。
//  Linux 可跑：不依赖 JavaScriptCore，JSCRuntime（iOS 分支）不在本套覆盖范围。
//
//  覆盖：
//    · jsRuntime 为 nil 时 @js / {{}} / URL 选项 js 仍抛 jsUnsupported（不静默）；
//    · 接入 JSRuntime 后三处接入点均走求值（Fake 运行时）；
//    · jsLib 先于各规则注入绑定；
//    · JSJavaBridge 高频子集方法语义（编解码 / 文本 / 随机 UUID）；
//    · 未实现 java 方法抛带方法名的异常（禁止静默 undefined）；
//    · 受限同步桥硬超时不挂死（不可达地址 + 小超时，限时内抛错返回）。
//

import XCTest
import Foundation
@testable import ReaderCore

// MARK: - Fake 运行时

final class FakeJSRuntime: JSRuntime, @unchecked Sendable {
    var receivedScripts: [String] = []
    var receivedBindings: [JSBindings] = []
    var result: Any?
    var error: Error?

    func evaluate(_ script: String, bindings: JSBindings, timeout: Duration) throws -> Any? {
        receivedScripts.append(script)
        receivedBindings.append(bindings)
        if let error { throw error }
        return result
    }
}

// MARK: - 测试

final class JSTierBTests: XCTestCase {

    private func textCtx(jsLib: String? = nil) -> EvalContext {
        EvalContext(source: EvalSource.text("正文原文"), jsLib: jsLib)
    }

    // MARK: 无运行时：仍一刀切报错（不允许静默空串）

    func testNoRuntimeStillThrowsJsUnsupported() {
        let ev = RuleEvaluator()
        let ctx = textCtx()

        XCTAssertThrowsError(try ev.evaluate(rule: "@js:result + 'x'", in: ctx)) { err in
            guard case RuleEvalError.jsUnsupported = err else {
                return XCTFail("期望 jsUnsupported，实际：\(err)")
            }
        }
        XCTAssertThrowsError(try ev.evaluate(rule: "{{ 'a' + 'b' }}", in: ctx)) { err in
            guard case RuleEvalError.jsUnsupported = err else {
                return XCTFail("期望 jsUnsupported，实际：\(err)")
            }
        }
        XCTAssertThrowsError(
            try URLTemplateEngine.analyze(
                template: "https://a.com/s?q=1,{\"method\":\"POST\",\"js\":\"java.ajax(true)\"}",
                vars: [:], evaluator: ev
            )
        ) { err in
            guard case RuleEvalError.jsUnsupported = err else {
                return XCTFail("期望 jsUnsupported，实际：\(err)")
            }
        }
    }

    // MARK: @js 段 / <js> 段 / {{}} 表达式接入运行时

    func testJsTailSegmentGoesThroughRuntime() throws {
        let fake = FakeJSRuntime()
        fake.result = "ID-777"
        let ev = RuleEvaluator(jsRuntime: fake)
        let ctx = EvalContext(source: EvalSource.detect("<div><h1>标题</h1></div>"))
        let out = try ev.evaluate(rule: "@css:h1@text@js:'ID-' + result", in: ctx)
        XCTAssertEqual(out, "ID-777")
        XCTAssertTrue(fake.receivedScripts.contains { $0.contains("ID-") })
    }

    func testInlineJsBlockSegmentGoesThroughRuntime() throws {
        let fake = FakeJSRuntime()
        fake.result = "hello"
        let ev = RuleEvaluator(jsRuntime: fake)
        let out = try ev.evaluate(rule: "<js>java.ajax('https://x')</js>", in: textCtx())
        XCTAssertEqual(out, "hello")
    }

    func testBracesJSExpressionGoesThroughRuntime() throws {
        let fake = FakeJSRuntime()
        fake.result = 3
        let ev = RuleEvaluator(jsRuntime: fake)
        let out = try ev.evaluate(rule: "{{ result.length }}", in: textCtx())
        XCTAssertEqual(out, "3")
    }

    func testJsLibInjectedIntoBindingsBeforeRules() throws {
        let fake = FakeJSRuntime()
        fake.result = "ok"
        let ev = RuleEvaluator(jsRuntime: fake)
        let ctx = textCtx(jsLib: "function helper(){ return 1; }")
        _ = try ev.evaluate(rule: "@js:helper()", in: ctx)
        XCTAssertEqual(fake.receivedBindings.last?.jsLib, "function helper(){ return 1; }")
    }

    // MARK: URL 选项 js：接入运行时后执行并回写

    func testURLTemplateJsOptionExecutesWithRuntime() throws {
        let fake = FakeJSRuntime()
        fake.result = "sign-value"
        let ev = RuleEvaluator(jsRuntime: fake)
        let a = try URLTemplateEngine.analyze(
            template: "https://a.com/s?q=1,{\"method\":\"POST\",\"js\":\"java.md5Encode(result)\"}",
            vars: [:], evaluator: ev
        )
        XCTAssertEqual(a.option.effectiveMethod, .post)
        XCTAssertTrue(a.url.contains("sign-value"), "js 结果应回写进新 URL：\(a.url)")
        XCTAssertEqual(a.option.js, "java.md5Encode(result)")
    }

    // MARK: JSJavaBridge：已实现方法语义

    func testBridgeCodecMethods() throws {
        let bridge = JSJavaBridge()
        let b64 = try bridge.call("base64Encode", ["hello"])
        XCTAssertEqual(b64, "aGVsbG8=")
        XCTAssertEqual(try bridge.call("base64Decode", [b64]), "hello")

        let hex = try bridge.call("hexEncodeToString", ["hi"])
        XCTAssertEqual(hex, "6869")
        XCTAssertEqual(try bridge.call("hexDecodeToString", [hex]), "hi")

        let bytes = try bridge.call("strToBytes", ["AB"])
        XCTAssertEqual(try bridge.call("bytesToStr", [bytes]), "AB")

        let enc = try bridge.call("encodeURI", ["https://a.com/?q=三 体"])
        XCTAssertTrue(enc.contains("%20"), "空格应被百分号编码：\(enc)")
        XCTAssertTrue(enc.contains("%E4%B8%89"), "encodeURI 语义：CJK 百分号编码：\(enc)")
    }

    func testBridgeTextMethods() throws {
        let bridge = JSJavaBridge()
        let s = try bridge.call("t2s", ["學習寫代碼"])
        XCTAssertEqual(s, "学习写代码")
        XCTAssertEqual(try bridge.call("s2t", ["学习写代码"]), "學習寫代碼")

        let uuid = try bridge.call("randomUUID", [])
        XCTAssertEqual(uuid.count, 36, "UUID 标准长度 36（含 4 个连字符）：\(uuid)")
        XCTAssertEqual(uuid.filter { $0 == "-" }.count, 4)
    }

    func testBridgeToastAndLogDoNotCrash() throws {
        let bridge = JSJavaBridge()
        var toasts: [String] = []
        var logs: [String] = []
        bridge.toastHandler = { toasts.append($0) }
        bridge.logHandler = { logs.append($0) }
        _ = try bridge.call("toast", ["提示"])
        _ = try bridge.call("log", ["日志"])
        XCTAssertEqual(toasts, ["提示"])
        XCTAssertEqual(logs, ["日志"])
    }

    // MARK: 未实现方法：异常带方法名，禁止静默 undefined

    func testBridgeMissingMethodThrowsWithName() {
        let bridge = JSJavaBridge()
        XCTAssertThrowsError(try bridge.call("getVerificationCode", ["x"])) { err in
            guard case JSRuntimeError.missingMethod(let m) = err else {
                return XCTFail("期望 missingMethod，实际：\(err)")
            }
            XCTAssertEqual(m, "getVerificationCode")
            XCTAssertTrue(String(describing: err).contains("getVerificationCode"), "提示必须精确到方法名")
            XCTAssertTrue(String(describing: err).contains("本版未实现"))
        }
        XCTAssertThrowsError(try bridge.call("md5Encode", ["x"])) { err in
            guard case JSRuntimeError.missingMethod(let m) = err else {
                return XCTFail("期望 missingMethod，实际：\(err)")
            }
            XCTAssertEqual(m, "md5Encode")
        }
    }

    // MARK: 受限同步桥：硬超时不挂死

    func testSyncBridgeHardTimeoutDoesNotHang() {
        let bridge = SemaphoreSyncHTTPBridge()
        let start = Date()
        XCTAssertThrowsError(
            try bridge.request(
                SyncHTTPRequest(url: "http://10.255.255.1:81/", method: "GET", headers: [:]),
                hardTimeout: 0.3
            )
        ) { err in
            guard case JSRuntimeError.network = err else {
                return XCTFail("期望 network 错误，实际：\(err)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0, "硬超时必须在秒级返回，不允许挂死；实际 \(elapsed)s")
    }

    // MARK: 导入能力探测（Tier B 第 5 条）

    func testImportReportsJsDegradedWithMissingMethods() throws {
        let json = """
        {
          "bookSourceUrl": "https://js-tierb.example.com",
          "bookSourceName": "TierB测试源",
          "bookSourceType": 0,
          "ruleSearch": {
            "bookList": "@js:var t = java.getVerificationCode(baseUrl); java.ajax(t)"
          }
        }
        """
        let svc = BookSourceImportService()
        let report = svc.importPayload(ImportPayload(text: json, originDescription: "测试"))

        XCTAssertEqual(report.items.count, 1)
        let item = report.items[0]
        XCTAssertEqual(item.outcome, .jsDegraded, "JS 源应按 Tier B 降级导入，而不是一刀切不支持")
        XCTAssertTrue(item.isImported, "JS 降级源必须仍可入库")
        XCTAssertTrue(item.isUsable, "Tier B：JS 降级源可用于搜索（运行到缺项才精确报错）")
        XCTAssertTrue(item.missingMethods.contains("getVerificationCode"), "缺项必须列在导入结果里")
        XCTAssertTrue(item.javaMethods.contains("ajax"))
        XCTAssertTrue(item.reason?.contains("getVerificationCode") == true, "导入提示必须精确到方法名")
        XCTAssertTrue(item.reason?.contains("仍可导入") == true, "必须告知用户源仍可运行")
        XCTAssertEqual(report.jsDegradedCount, 1)
        XCTAssertTrue(report.headline.contains("含 JS 降级 1，可运行"))
    }

    func testImportPlainSourceStillOk() throws {
        let json = """
        {
          "bookSourceUrl": "https://plain.example.com",
          "bookSourceName": "普通测试源",
          "bookSourceType": 0,
          "ruleSearch": { "bookList": "class.book" }
        }
        """
        let svc = BookSourceImportService()
        let report = svc.importPayload(ImportPayload(text: json, originDescription: "测试"))
        XCTAssertEqual(report.items.first?.outcome, .ok)
        XCTAssertEqual(report.jsDegradedCount, 0)
    }

    func testStaticScanRegistryAndRuleScan() {
        // 含已实现方法调用的规则串，直接走扫描器
        let hits = JSStaticScanner.scanRule("@js:java.ajax(baseUrl)", location: "ruleSearch.bookList")
        XCTAssertTrue(hits.contains { $0.kind == .javaMethod && $0.snippet == "java.ajax" })
        XCTAssertEqual(JSCapabilityRegistry.missing("ajax"), false)
        XCTAssertEqual(JSCapabilityRegistry.missing("getVerificationCode"), true)
    }
}
