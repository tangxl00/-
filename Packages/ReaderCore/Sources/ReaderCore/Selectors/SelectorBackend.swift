//
//  SelectorBackend.swift
//  ReaderCore
//
//  两个选择器后端：Default（Jsoup CSS + 自研 `@` 逐级下钻）与 XPath。
//
//  Default 模式的真实语义（架构文档二·四）：
//    · 规则按 `@` 逐级下钻，除最后一段外，每段都是「选择器 + 索引筛选」
//    · 前置规则可为空（等价 children），或 children / class.xxx / tag.xxx / id.xxx / text.xxx
//    · 索引两套语法：冒号式 `tag.div.-1:10:2` 与方括号式 `tag.div[-1, 3:-2:-10, 2]`
//      `!` 或 `.` 表示筛选方式，两端与步长均可为负
//    · 末段是取值动作（text / textNodes / ownText / html / all），否则当属性名；
//      但在「列表规则」语境下末段可以是选择器（结果即元素列表）
//
//  XPath 模式解析前必须做三条 HTML 修补（漏掉会让表格型站点直接取空）：
//    · 以 </td> 结尾补 <tr>
//    · 以 </tr> 或 </tbody> 结尾补 <table>
//    · 以 <?xml 开头改用 XML 解析器
//

import Foundation
import SwiftSoup

// MARK: - 索引规格

/// 一段 `@` 下的索引规格。`!` 前缀表示「排除」，`.` 表示「按索引选取」。
struct IndexSpec {
    enum Mode { case pick, exclude }
    var mode: Mode
    /// 每组是 start:end:step（单个数则只含一个元素）
    var groups: [[Int]]

    /// 解析索引串（`-1`、`3:-2`、`3:-2:-10`、`, ` 分隔的多组）。
    /// 负数保留符号，由 `resolve`/`slice` 统一下标归一。
    static func parseGroups(_ body: String) -> [[Int]] {
        body.split(separator: ",").map { g -> [Int] in
            g.split(separator: ":").map { piece -> Int in
                Int(piece.trimmingCharacters(in: .whitespaces)) ?? Int.min
            }.filter { $0 != Int.min }
        }.filter { !$0.isEmpty }
    }

    static func resolve(groups: [[Int]], count: Int) -> [Int] {
        var picked: [Int] = []
        for g in groups {
            switch g.count {
            case 0:
                continue
            case 1:
                let i = normalize(g[0], count)
                if i >= 0 && i < count { picked.append(i) }
            default:
                let start = g[0]
                let end = g.count > 1 ? g[1] : count
                let step = g.count > 2 ? g[2] : 1
                guard step != 0 else { continue }
                picked.append(contentsOf: slice(start: start, end: end, step: step, count: count))
            }
        }
        return picked
    }

    private static func normalize(_ i: Int, _ count: Int) -> Int {
        i < 0 ? count + i : i
    }

    /// `start:end:step`。负下标按倒数计数；±0 混用时允许任意位置起反向。
    static func slice(start s0: Int, end e0: Int, step: Int, count: Int) -> [Int] {
        var s = s0 < 0 ? count + s0 : s0
        var e = e0 < 0 ? count + e0 : e0
        // 越界收敛
        s = s < 0 ? 0 : s
        e = e > count ? count : e
        guard count > 0 else { return [] }
        var out: [Int] = []
        if step > 0 {
            var i = s
            while i < e {
                if i >= 0 && i < count { out.append(i) }
                i += step
            }
        } else {
            // 反向：起点若超出上界，从末尾开始
            var i = s
            if i >= count { i = count - 1 }
            if i < 0 { i = 0 }
            // 反向时 end 表示「不小于该位置」
            let lower = e
            while i > lower - 1 && i >= 0 && i < count {
                out.append(i)
                i += step
            }
        }
        return out
    }
}

// MARK: - 单段解析结果

/// 选择器前缀语义
enum SelectorPrefix {
    case css         // 默认：在当前元素集内做 CSS 选择
    case children    // 直接子元素
    case tag(String)
    case `class`(String)
    case id(String)
    case text        // 取文本子节点
}

struct SelectorSegment {
    var raw: String
    var prefix: SelectorPrefix
    var index: IndexSpec?
    var action: ExtractAction?
}

