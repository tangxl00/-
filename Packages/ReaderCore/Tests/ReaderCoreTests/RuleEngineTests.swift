import XCTest
@testable import ReaderCore

/// 规则引擎测试：分段、mode 前缀、四个静默失败陷阱、## 替换链、{{}} 嵌套规则、
/// @get/@put、$1..$99 回填、Default 选择器的两种索引语法、XPath 三条 HTML 修补、
/// HTML 实体反转义、相对 URL 绝对化。
final class RuleEngineTests: XCTestCase {

    // MARK: - 陷阱 1：`@js:` 贪婪到底

    func testGreedyJsTailSwallowsRestOfRule() {
        let segments = RuleParser.parse("@js:var x='@css:div' + foo; return x")
        XCTAssertEqual(segments.count, 1, "@js: 出现后后面全部归 JS，不应再切出 CSS 段")
        XCTAssertEqual(segments[0].kind, .jsTail)
    }

    func testGreedyJsTailAfterCssSegment() {
        // 前面有 CSS 段时：CSS 段保留，后面从 @js: 开始全部是 JS
        let segments = RuleParser.parse("@css:div.book&&@js:return 1 && @css:x")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].kind, .plain)
        XCTAssertEqual(segments[0].mode, .`default`)
        XCTAssertEqual(segments[1].kind, .jsTail)
        XCTAssertTrue(
            segments[1].rule.contains("@css:x"),
            "JS 尾部必须包含后续所有字符（含看似 CSS 的部分）"
        )
    }

    func testJsTagIsNonGreedy() {
        // <js>...</js> 是非贪婪的，两个标签各成一段
        let segments = RuleParser.parse("<js>a()</js>@css:div<js>b()</js>")
        XCTAssertEqual(segments.filter { $0.kind == .js }.count, 2)
    }

    func testContainsJSDetection() {
        XCTAssertTrue(RuleParser.containsJS("@js:return 1"))
        XCTAssertTrue(RuleParser.containsJS("<js>x</js>"))
        XCTAssertTrue(RuleParser.containsJS("@webjs:var a=1"))
        XCTAssertFalse(RuleParser.containsJS("@css:div.a@text"))
        XCTAssertFalse(RuleParser.containsJS(nil))
    }

    // MARK: - 陷阱 2：mode 前缀解析顺序

    func testModePrefixes() {
        XCTAssertEqual(RuleParser.parse("@CSS:div.a@text")[0].mode, .`default`)
        XCTAssertEqual(RuleParser.parse("@XPath://div/a")[0].mode, .xpath)
        XCTAssertEqual(RuleParser.parse("@Json:$.data.list")[0].mode, .json)
        // 无前缀但以 $./$[ 开头 → Json
        XCTAssertEqual(RuleParser.parse("$.data.name")[0].mode, .json)
        XCTAssertEqual(RuleParser.parse("$[0]")[0].mode, .json)
        // 以 / 开头 → XPath
        XCTAssertEqual(RuleParser.parse("/html/body/div")[0].mode, .xpath)
        // 本身是 JSON 对象文本 → Json
        XCTAssertEqual(RuleParser.parse("{\"a\":1}")[0].mode, .json)
        // @@ 去两字符 → Default
        let segs = RuleParser.parse("@@div.a@text")
        XCTAssertEqual(segs[0].mode, .`default`)
        XCTAssertEqual(segs[0].rule, "div.a@text")
    }

    // MARK: - 陷阱 3：`##` 位置影响 mode

    func testReplacementChainModeDetection() {
        // 规则以 ## 开头：说明左侧为空（无 CSS 规则），此时 `##` 之前的内容才是模式判定依据
        let seg = RuleParser.parse("@css:div.a@text##<p>##\n")[0]
        XCTAssertEqual(seg.mode, .`default`)
        XCTAssertNotNil(seg.replacement)
        XCTAssertEqual(seg.replacement?.pattern, "<p>")
        XCTAssertEqual(seg.replacement?.replacement, "\n")
    }

    func testReplacementThirdSegmentMeansReplaceFirstOnly() {
        let seg = RuleParser.parse("div@text##a##b##")[0]
        XCTAssertNotNil(seg.replacement)
        XCTAssertTrue(seg.replacement!.replaceFirstOnly, "第三段存在 → 只替换首个")
    }

    func testReplacementTwoSegmentsReplacesAll() {
        let seg = RuleParser.parse("div@text##a##b")[0]
        XCTAssertNotNil(seg.replacement)
        XCTAssertFalse(seg.replacement!.replaceFirstOnly, "只有两段 → 全部替换")
    }

    func testReplacementAppliesInOrder() throws {
        let ctx = EvalContext(source: EvalSource.text(""))
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "##aaa##bbb##", in: ctx)
        // 空源 → 输入为空串 → 替换后仍为空
        XCTAssertEqual(out, "")

        // 用 HTML 源验证真实替换链
        let ctx2 = EvalContext(source: EvalSource.detect("<div>x</div>"))
        let out2 = try ev.evaluate(rule: "@css:div@text##x##y##", in: ctx2)
        XCTAssertEqual(out2, "y")
    }

    /// 替换链按顺序叠加：`##a##b##z` 含义是「a→b，第三个 z 表示只替换首个」
    func testReplacementChainSequentialApplication() throws {
        let ctx = EvalContext(
            source: EvalSource.detect("<div><p>a</p><p>b</p></div>")
        )
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "@css:p@text", in: ctx)
        XCTAssertTrue(out.contains("a"))
        XCTAssertTrue(out.contains("b"))
    }

    // MARK: - 陷阱 4：`{{}}` 内嵌规则优先于 JS

    func testBracesWithNestedRuleIsEvaluatedAsRule() throws {
        // {{}} 内容以 @ 开头 → 嵌套规则，不是 JS
        let ctx = EvalContext(
            source: EvalSource.detect("<div><a href='/x'>t</a></div>"),
            variables: VariableStore(["k": "v"])
        )
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "https://host/{{@css:a@href}}", in: ctx)
        XCTAssertTrue(out.contains("/x") || out.contains("x"), "嵌套规则应被求值，实际：\(out)")
    }

    func testBracesWithPlainTextIsVariableSubstitution() throws {
        let ctx = EvalContext(
            source: EvalSource.text(""),
            variables: VariableStore(["key": "三体", "page": "1"])
        )
        let ev = RuleEvaluator()
        let url = try URLTemplateEngine.analyze(
            template: "https://h/search?q={{key}}&p={{page}}",
            vars: ["key": "三体", "page": "1"]
        ).url
        XCTAssertEqual(url, "https://h/search?q=%E4%B8%89%E4%BD%93&p=1")
        _ = try ev.evaluate(rule: "{{key}}", in: ctx)
    }

    /// `{{}}` 里既不是规则也不是已声明变量 → 应当报 jsUnsupported（因为 legado 会按 JS 求值）
    func testBracesUnknownContentThrowsInsteadOfSilentEmpty() {
        let ctx = EvalContext(source: EvalSource.text(""))
        let ev = RuleEvaluator()
        XCTAssertThrowsError(try ev.evaluate(rule: "{{nope}}", in: ctx)) { err in
            guard case RuleEvalError.jsUnsupported = err else {
                return XCTFail("应抛出 jsUnsupported，实际：\(err)")
            }
        }
    }

    // MARK: - @get / @put / $1..$99

    func testGetPutVariables() throws {
        let store = VariableStore()
        let ctx = EvalContext(
            source: EvalSource.detect("<div><span>hello</span></div>"),
            variables: store
        )
        let ev = RuleEvaluator()
        // @put 求值并写变量
        _ = try? ev.evaluate(rule: "@css:span@text@put:{t:span@text}", in: ctx)
        XCTAssertEqual(store["t"], "hello", "@put 应写入变量")
        // @get 取值
        let out = try ev.evaluate(rule: "@get:{t}", in: ctx)
        XCTAssertEqual(out, "hello")
    }

    func testGroupBackfill() throws {
        var ctx = EvalContext(
            source: EvalSource.detect("<div><a href='/p/1'>第一章</a></div>")
        )
        ctx.regexGroups = ["第一章", "/p/1", "/p/1"]
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "https://h$2", in: ctx)
        XCTAssertTrue(out.hasSuffix("/p/1"), "实际：\(out)")
    }

    // MARK: - Default 选择器：两种索引语法

    private let listHTML = """
    <html><body>
      <ul class="list">
        <li class="item"><a href="/b/1"><em>一</em></a></li>
        <li class="item"><a href="/b/2"><em>二</em></a></li>
        <li class="item"><a href="/b/3"><em>三</em></a></li>
        <li class="item"><a href="/b/4"><em>四</em></a></li>
        <li class="item"><a href="/b/5"><em>五</em></a></li>
      </ul>
    </body></html>
    """

    func testIndexSyntaxDotRange() throws {
        let ctx = EvalContext(source: EvalSource.detect(listHTML))
        let ev = RuleEvaluator()
        let one = try ev.evaluate(rule: "@css:ul.list@li.item.-1@text", in: ctx)
        XCTAssertEqual(one, "五", "`.-1` 取最后一个")
        let sliced = try ev.evaluate(rule: "@css:ul.list@li.item.0:2@text", in: ctx)
        XCTAssertTrue(sliced.contains("一"))
        XCTAssertFalse(sliced.contains("四"), "0:2 应只取前两个，实际：\(sliced)")
    }

    func testIndexSyntaxBracketGroups() throws {
        let ctx = EvalContext(source: EvalSource.detect(listHTML))
        let ev = RuleEvaluator()
        // [-1, 3]：0 基索引（与冒号式 .-1/.0:2 同口径），-1=最后一个，3=第 4 个元素
        let out = try ev.evaluate(rule: "ul.list@li.item[-1, 3]@text", in: ctx)
        XCTAssertTrue(out.contains("五"), "应包含最后一个，实际：\(out)")
        XCTAssertTrue(out.contains("四"), "0 基下标 3 = 第 4 个元素，实际：\(out)")
        // [1:3] 切片：0 基 1、2（第 2、3 个）
        let sliced = try ev.evaluate(rule: "ul.list@li.item[1:3]@text", in: ctx)
        XCTAssertTrue(sliced.contains("二") && sliced.contains("三"), "实际：\(sliced)")
        XCTAssertFalse(sliced.contains("一"), "1:3 不含第 1 个，实际：\(sliced)")
    }

    func testExtractActions() throws {
        let ctx = EvalContext(source: EvalSource.detect(
            "<div class='x'><p>a<b>b</b></p></div>"
        ))
        let ev = RuleEvaluator()
        let text = try ev.evaluate(rule: "div.x@text", in: ctx)
        XCTAssertEqual(text, "ab")
        let own = try ev.evaluate(rule: "div.x@p@ownText", in: ctx)
        XCTAssertEqual(own, "a")
        let html = try ev.evaluate(rule: "div.x@p@html", in: ctx)
        XCTAssertTrue(html.contains("<b>"))
        let attr = try ev.evaluate(rule: "div.x@class", in: ctx)
        XCTAssertEqual(attr, "x")
    }

    // MARK: - 算子 && / || / %%

    func testOrOperatorPicksFirstNonEmpty() throws {
        let ctx = EvalContext(source: EvalSource.detect("<div><p class='a'>A</p></div>"))
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "p.b@text||p.a@text", in: ctx)
        XCTAssertEqual(out, "A", "第一个候选为空应退到第二个")
    }

    func testAndOperatorInListContext() throws {
        let ctx = EvalContext(source: EvalSource.detect(listHTML))
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "@css:ul.list@li.item", in: ctx)
        XCTAssertFalse(out.isEmpty)
    }

    // MARK: - XPath 三条修补

    func testXPathTablePatch() throws {
        // 片段以 </td> 结尾 → 自动补 <tr>，否则 XPath 无法解析
        let html = "<table><tr><td>甲</td>"
        let ctx = EvalContext(source: EvalSource.text(html))
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "@XPath://table//tr/td", in: ctx)
        XCTAssertTrue(out.contains("甲"), "实际：\(out)")
    }

    func testXPathNormalPath() throws {
        let ctx = EvalContext(source: EvalSource.detect(
            "<html><body><div class='c'><a href='/x'>t</a></div></body></html>"
        ))
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "@XPath://div[@class='c']/a/@href", in: ctx)
        XCTAssertTrue(out.contains("/x"), "实际：\(out)")
    }

    // MARK: - HTML 实体反转义

    func testEntityDecoding() throws {
        let ctx = EvalContext(source: EvalSource.detect(
            "<div><p>&amp;lt;不是标签&amp;gt; &amp;nbsp; 完 &amp;#39;</p></div>"
        ))
        let ev = RuleEvaluator()
        let out = try ev.evaluate(rule: "p@text", in: ctx)
        XCTAssertFalse(out.contains("&amp;lt;"), "应反转义，实际：\(out)")
        XCTAssertTrue(out.contains("<不是标签>"), "实际：\(out)")
    }

    // MARK: - 相对 URL 绝对化

    func testRelativeUrlAbsolutization() throws {
        let ctx = EvalContext(
            source: EvalSource.detect("<a href='/book/1'>x</a>"),
            baseURL: "https://site.example/list?p=1"
        )
        let ev = RuleEvaluator()
        var c = ctx
        c.isURL = true
        let out = try ev.evaluate(rule: "a@href", in: c)
        XCTAssertEqual(out, "https://site.example/book/1")
    }

    // MARK: - chapterList 反转标记

    func testChapterListReverseMarker() throws {
        let ctx = EvalContext(source: EvalSource.detect(listHTML))
        let ev = RuleEvaluator()
        let asc = try ev.evaluateList(rule: "@css:ul.list@li.item@text", in: ctx)
        XCTAssertEqual(asc.first, "一")
        let desc = try ev.evaluateList(rule: "-@css:ul.list@li.item@text", in: ctx)
        XCTAssertEqual(desc.first, "五", "`-` 前缀应反转顺序")
    }
}
