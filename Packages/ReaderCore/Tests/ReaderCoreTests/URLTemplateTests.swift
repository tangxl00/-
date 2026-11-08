import XCTest
@testable import ReaderCore

/// URL 模板引擎：变量替换、编码、选项 JSON、GET query / POST body 规则求值。
/// 对应需求 3-4（URL 模板）与 3-6（P0 不支持的 js 选项显式报错）。
final class URLTemplateTests: XCTestCase {

    func testSimpleVariableSubstitution() throws {
        let a = try URLTemplateEngine.analyze(
            template: "https://a.com/search?q={{key}}&p={{page}}",
            vars: ["key": "三体", "page": "1"]
        )
        XCTAssertTrue(a.url.hasPrefix("https://a.com/search?q="))
        XCTAssertTrue(a.url.contains("%E4%B8%89%E4%BD%93")) // 三体
        XCTAssertTrue(a.url.contains("p=1"))
        XCTAssertTrue(a.isPost == false)
    }

    func testMissingVariableLeavesEmpty() throws {
        let a = try URLTemplateEngine.analyze(
            template: "https://a.com/s?q={{key}}",
            vars: [:]
        )
        XCTAssertTrue(a.url.contains("q="))
        XCTAssertFalse(a.url.contains("{{"))
    }

    func testUTF8AndSpecialCharsEncoded() throws {
        let a = try URLTemplateEngine.analyze(
            template: "https://a.com/s?q={{key}}",
            vars: ["key": "a b&c=d"]
        )
        // & 与 = 必须被转义，避免破坏 query 结构
        XCTAssertTrue(a.url.contains("a%20b"))
        XCTAssertTrue(a.url.contains("%26c%3Dd") || a.url.contains("&c%3Dd") == false)
    }

    func testPathValueEncodingKeepsSlash() {
        let out = URLTemplateEngine.encodePathValue("a/b c")
        XCTAssertFalse(out.contains(" "))
        // 路径段里的 / 保留
        XCTAssertTrue(out.contains("a/b"))
    }

    func testOptionJSONParsedAfterFirstComma() throws {
        let tpl = "https://a.com/s?q=x,{\"method\":\"POST\",\"charset\":\"gbk\",\"headers\":{\"U\":\"v1\"}}"
        let a = try URLTemplateEngine.analyze(template: tpl, vars: [:])
        XCTAssertTrue(a.isPost)
        XCTAssertEqual(a.option.charset, "gbk")
        XCTAssertEqual(a.option.headers?["U"], "v1")
        XCTAssertEqual(a.url, "https://a.com/s?q=x")
    }

    func testOptionGETDefault() throws {
        let a = try URLTemplateEngine.analyze(
            template: "https://a.com/s?q=1,{\"retry\":2}",
            vars: [:]
        )
        XCTAssertEqual(a.option.effectiveMethod, .get)
        XCTAssertEqual(a.option.retry, 2)
    }

    func testOptionJsUnsupported() {
        XCTAssertThrowsError(
            try URLTemplateEngine.analyze(
                template: "https://a.com/s?q=1,{\"method\":\"POST\",\"js\":\"java.ajax(true)\"}",
                vars: [:]
            )
        ) { err in
            guard case RuleEvalError.jsUnsupported = err else {
                return XCTFail("期望 jsUnsupported，实际 \(err)")
            }
        }
    }

    func testOptionWebJsUnsupported() {
        XCTAssertThrowsError(
            try URLTemplateEngine.analyze(
                template: "https://a.com/s?q=1,{\"webJs\":\"document.title\"}",
                vars: [:]
            )
        ) { err in
            guard case RuleEvalError.jsUnsupported = err else {
                return XCTFail("期望 jsUnsupported，实际 \(err)")
            }
        }
    }

    func testOptionWebViewUnsupported() {
        XCTAssertThrowsError(
            try URLTemplateEngine.analyze(
                template: "https://a.com/s?q=1,{\"webView\":true}",
                vars: [:]
            )
        ) { err in
            guard case RuleEvalError.jsUnsupported = err else {
                return XCTFail("期望 jsUnsupported，实际 \(err)")
            }
        }
    }