enum SelectorParseError: Error, CustomStringConvertible {
    case empty
    case invalidIndex(String)
    var description: String {
        switch self {
        case .empty: return "空选择器"
        case .invalidIndex(let s): return "索引语法无法解析: \(s)"
        }
    }
}

enum SelectorParser {
    /// 解析单个 `@` 段。`isLast` 为真时允许把末段当取值动作。
    static func parse(_ part: String, isLast: Bool) -> SelectorSegment {
        let text = part

        // ① 末段可能是取值动作（裸动作名 → 固定集合；其它裸标识符 → 属性名）
        if isLast {
            let t = text.trimmingCharacters(in: .whitespaces)
            if let action = ExtractAction.parse(t) {
                return SelectorSegment(raw: text, prefix: .css, index: nil, action: action)
            }
            // legado 末段没有索引/前缀时，裸词当属性名（如 `@href`、`@src`、`@title`）。
            // 只接受合法标识符，避免把 `li.item` 之类误当属性。
            if isPlainIdentifier(t) {
                return SelectorSegment(raw: text, prefix: .css, index: nil, action: .attr(t))
            }
        }

        // ② 方括号索引 `[-1, 3:-2:-10, 2]`
        var index: IndexSpec?
        var selectorPart = text
        if text.hasSuffix("]"), let open = matchingOpenBracket(text) {
            let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            let mode: IndexSpec.Mode = inner.hasPrefix("!") ? .exclude : .pick
            var body = inner
            if body.hasPrefix("!") { body = String(body.dropFirst()) }
            let groups = IndexSpec.parseGroups(body)
            if !groups.isEmpty {
                index = IndexSpec(mode: mode, groups: groups)
                selectorPart = String(text[text.startIndex..<open])
            }
        }

        // ③ 冒号式索引 `tag.div.-1:10:2` / `tag.div!0`
        if index == nil, let r = trailingColonIndexRange(selectorPart) {
            let specText = String(selectorPart[r])
            let modeChar = specText.first
            let mode: IndexSpec.Mode = (modeChar == "!") ? .exclude : .pick
            var nums = specText
            if modeChar == "." || modeChar == "!" { nums = String(nums.dropFirst()) }
            if let g = IndexSpec.parseGroups(nums).first, !g.isEmpty {
                index = IndexSpec(mode: mode, groups: [g])
                selectorPart = String(selectorPart[selectorPart.startIndex..<r.lowerBound])
            }
        }

        // ④ 前缀判定
        var prefix = SelectorPrefix.css
        if selectorPart.isEmpty {
            prefix = .children
        } else if selectorPart == "children" {
            prefix = .children
            selectorPart = ""
        } else if selectorPart.hasPrefix("class.") {
            prefix = .class(String(selectorPart.dropFirst(6)))
        } else if selectorPart.hasPrefix("tag.") {
            prefix = .tag(String(selectorPart.dropFirst(4)))
        } else if selectorPart.hasPrefix("id.") {
            prefix = .id(String(selectorPart.dropFirst(3)))
        } else if selectorPart.hasPrefix("text.") {
            prefix = .text
        }

        return SelectorSegment(raw: part, prefix: prefix, index: index, action: nil)
    }

    /// 找最后一个方括号组的 `[`（从末尾向内配对）。
    private static func matchingOpenBracket(_ text: String) -> String.Index? {
        guard text.hasSuffix("]") else { return nil }
        var depth = 0
        var i = text.index(before: text.endIndex)
        while true {
            let c = text[i]
            if c == "]" { depth += 1 }
            if c == "[" {
                depth -= 1
                if depth == 0 { return i }
            }
            if i == text.startIndex { return nil }
            i = text.index(before: i)
        }
    }

    /// 尾部追加式索引：`.<nums>` 或 `!<nums>`，nums 允许负数与冒号。
    /// 例：`div.-1:10:2` → 返回 `.-1:10:2`；`div` → nil。
    private static func trailingColonIndexRange(_ text: String) -> Range<String.Index>? {
        guard !text.isEmpty else { return nil }
        // 从末尾向前收集 [0-9:-] 连续段
        var i = text.index(before: text.endIndex)
        var start = text.endIndex
        while true {
            let c = text[i]
            if c.isNumber || c == ":" || c == "-" {
                start = i
                if i == text.startIndex { break }
                i = text.index(before: i)
            } else {
                break
            }
        }
        guard start < text.endIndex else { return nil }
        // start 之前必须紧跟 `.` 或 `!`
        guard start > text.startIndex else { return nil }
        let sep = text.index(before: start)
        let sepChar = text[sep]
        guard sepChar == "." || sepChar == "!" else { return nil }
        return sep..<text.endIndex
    }

