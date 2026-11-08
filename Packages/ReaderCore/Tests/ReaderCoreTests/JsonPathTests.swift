import XCTest
@testable import ReaderCore

/// JSONPath 求值 + JsonValue 基础行为。
/// 对应需求 3-3（JSON 书源解析）与自测标准 JsonPath 引擎。
final class JsonPathTests: XCTestCase {

    let storeJSON = """
    {"code":0,"data":{"books":[
      {"name":"三体","author":"刘慈欣","tags":["科幻","雨果奖"],"stat":{"views":1200,"score":9.4}},
      {"name":"球状闪电","author":"刘慈欣","tags":["科幻"],"stat":{"views":800,"score":8.9}}
    ]},"ok":true}
    """

    var root: JsonValue { JsonValue.parse(storeJSON)! }

    func testChildAccess() throws {
        let v = try JsonPath.query("$.code", on: root)
        XCTAssertEqual(v.first?.text, "0")
        XCTAssertEqual(JsonPath.firstString("$.ok", on: root), "true")
    }

    func testNestedChildAccess() {
        XCTAssertEqual(JsonPath.firstString("$.data.books[0].name", on: root), "三体")
        XCTAssertEqual(JsonPath.firstString("$.data.books[1].stat.score", on: root), "8.9")
    }

    func testIndexNegativeAndOutOfBounds() throws {
        let last = try JsonPath.query("$.data.books[-1].name", on: root)
        XCTAssertEqual(last.first?.text, "球状闪电")
        let oob = try JsonPath.query("$.data.books[5]", on: root)
        XCTAssertTrue(oob.isEmpty)
    }

    func testMultipleIndexSelect() throws {
        let both = try JsonPath.query("$.data.books[0,1].author", on: root)
        XCTAssertEqual(both.map(\.text), ["刘慈欣", "刘慈欣"])
    }

    func testWildcardOnArray() throws {
        let names = try JsonPath.query("$.data.books[*].name", on: root)
        XCTAssertEqual(names.map(\.text), ["三体", "球状闪电"])
    }

    func testSliceSyntax() throws {
        let first = try JsonPath.query("$.data.books[0:1].name", on: root)
        XCTAssertEqual(first.map(\.text), ["三体"])
        let step = try JsonPath.query("$.data.books[0:2:2].name", on: root)
        XCTAssertEqual(step.map(\.text), ["三体"])
    }

    func testRecursiveDescent() throws {
        // $..name 递归下钻
        let names = try JsonPath.query("$..name", on: root)
        XCTAssertEqual(names.map(\.text).sorted(), ["三体", "球状闪电"])
        // $..score
        let scores = try JsonPath.query("$..score", on: root)
        XCTAssertEqual(Set(scores.map(\.text)), ["9.4", "8.9"])
    }

    func testFilterEquality() throws {
        let hit = try JsonPath.query("$.data.books[?(@.name == '三体')].stat.views", on: root)
        XCTAssertEqual(hit.first?.text, "1200")
    }

    func testFilterComparison() throws {
        let hit = try JsonPath.query("$.data.books[?(@.stat.views > 1000)].name", on: root)
        XCTAssertEqual(hit.map(\.text), ["三体"])
    }

    func testFilterExists() throws {
        let hit = try JsonPath.query("$.data.books[?(@.tags)].name", on: root)
        XCTAssertEqual(hit.count, 2)
    }

    func testMissingPathReturnsEmptyNotCrash() {
        XCTAssertEqual(JsonPath.firstString("$.nope.nope", on: root), "")
        XCTAssertEqual(JsonPath.firstString("$.data.books.name", on: root), "") // 数组上的子键
    }

    func testQueryOnScalarAndNull() throws {
        let scalar = JsonValue.string("x")
        XCTAssertTrue(try JsonPath.query("$.a", on: scalar).isEmpty)
        XCTAssertTrue(try JsonPath.query("$[0]", on: JsonValue.null).isEmpty)
    }

    func testArrayRoot() throws {
        let arr = JsonValue.parse("[{\"t\":\"a\"},{\"t\":\"b\"}]")!
        XCTAssertEqual(try JsonPath.query("$[1].t", on: arr).first?.text, "b")
        // 子键访问只作用于对象；数组根上的 $.t 为空（要遍历得用 $[*].t）
        XCTAssertTrue(try JsonPath.query("$.t", on: arr).isEmpty)
        XCTAssertEqual(try JsonPath.query("$[*].t", on: arr).map(\.text), ["a", "b"])
    }

    func testFirstStringNumberFormatting() {
        // 整数走 Int64 展示（不带小数点）
        let j = JsonValue.parse("{\"n\":3,\"m\":3.5,\"big\":1e16}")!
        XCTAssertEqual(JsonPath.firstString("$.n", on: j), "3")
        XCTAssertEqual(JsonPath.firstString("$.m", on: j), "3.5")
        XCTAssertEqual(JsonPath.firstString("$.big", on: j), "1e+16")
    }