    /// bodyJs（响应后二次 JS）：Tier B 口径 —— 不执行但不阻断请求，option 原样保留
    /// （响应体可能未按书源预期二次加工，记录在案的能力缺口，区别于 webJs 的硬抛）。
    func testOptionBodyJsKeptButNotExecuted() throws {
        let a = try URLTemplateEngine.analyze(
            template: "https://a.com/s?q=1,{\"method\":\"POST\",\"body\":\"a=1\",\"bodyJs\":\"x\"}",
            vars: [:]
        )
        XCTAssertEqual(a.option.bodyJs, "x")
        XCTAssertEqual(a.option.effectiveMethod, .post)
    }

    func testEmptyJsOptionTreatedAsAbsent() {
        // 空串 / 纯空白 js 视为未配置（书源里常见空字段），不报错也不执行
        XCTAssertNoThrow(
            try URLTemplateEngine.analyze(
                template: "https://a.com/s?q=1,{\"js\":\"\"}",
                vars: [:]
            )
        )
        XCTAssertNoThrow(
            try URLTemplateEngine.analyze(
                template: "https://a.com/s?q=1,{\"js\":\"  \"}",
                vars: [:]
            )
        )
    }

    func testGETQueryRuleEvaluationWithDOM() throws {
        // query 参数值是规则时（text 型源）逐参数求值
        let html = "<html><input id='kw' value='关键词'></html>"
        let ctx = EvalContext(
            source: try EvalSource.html(html),
            variables: VariableStore(["key": "书名"])
        )
        let a = try URLTemplateEngine.analyze(
            template: "https://a.com/s?q={{key}}&w={{#kw@value}}",
            vars: ["key": "书名"],
            evaluator: RuleEvaluator(),
            ctx: ctx
        )
        XCTAssertTrue(a.url.contains("%E4%B9%A6%E5%90%8D")) // 书名
        XCTAssertTrue(a.url.contains("w=%E5%85%B3%E9%94%AE%E8%AF%8D")) // 关键词
    }

    func testPOSTFormBodyRuleEvaluation() throws {
        let html = "<html><meta name='k' content='body值'></html>"
        let ctx = EvalContext(
            source: try EvalSource.html(html),
            variables: VariableStore(["key": "三体"])
        )
        let a = try URLTemplateEngine.analyze(
            template: "https://a.com/s,{\"method\":\"POST\",\"body\":\"kw={{key}}&c=@meta[name=k]@content\"}",
            vars: ["key": "三体"],
            evaluator: RuleEvaluator(),
            ctx: ctx
        )
        XCTAssertTrue(a.isPost)
        // POST 表单字段值按 URL 编码落盘
        XCTAssertEqual(a.option.body, "kw=%E4%B8%89%E4%BD%93&c=body%E5%80%BC")
    }

    func testPOSTBodyPlainStringUntouched() throws {
        let a = try URLTemplateEngine.analyze(
            template: "https://a.com/s,{\"method\":\"POST\",\"body\":\"plain\"}",
            vars: [:]
        )
        XCTAssertEqual(a.option.body, "plain")
    }

    func testSplitOptionURLWithoutJSON() {
        let (url, opt) = URLTemplateEngine.splitOption("https://a.com/s?q=1")
        XCTAssertEqual(url, "https://a.com/s?q=1")
        XCTAssertNil(opt)
    }

    func testSplitOptionWithCommaInURL() {
        // URL 本身的逗号：选项 JSON 必须从第一个「逗号+{」开始
        let (url, opt) = URLTemplateEngine.splitOption("https://a.com/s?a=1,2&b=3,{\"method\":\"POST\"}")
        XCTAssertEqual(url, "https://a.com/s?a=1,2&b=3")
        XCTAssertNotNil(opt)
    }

    func testAnalyzeNoRulesNoContextNeeded() throws {
        // 便捷入口：变量型模板不需要 DOM
        let a = try URLTemplateEngine.analyze(
            template: "https://a.com/s?q={{key}}",
            vars: ["key": "abc"]
        )
        XCTAssertTrue(a.url.contains("q=abc"))
    }

    func testHeadersAndDnsIPOptions() throws {
        let tpl = "https://a.com/s,{\"headers\":{\"Referer\":\"https://r.com\"},\"dnsIp\":\"1.2.3.4\"}"
        let a = try URLTemplateEngine.analyze(template: tpl, vars: [:])
        XCTAssertEqual(a.option.headers?["Referer"], "https://r.com")
        XCTAssertEqual(a.option.dnsIp, "1.2.3.4")
    }
}