    /// 裸标识符（属性名）：字母/下划线开头，只含字母数字下划线与短横。
    static func isPlainIdentifier(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}

// MARK: - Default 后端（Jsoup）

public enum DefaultSelector {
    /// 按 `@` 下钻求值。
    /// - Parameters:
    ///   - rule: 已剥掉模式前缀的规则体
    ///   - elements: 起始元素集
    ///   - isList: 列表规则（末段允许是选择器）
    static func evaluate(rule: String, from elements: [Element], isList: Bool) throws -> [String] {
        let parts = rule.split(separator: "@", omittingEmptySubsequences: false)
            .map(String.init)
        guard !parts.isEmpty else { return [] }

        var current: [Element] = elements
        var currentTextNodes: [String] = []
        var result: [String] = []
        var usedAction = false

        for (idx, part) in parts.enumerated() {
            let isLast = idx == parts.count - 1
            let seg = SelectorParser.parse(part, isLast: isLast)

            if let action = seg.action, isLast {
                usedAction = true
                if case .textNodes = action {
                    // textNodes 作用在「文本节点」而非元素上
                    var texts: [String] = []
                    for e in current {
                        for node in e.getChildNodes() {
                            if let t = node as? TextNode {
                                let s = t.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines)
                                if !s.isEmpty { texts.append(s) }
                            }
                        }
                    }
                    result = texts
                } else {
                    result = try current.map { try NodeExtractor.extract(action, from: $0) }
                }
                break
            }

            // 选择器段
            current = try select(seg, from: current)
            _ = currentTextNodes
        }

        if !usedAction {
            if isList {
                // 列表规则：末段是选择器，结果即元素（取 text 作为元素标识用于后续规则）
                result = try current.map { try NodeExtractor.extract(.text, from: $0) }
            } else {
                // 字段规则但末段没写动作：legado 默认取 text
                result = try current.map { try NodeExtractor.extract(.text, from: $0) }
            }
        }
        return result
    }

    /// 列表规则：返回元素集（供后续名称/URL 规则逐项求值）。
    static func evaluateElements(rule: String, from elements: [Element]) throws -> [Element] {
        let parts = rule.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return [] }
        var current = elements
        for (idx, part) in parts.enumerated() {
            let isLast = idx == parts.count - 1
            let seg = SelectorParser.parse(part, isLast: isLast && ExtractAction.parse(part) != nil)
            if isLast, let action = seg.action {
                // 末段是取值动作 → 不回元素；这种规则在列表语境下无意义，返回空
                _ = action
                return []
            }
            current = try select(seg, from: current)
        }
        return current
    }

    static func select(_ seg: SelectorSegment, from elements: [Element]) throws -> [Element] {
        var picked: [Element] = []
        switch seg.prefix {
        case .css:
            let q = seg.raw.isEmpty ? "" : queryString(seg)
            guard !q.isEmpty else { return elements }
            for e in elements { picked.append(contentsOf: try e.select(q)) }
        case .children:
            for e in elements { picked.append(contentsOf: e.children()) }
        case .tag(let t):
            guard !t.isEmpty else { return elements }
            for e in elements { picked.append(contentsOf: try e.select(t)) }
        case .class(let c):
            guard !c.isEmpty else { return elements }
            for e in elements { picked.append(contentsOf: try e.select(".\(c)")) }
        case .id(let i):
            guard !i.isEmpty else { return elements }
            for e in elements { picked.append(contentsOf: try e.select("#\(i)")) }
        case .text:
            // 文本前缀只作为取值语义，元素级不做筛选
            return elements
        }
        return applyIndex(seg.index, to: picked)
    }

    /// 从原始段重建可用的 CSS 选择器（去掉索引片段）。
    private static func queryString(_ seg: SelectorSegment) -> String {
        var text = seg.raw
        if seg.index != nil {
            if text.hasSuffix("]"), let open = SelectorParser.matchingOpenBracketPublic(text) {
                text = String(text[text.startIndex..<open])
            } else if let r = SelectorParser.trailingColonIndexRangePublic(text) {
                text = String(text[text.startIndex..<r.lowerBound])
            }
        }
        return text
    }

    static func applyIndex(_ spec: IndexSpec?, to elements: [Element]) -> [Element] {
        guard let spec, !spec.groups.isEmpty else { return elements }
        let indices = IndexSpec.resolve(groups: spec.groups, count: elements.count)
        switch spec.mode {
        case .pick:
            return indices.compactMap { $0 >= 0 && $0 < elements.count ? elements[$0] : nil }
        case .exclude:
            let excluded = Set(indices)
            return elements.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
        }
    }
}