    func testFirstStringOnObjectYieldsCompactJSON() {
        let j = JsonValue.parse("{\"o\":{\"b\":1,\"a\":2}}")!
        let s = JsonPath.firstString("$.o", on: j)
        XCTAssertTrue(s.contains("\"a\":2"))
        XCTAssertTrue(s.contains("\"b\":1"))
    }

    func testParseInvalidReturnsNil() {
        XCTAssertNil(JsonValue.parse("not json"))
        XCTAssertNil(JsonValue.parse(""))
        XCTAssertNil(JsonValue.parse("{\"a\":}"))
    }

    func testParseFragmentsAllowed() {
        XCTAssertEqual(JsonValue.parse("42")?.text, "42")
        XCTAssertEqual(JsonValue.parse("\"hi\"")?.text, "hi")
    }

    func testFromBridge() {
        XCTAssertEqual(JsonValue.from(true).text, "true")
        XCTAssertEqual(JsonValue.from(7).text, "7")
        XCTAssertEqual(JsonValue.from("s").text, "s")
        XCTAssertEqual(JsonValue.from([1, 2]).flattened.map(\.text), ["1", "2"])
        // NSNumber 桥接下 true 不能变成数字 1
        if case .bool = JsonValue.from(true) {} else { XCTFail("bool 被误判为 number") }
        if case .bool = JsonValue.from(NSNumber(value: 1)) { XCTFail("数字 1 被误判为 bool") }
    }

    func testFlattened() {
        XCTAssertEqual(JsonValue.array([.string("a")]).flattened.count, 1)
        XCTAssertEqual(JsonValue.string("a").flattened.count, 1)
        XCTAssertEqual(JsonValue.null.flattened.count, 0)
    }

    func testEscapedUnicodeAndChineseKeys() throws {
        let j = JsonValue.parse("{\"书名\":\"三体\",\"嵌套\":{\"标题\":\"黑暗森林\"}}")!
        XCTAssertEqual(JsonPath.firstString("$.书名", on: j), "三体")
        XCTAssertEqual(JsonPath.firstString("$.嵌套.标题", on: j), "黑暗森林")
    }

    func testPathWhitespaceTrimmed() throws {
        let v = try JsonPath.query("  $.code  ", on: root)
        XCTAssertEqual(v.first?.text, "0")
    }

    func testEvalContextJSONDetection() {
        let src = EvalSource.detect(storeJSON)
        XCTAssertEqual(src.kind, .json)
        XCTAssertNotNil(src.jsonValue())
    }

    func testEvalContextTextDetection() {
        let src = EvalSource.detect("<html><body>x</body></html>")
        XCTAssertEqual(src.kind, .html)
        XCTAssertNil(src.jsonValue())
    }

    func testJsonModeRuleOnJSONSource() throws {
        // 书源 @Json: 模式（或 $. 开头）在 JSON 源上直接走 JSONPath
        let ctx = EvalContext(
            source: EvalSource.detect(storeJSON),
            variables: VariableStore()
        )
        let ev = RuleEvaluator()
        XCTAssertEqual(try ev.evaluate(rule: "$.data.books[0].name", in: ctx), "三体")
        // 单值语义 = getString：多命中取第一个
        XCTAssertEqual(try ev.evaluate(rule: "@Json:$.data.books[*].name", in: ctx), "三体")
        // 列表语义 = 全量
        XCTAssertEqual(try ev.evaluateList(rule: "$.data.books[*].name", in: ctx), ["三体", "球状闪电"])
    }

    func testFilterRegexOperator() throws {
        let v = try JsonPath.query("$.data.books[?(@.name =~ '三.*')].name", on: root)
        XCTAssertEqual(v.map(\.text), ["三体"])
    }

    func testWildcardOnObjectGivesSortedValues() throws {
        let j = JsonValue.parse("{\"o\":{\"b\":1,\"a\":2}}")!
        let vals = try JsonPath.query("$.o.*", on: j)
        XCTAssertEqual(vals.map(\.text), ["2", "1"]) // 键排序 a<b
    }

    func testRecursiveWildcard() throws {
        let v = try JsonPath.query("$.stat..*", on: JsonValue.parse("{\"stat\":{\"a\":1}}")!)
        XCTAssertFalse(v.isEmpty)
    }

    func testIndexOnObjectIsEmpty() throws {
        let v = try JsonPath.query("$[0]", on: JsonValue.parse("{\"a\":1}")!)
        XCTAssertTrue(v.isEmpty)
    }

    func testBoolText() {
        XCTAssertEqual(JsonValue.bool(true).text, "true")
        XCTAssertEqual(JsonValue.bool(false).text, "false")
        XCTAssertEqual(JsonValue.null.text, "")
    }

    func testSliceNegativeBounds() throws {
        let arr = JsonValue.parse("[0,1,2,3,4]")!
        let v = try JsonPath.query("$[-2:]", on: arr)
        XCTAssertEqual(v.map(\.text), ["3", "4"])
    }

    func testFirstStringMultiValueTakesFirst() {
        XCTAssertEqual(JsonPath.firstString("$.data.books[*].name", on: root), "三体")
    }
}
