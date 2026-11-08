import XCTest
@testable import ReaderCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// v1.2.0 质检补测（P1#16 / P1#1 / P1-12）：
/// 1. substituteBraces 嵌套规则三条路径：`{$.x}` 单括号 JSONPath、`{@css:...}` 单括号嵌套规则、
///    无 JS 运行时按 JS 解释的内容显式抛 jsUnsupported（不静默空串）。
/// 2. evaluateListSources 算子语义：`||` 首个非空胜出、`&&` 元素合并、`%%` 拼接单文本源、
///    `-` 前缀倒序、JS / 多段 / `##替换` 抛 selectorFailed。
/// 3. XPathSelector HTML 修补三条：`</td>` 补 `<tr>`、`</tr>` / `</tbody>` 补 `<table>`、
///    `<?xml` 开头走 XML 解析器。
/// 4. SourceCookieJar 按源隔离 + persist 开关（P1-12 行为固化）。
final class RuleEngineSupplementTests: XCTestCase {

    // MARK: - 嵌套规则 substituteBraces

    let booksJSON = """
    {"data":{"books":[{"id":1,"name":"三体"},{"id":2,"name":"球状闪电"}]}}
    """

    /// 单括号 `{$.x}`：嵌套 JSONPath 替换后整条规则成为 URL 字面量，按 URL 兜底返回。
    func testSingleBraceJSONPathInsideURLTemplate() throws {
        let ctx = EvalContext(source: EvalSource.detect(booksJSON))
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "https://api.test/book/{$.data.books[0].id}.html", in: ctx)
        XCTAssertEqual(out, "https://api.test/book/1.html")
    }

    /// 单括号 `{@css:...}`：嵌套选择器规则求值后拼进外层 URL。
    func testSingleBraceNestedCSSInsideURLTemplate() throws {
        let html = "<div><a href=\"book/9.html\">甲</a></div>"
        let ctx = EvalContext(source: EvalSource.detect(html))
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "https://api.test/{@css:a@href}", in: ctx)
        XCTAssertEqual(out, "https://api.test/book/9.html")
    }

    /// 双括号纯模板 `{{$.x}}` / `{{@css:...}}`：替换结果即取值本身。
    func testDoubleBracePureTemplates() throws {
        let jctx = EvalContext(source: EvalSource.detect(booksJSON))
        let ev = RuleEvaluator()
        XCTAssertEqual(try ev.evaluate(rule: "{{$.data.books[1].name}}", in: jctx), "球状闪电")

        let hctx = EvalContext(source: EvalSource.detect("<div><p>甲</p></div>"))
        XCTAssertEqual(try ev.evaluate(rule: "{{@css:p@text}}", in: hctx), "甲")
    }

    /// 无 JS 运行时时，非规则内容按 JS 解释 → 显式 jsUnsupported，绝不静默返回空串。
    func testNonRuleBraceContentThrowsJSUnsupported() {
        let ctx = EvalContext(source: EvalSource.detect("<div><p>甲</p></div>"))
        let ev = RuleEvaluator()

        // 双括号：内容既非规则（@ / $. / $[ / // 前缀，也不含规则标记）也非已声明变量 → JS
        XCTAssertThrowsError(try ev.evaluate(rule: "{{Math.max(1,2)}}", in: ctx)) { e in
            XCTAssertTrue(e is RuleEvalError, "应为 RuleEvalError，实际 \(e)")
        }
        // 单括号：@ 前缀进入嵌套求值，嵌套规则本身是 JS → 同样显式抛错
        XCTAssertThrowsError(try ev.evaluate(rule: "{@js:return 1}", in: ctx)) { e in
            XCTAssertTrue(e is RuleEvalError, "应为 RuleEvalError，实际 \(e)")
        }
    }

    // MARK: - evaluateListSources 算子（P1#1）

    let listHTML = """
    <div><ul><li class="a">甲</li><li class="a">乙</li></ul><p>丙</p></div>
    """

    func testListSourcesPlainSelector() throws {
        let ctx = EvalContext(source: EvalSource.detect(listHTML))
        let ev = RuleEvaluator()
        let srcs = try ev.evaluateListSources(rule: "li.a", in: ctx)
        XCTAssertEqual(srcs.count, 2)
        XCTAssertTrue(srcs[0].text.contains("甲"))
        XCTAssertTrue(srcs[1].text.contains("乙"))
    }

    /// `||`：逐分支求值，首个产出非空元素的分支胜出。
    func testListSourcesOrOperator() throws {
        let ctx = EvalContext(source: EvalSource.detect(listHTML))
        let ev = RuleEvaluator()

        // 首分支取空 → 回退到第二分支
        let fallback = try ev.evaluateListSources(rule: "nothing.zzz||li.a", in: ctx)
        XCTAssertEqual(fallback.count, 2)

        // 首分支命中 → 不再取后备（p 不会并入）
        let firstWins = try ev.evaluateListSources(rule: "li.a||p", in: ctx)
        XCTAssertEqual(firstWins.count, 2)
        XCTAssertTrue(firstWins.allSatisfy { $0.text.contains("<li") })
    }

    /// `&&`：两侧元素合并。
    func testListSourcesAndOperator() throws {
        let ctx = EvalContext(source: EvalSource.detect(listHTML))
        let ev = RuleEvaluator()
        let merged = try ev.evaluateListSources(rule: "li.a&&p", in: ctx)
        XCTAssertEqual(merged.count, 3, "2 个 li + 1 个 p")
        XCTAssertTrue(merged[2].text.contains("丙"))
    }

    /// `%%`：各段按字符串求值后直接拼接（段间无分隔符），结果是单个文本源。
    func testListSourcesConcatOperator() throws {
        let html = "<div><p id=\"t1\">甲</p><p id=\"t2\">乙</p></div>"
        let ctx = EvalContext(source: EvalSource.detect(html))
        let ev = RuleEvaluator()
        let srcs = try ev.evaluateListSources(rule: "@css:#t1@text%%@css:#t2@text", in: ctx)
        XCTAssertEqual(srcs.count, 1, "%% 语义必然是单个文本源")
        XCTAssertEqual(srcs[0].text, "甲乙")
    }

    /// `-` 前缀：元素倒序。
    func testListSourcesReversePrefix() throws {
        let ctx = EvalContext(source: EvalSource.detect(listHTML))
        let ev = RuleEvaluator()
        let srcs = try ev.evaluateListSources(rule: "-li.a", in: ctx)
        XCTAssertEqual(srcs.count, 2)
        XCTAssertTrue(srcs[0].text.contains("乙"))
        XCTAssertTrue(srcs[1].text.contains("甲"))
    }

    /// JS / `##替换` 形态无法产出可逐项求值的元素 → 显式 selectorFailed（不静默退文本）。
    func testListSourcesThrowsOnJSAndReplacement() {
        let ctx = EvalContext(source: EvalSource.detect(listHTML))
        let ev = RuleEvaluator()

        XCTAssertThrowsError(try ev.evaluateListSources(rule: "<js>return 1</js>", in: ctx)) { e in
            guard case RuleEvalError.selectorFailed = e else {
                return XCTFail("JS 列表规则应抛 selectorFailed，实际 \(e)")
            }
        }
        XCTAssertThrowsError(
            try ev.evaluateListSources(rule: "li.a@text##甲##丙", in: ctx)
        ) { e in
            guard case RuleEvalError.selectorFailed = e else {
                return XCTFail("含 ##替换 的列表规则应抛 selectorFailed，实际 \(e)")
            }
        }
    }

    // MARK: - XPath HTML 修补三条（架构文档二·四）

    /// `</td>` 结尾 → 补 `<tr>`：未闭合表格片段仍可查。
    func testXPathPatchUnterminatedTable() throws {
        let out = try XPathSelector.evaluate(
            rule: "//td", html: "<table><tr><td>甲</td><td>乙</td>", isList: true
        )
        XCTAssertEqual(out, ["甲", "乙"])
    }

    /// `</tr>` 结尾 → 追加 `<table>`（尾部补上下文，不回包裹开头）。
    func testXPathPatchBareTR() throws {
        XCTAssertEqual(
            XPathSelector.patch("<tr><td>甲</td><td>乙</td></tr>"),
            "<tr><td>甲</td><td>乙</td></tr><table>",
            "</tr> 结尾应追加 <table>"
        )
        // 带 <table> 开头的闭合片段：尾部追加不干扰既有表格树
        let out = try XPathSelector.evaluate(
            rule: "//tr/td", html: "<table><tr><td>甲</td><td>乙</td></tr>", isList: true
        )
        XCTAssertEqual(out, ["甲", "乙"])
        // 已知边界：裸 <tr> 片段无表上下文，HTML 建树丢弃行标签 → 取空（patch 追加在尾部，不回包裹）
        let bare = try XPathSelector.evaluate(
            rule: "//tr/td", html: "<tr><td>甲</td><td>乙</td></tr>", isList: true
        )
        XCTAssertEqual(bare, [], "裸 tr 片段为既有行为的已知边界")
    }

    /// `</tbody>` 结尾 → 同样追加 `<table>`。
    func testXPathPatchBareTbody() throws {
        XCTAssertEqual(
            XPathSelector.patch("<tbody><tr><td>甲</td></tr></tbody>"),
            "<tbody><tr><td>甲</td></tr></tbody><table>",
            "</tbody> 结尾应追加 <table>"
        )
        let out = try XPathSelector.evaluate(
            rule: "//tr/td", html: "<table><tbody><tr><td>甲</td></tr></tbody>", isList: true
        )
        XCTAssertEqual(out, ["甲"])
    }

    /// `<?xml` 开头 → 走 XML 解析器（大小写敏感的 XML 文档）。
    func testXPathXMLDocumentUsesXMLParser() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><root><book><title>甲</title></book></root>"
        let out = try XPathSelector.evaluate(rule: "//book/title", html: xml, isList: true)
        XCTAssertEqual(out, ["甲"])
    }

    /// XPath 属性取值 `//a/@href`。
    func testXPathAttributeExtraction() throws {
        let out = try XPathSelector.evaluate(
            rule: "//a/@href", html: "<div><a href=\"/x/1\">甲</a></div>", isList: true
        )
        XCTAssertEqual(out, ["/x/1"])
    }

    // MARK: - SourceCookieJar（P1-12 行为固化）

    private func makeJar(defaults: UserDefaults? = nil) -> SourceCookieJar {
        SourceCookieJar(defaults: defaults, keyPrefix: "td.tests.sourceCookies")
    }

    func testCookieJarStoreAndHeaderRoundTrip() throws {
        let jar = makeJar()
        let url = try XCTUnwrap(URL(string: "https://www.example.com/a"))
        jar.store(responseHeaders: ["Set-Cookie": "sid=1; path=/"],
                  url: url, sourceKey: "s1", persist: false)
        XCTAssertEqual(jar.count(sourceKey: "s1"), 1)
        XCTAssertEqual(jar.cookieHeader(sourceKey: "s1", url: url), "sid=1")
    }

    /// 按源隔离：s1 的 Cookie 绝不会发给 s2。
    func testCookieJarIsolationBetweenSources() throws {
        let jar = makeJar()
        let url = try XCTUnwrap(URL(string: "https://www.example.com/a"))
        jar.store(responseHeaders: ["Set-Cookie": "sid=1; path=/"],
                  url: url, sourceKey: "s1", persist: false)
        XCTAssertNil(jar.cookieHeader(sourceKey: "s2", url: url), "跨源不得带 Cookie")
        XCTAssertEqual(jar.count(sourceKey: "s2"), 0)
        jar.clear(sourceKey: "s1")
        XCTAssertNil(jar.cookieHeader(sourceKey: "s1", url: url))
    }

    /// persist 开关：false = 会话级（不落盘），true = 落盘且新实例可恢复。
    func testCookieJarPersistToggle() throws {
        let suite = "TingDuTests.CookieJar"
        // corelibs（Linux）与 Darwin 的移除域标签不同
        #if canImport(FoundationNetworking)
        UserDefaults().removePersistentDomain(forName: suite)
        #else
        UserDefaults().removePersistentDomain(forSuiteName: suite)
        #endif
        let defaults = UserDefaults(suiteName: suite)
        XCTAssertNotNil(defaults)

        let url = try XCTUnwrap(URL(string: "https://www.example.com/a"))
        let headers = ["Set-Cookie": "sid=1; path=/"]

        let sessionJar = makeJar(defaults: defaults)
        sessionJar.store(responseHeaders: headers, url: url, sourceKey: "tmp", persist: false)
        XCTAssertEqual(makeJar(defaults: defaults).count(sourceKey: "tmp"), 0, "persist=false 不落盘")

        let persistJar = makeJar(defaults: defaults)
        persistJar.store(responseHeaders: headers, url: url, sourceKey: "keep", persist: true)
        let restored = makeJar(defaults: defaults)
        XCTAssertEqual(restored.count(sourceKey: "keep"), 1, "persist=true 落盘可恢复")
        XCTAssertEqual(restored.cookieHeader(sourceKey: "keep", url: url), "sid=1")
    }

    /// RFC6265 简化匹配：域 / 子域通配 / 路径前缀 / 过期。
    func testCookieJarMatchesSemantics() throws {
        func cookie(domain: String, path: String = "/",
                    expires: Date? = nil) throws -> HTTPCookie {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: "a", .value: "1", .domain: domain, .path: path,
            ]
            if let expires { props[.expires] = expires }
            return try XCTUnwrap(HTTPCookie(properties: props))
        }
        // 子域通配：.example.com 匹配本域与子域，不匹配其它域
        let wildcard = try cookie(domain: ".example.com")
        XCTAssertTrue(SourceCookieJar.matches(wildcard, host: "example.com", path: "/"))
        XCTAssertTrue(SourceCookieJar.matches(wildcard, host: "a.example.com", path: "/"))
        XCTAssertFalse(SourceCookieJar.matches(wildcard, host: "example.org", path: "/"))

        // host-only：不带点前缀只精确匹配本域
        let hostOnly = try cookie(domain: "example.com")
        XCTAssertTrue(SourceCookieJar.matches(hostOnly, host: "example.com", path: "/"))
        XCTAssertFalse(SourceCookieJar.matches(hostOnly, host: "a.example.com", path: "/"))

        // 路径前缀
        let scoped = try cookie(domain: ".example.com", path: "/book")
        XCTAssertTrue(SourceCookieJar.matches(scoped, host: "example.com", path: "/book/1"))
        XCTAssertFalse(SourceCookieJar.matches(scoped, host: "example.com", path: "/other"))

        // 过期 = 不匹配
        let expired = try cookie(domain: ".example.com", expires: Date(timeIntervalSinceNow: -10))
        XCTAssertFalse(SourceCookieJar.matches(expired, host: "example.com", path: "/"))
    }
}