// MARK: - 给外部用的解析入口（保持封装）

extension SelectorParser {
    static func matchingOpenBracketPublic(_ t: String) -> String.Index? { matchingOpenBracket(t) }
    static func trailingColonIndexRangePublic(_ t: String) -> Range<String.Index>? { trailingColonIndexRange(t) }
}

// MARK: - XPath 后端

/// XPath 选择器门面。真实求值在 `XPathEngine`（纯 Swift，建树在 SwiftSoup DOM，
/// 不依赖 FoundationXML 的 XMLDocument/XMLNode/XMLElement——那三者在 iOS SDK 上不存在）。
///
/// 保留的三条 HTML 修补（架构文档二·四，缺一条表格型站点直接取空）：
///   · 以 `</td>` 结尾补 `<tr>`
///   · 以 `</tr>` 或 `</tbody>` 结尾补 `<table>`
///   · 以 `<?xml` 开头改用 XML 解析器（SwiftSoup 的 xmlParser）
public enum XPathSelector {
    private static let maxCollection = 2048

    /// HTML 修补（架构文档二·四三条）。
    static func patch(_ html: String) -> String {
        var s = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("</td>") {
            s += "<tr>"
        }
        if s.hasSuffix("</tr>") || s.hasSuffix("</tbody>") {
            s += "<table>"
        }
        return s
    }

    /// 求值。返回文本结果。
    static func evaluate(rule: String, html: String, isList: Bool) throws -> [String] {
        guard let doc = try makeDocument(html) else { return [] }
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return [] }

        // 属性取值 `//a/@href`
        if let slashRange = trimmedRule.range(of: "/@", options: .backwards) {
            let nodePath = String(trimmedRule[trimmedRule.startIndex..<slashRange.lowerBound])
            let attr = String(trimmedRule[slashRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nodePath.isEmpty, !attr.isEmpty, !attr.contains("/") else {
                throw XPathError.malformed(trimmedRule)
            }
            let items = try XPathEngine.query(nodePath, document: doc)
            var out: [String] = []
            for item in items {
                guard let e = item.element else { continue }
                out.append((try? e.attr(attr)) ?? "")
            }
            return isList ? out : [out.first ?? ""]
        }

        let items = try XPathEngine.query(trimmedRule, document: doc)
        let out = items.map { $0.stringValue() }
        if !isList {
            return [out.first ?? ""]
        }
        return out
    }

    /// 列表规则：返回可再求值的源（供逐项再下钻）。
    static func nodes(rule: String, html: String) throws -> [EvalSource] {
        guard let doc = try makeDocument(html) else { return [] }
        let path = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return [] }
        let items = try XPathEngine.query(path, document: doc)
        var out: [EvalSource] = []
        for item in items.prefix(maxCollection) {
            switch item.payload {
            case .element(let e):
                let html = (try? e.outerHtml()) ?? ""
                if let src = try? EvalSource.html(html) {
                    out.append(src)
                } else {
                    out.append(EvalSource.text(html))
                }
            case .attribute(_, let v):
                out.append(EvalSource.text(v))
            case .text(let t):
                out.append(EvalSource.text(t))
            }
        }
        return out
    }

    /// 建树：修补后交给 SwiftSoup。`<?xml` 开头用 XML 解析器，其余用 HTML 解析器
    /// （与 JXDocument 建树在 Jsoup DOM 上的口径一致）。
    static func makeDocument(_ html: String) throws -> Element? {
        let patched = patch(html)
        let trimmed = patched.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("<?xml") {
            return try SwiftSoup.parse(patched, "", Parser.xmlParser())
        }
        return try SwiftSoup.parse(patched)
    }
}
