//
//  XPathEngine.swift
//  ReaderCore
//
//  纯 Swift 的 XPath 子集求值器，建树在 SwiftSoup DOM 上。
//
//  为什么不用 Foundation 的 XMLDocument：XMLDocument / XMLElement / XMLNode 属于
//  FoundationXML，在 macOS/Linux 可用，但 iOS SDK 里不存在（iOS 的 Foundation 没有
//  XMLDocument 类）。把 XPath 后端建在 FoundationXML 上会让 iOS 构建直接编译失败，
//  因此这里改为在 SwiftSoup DOM 上自实现求值——这也更贴近 legado 的真实实现
//  （seimicrawler 的 JXDocument 就是建树在 Jsoup DOM 上的）。
//
//  支持的语法面（覆盖架构文档二·四要求的语义范围）：
//    · 轴：`/`（子轴）、`//`（descendant-or-self）、`.`（当前节点）、`..`（父节点）
//    · 节点测试：元素名、`*`、`text()`、`node()`
//    · 属性步：`@attr`（可作末步，取属性值）
//    · 谓词：`[n]`（1 基，支持负数从尾取）、`[last()]`、`[@a]`、`[@a='v']`、`[@a!='v']`、
//      `[contains(@a,'v')]`、`[starts-with(@a,'v')]`、`[text()='v']`、`[contains(text(),'v')]`、
//      `[not(…)]`，以及这些谓词用 `and` / `or` 组合（组合时须整体用括号包住）
//    · 多条路径用 `|` 求并集
//
//  不支持的语法（XPath 2.0 函数库、命名空间前缀、算术表达式、`following-sibling::` 等轴）
//  会抛 `XPathError.unsupported`，绝不静默返回空集——静默空集会让书源「取不到值也不报错」。
//

import Foundation
import SwiftSoup

// MARK: - 错误

public enum XPathError: Error, CustomStringConvertible, Equatable {
    /// 不支持的 XPath 语法（前缀、函数、轴等）
    case unsupported(String)
    /// 路径本身无法解析
    case malformed(String)

    public var description: String {
        switch self {
        case .unsupported(let s): return "XPath 语法暂不支持：\(s)"
        case .malformed(let s): return "XPath 路径无法解析：\(s)"
        }
    }
}

// MARK: - 结果项

/// 一次 XPath 求值命中项。三种形态互斥：元素 / 属性值 / 文本节点。
public struct XPathItem {
    public enum Payload {
        case element(Element)
        case attribute(name: String, value: String)
        case text(String)
    }

    public let payload: Payload

    public var element: Element? {
        if case .element(let e) = payload { return e }
        return nil
    }

    /// 元素取 Jsoup `text()`（空白归一，与 Default 后端一致）；属性取属性值；文本节点取原文。
    public func stringValue() -> String {
        switch payload {
        case .element(let e):
            return (try? e.text()) ?? ""
        case .attribute(_, let v):
            return v
        case .text(let t):
            return t
        }
    }

    public func outerHTML() -> String {
        switch payload {
        case .element(let e):
            return (try? e.outerHtml()) ?? ""
        case .attribute(let n, let v):
            return v.isEmpty ? "" : "\(n)=\"\(v)\""
        case .text(let t):
            return t
        }
    }
}

// MARK: - 语法节点

enum XPathAxis: Equatable {
    case child        // `/`
    case descendant   // `//`（descendant-or-self）
    case selfNode     // `.`
    case parent       // `..`
}

enum XPathNodeTest: Equatable {
    case name(String)   // 元素名（大小写不敏感匹配，HTML 语义）
    case wildcard       // `*`
    case text           // `text()`
    case node           // `node()`
}

struct XPathStep {
    var axis: XPathAxis
    var test: XPathNodeTest?
    /// 属性步 `@href`
    var attribute: String?
    var predicates: [XPathPredicate]
}

indirect enum XPathPredicate: Equatable {
    case index(Int)
    case last
    case existsAttribute(String)
    case attributeEquals(String, String)
    case attributeNotEquals(String, String)
    case attributeContains(String, String)
    case attributeStartsWith(String, String)
    case textEquals(String)
    case textContains(String)
    case not(XPathPredicate)
    case and(XPathPredicate, XPathPredicate)
    case or(XPathPredicate, XPathPredicate)
}

// MARK: - 求值器

public enum XPathEngine {

    /// 单条路径求值。返回全部命中项（文档顺序）。
    public static func query(_ rule: String, document: Element) throws -> [XPathItem] {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // `|` 并集：逐条求值后合并（去重靠元素身份）
        let branches = splitTopLevel(trimmed, separator: "|")
        if branches.count > 1 {
            var merged: [XPathItem] = []
            var seenElements = Set<ObjectIdentifier>()
            var seenScalars = Set<String>()
            for branch in branches {
                for item in try query(branch, document: document) {
                    switch item.payload {
                    case .element(let e):
                        if seenElements.insert(ObjectIdentifier(e)).inserted { merged.append(item) }
                    case .attribute(let n, let v):
                        if seenScalars.insert("@\(n)=\(v)").inserted { merged.append(item) }
                    case .text(let t):
                        if seenScalars.insert("#\(t)").inserted { merged.append(item) }
                    }
                }
            }
            return merged
        }

        let steps = try parsePath(trimmed)

        var current: [XPathItem] = [XPathItem(payload: .element(document))]

        for (stepIndex, step) in steps.enumerated() {
            // 末步属性：`/@href`
            if let attr = step.attribute {
                var out: [XPathItem] = []
                for item in current {
                    guard let el = item.element else { continue }
                    guard el.hasAttr(attr) else { continue }
                    let value = (try? el.attr(attr)) ?? ""
                    out.append(XPathItem(payload: .attribute(name: attr, value: value)))
                }
                current = applyPredicates(step.predicates, to: out, stepIndex: stepIndex, path: trimmed)
                continue
            }

            // 文本节点测试
            if case .text? = step.test {
                var out: [XPathItem] = []
                for item in current {
                    guard let el = item.element else { continue }
                    let nodes: [Node]
                    switch step.axis {
                    case .descendant:
                        nodes = descendantsOrSelf(of: el).flatMap { $0.getChildNodes() }
                    case .child, .selfNode:
                        nodes = el.getChildNodes()
                    case .parent:
                        nodes = []
                    }
                    for node in nodes {
                        if let t = node as? TextNode {
                            out.append(XPathItem(payload: .text(t.getWholeText())))
                        }
                    }
                }
                current = applyPredicates(step.predicates, to: out, stepIndex: stepIndex, path: trimmed)
                continue
            }

            switch step.axis {
            case .selfNode:
                current = applyPredicates(step.predicates, to: current, stepIndex: stepIndex, path: trimmed)

            case .parent:
                var out: [XPathItem] = []
                for item in current {
                    if let el = item.element, let parent = el.parent() {
                        out.append(XPathItem(payload: .element(parent)))
                    }
                }
                current = applyPredicates(step.predicates, to: out, stepIndex: stepIndex, path: trimmed)

            case .child, .descendant:
                var out: [XPathItem] = []
                for item in current {
                    guard let el = item.element else { continue }
                    let candidates: [Element]
                    switch step.axis {
                    case .descendant:
                        candidates = descendantsOrSelf(of: el)
                    default:
                        candidates = childElements(of: el)
                    }
                    let matched = candidates.filter { matches(step.test, $0) }
                    let resolved = applyPredicates(step.predicates,
                                                   to: matched.map { XPathItem(payload: .element($0)) },
                                                   stepIndex: stepIndex,
                                                   path: trimmed)
                    out.append(contentsOf: resolved)
                }
                current = out
            }
        }

        return current
    }

    // MARK: - 解析

    private static func parsePath(_ rule: String) throws -> [XPathStep] {
        var steps: [XPathStep] = []
        let chars = Array(rule)
        var i = 0
        var pendingAxis: XPathAxis = .child

        // 绝对路径：起始 `/` 或 `//` 都从文档根出发（文档根是 Document，其子即 html/XML 根）
        while i < chars.count {
            // 读轴分隔符
            if chars[i] == "/" {
                if i + 1 < chars.count, chars[i + 1] == "/" {
                    pendingAxis = .descendant
                    i += 2
                } else {
                    pendingAxis = .child
                    i += 1
                }
                if i >= chars.count { break }
            }

            // 读一步：到下一个顶层 `/` 为止，方括号与引号内不切
            var body = ""
            var bracketDepth = 0
            var quote: Character? = nil
            while i < chars.count {
                let c = chars[i]
                if let q = quote {
                    body.append(c)
                    if c == q { quote = nil }
                    i += 1
                    continue
                }
                if c == "'" || c == "\"" {
                    quote = c
                    body.append(c)
                    i += 1
                    continue
                }
                if c == "[" { bracketDepth += 1; body.append(c); i += 1; continue }
                if c == "]" {
                    bracketDepth -= 1
                    if bracketDepth < 0 { throw XPathError.malformed(rule) }
                    body.append(c); i += 1; continue
                }
                if c == "/" && bracketDepth == 0 { break }
                body.append(c)
                i += 1
            }
            if quote != nil { throw XPathError.malformed(rule) }
            if bracketDepth != 0 { throw XPathError.malformed(rule) }

            let raw = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                // 允许路径以 `/` 结尾，忽略空步
                continue
            }
            steps.append(try parseStep(raw, axis: pendingAxis, rule: rule))
            pendingAxis = .child
        }

        guard !steps.isEmpty else { throw XPathError.malformed(rule) }
        return steps
    }

    private static func parseStep(_ raw: String, axis: XPathAxis, rule: String) throws -> XPathStep {
        if raw == "." {
            return XPathStep(axis: .selfNode, test: nil, attribute: nil, predicates: [])
        }
        if raw == ".." {
            return XPathStep(axis: .parent, test: nil, attribute: nil, predicates: [])
        }

        // 拆出谓词（保留引号内容）
        var base = ""
        var predicateBodies: [String] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "[" {
                guard let close = matchingBracket(raw, from: i) else {
                    throw XPathError.malformed(rule)
                }
                let inner = String(raw[raw.index(after: i)..<close])
                predicateBodies.append(inner)
                i = raw.index(after: close)
                continue
            }
            base.append(c)
            i = raw.index(after: i)
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)

        // 轴关键字（`axis::test` 形式只支持 child/descendant-or-self/self/parent）
        if let range = base.range(of: "::") {
            let axisName = String(base[base.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(base[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved: XPathAxis
            switch axisName {
            case "child": resolved = .child
            case "descendant-or-self": resolved = .descendant
            case "descendant": resolved = .descendant
            case "self": resolved = .selfNode
            case "parent": resolved = .parent
            default:
                throw XPathError.unsupported("\(axisName):: 轴")
            }
            return XPathStep(axis: resolved,
                             test: try nodeTest(rest, rule: rule),
                             attribute: rest.hasPrefix("@") ? String(rest.dropFirst()) : nil,
                             predicates: try predicateBodies.map { try parsePredicate($0.trimmingCharacters(in: .whitespacesAndNewlines), rule: rule) })
        }

        if base.hasPrefix("@") {
            let name = String(base.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw XPathError.malformed(rule) }
            if name.contains("*") || name.contains("(") {
                throw XPathError.unsupported("属性步 \(base)")
            }
            return XPathStep(axis: axis,
                             test: nil,
                             attribute: name,
                             predicates: try predicateBodies.map { try parsePredicate($0.trimmingCharacters(in: .whitespacesAndNewlines), rule: rule) })
        }

        return XPathStep(axis: axis,
                         test: try nodeTest(base, rule: rule),
                         attribute: nil,
                         predicates: try predicateBodies.map { try parsePredicate($0.trimmingCharacters(in: .whitespacesAndNewlines), rule: rule) })
    }

    private static func nodeTest(_ base: String, rule: String) throws -> XPathNodeTest {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "*" { return .wildcard }
        if trimmed == "text()" { return .text }
        if trimmed == "node()" { return .node }
        if trimmed.hasSuffix("(") || trimmed.contains("(") {
            throw XPathError.unsupported("节点测试 \(trimmed)")
        }
        if trimmed.contains(":") {
            // 命名空间前缀：只用本地名匹配，避免整条规则失败
            let parts = trimmed.components(separatedBy: ":")
            if parts.count == 2, let local = parts.last, !local.isEmpty {
                return .name(local)
            }
            throw XPathError.unsupported("命名空间节点测试 \(trimmed)")
        }
        guard !trimmed.isEmpty else { throw XPathError.malformed(rule) }
        return .name(trimmed)
    }

    // MARK: - 谓词

    private static func parsePredicate(_ body: String, rule: String) throws -> XPathPredicate {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw XPathError.malformed(rule) }

        // 外层括号整体包裹的 and / or 组合
        if text.hasPrefix("("), let close = matchingBracket(text, expecting: "(", from: text.startIndex),
           text.index(after: close) == text.endIndex {
            return try parsePredicate(String(text[text.index(after: text.startIndex)..<close]), rule: rule)
        }

        if let split = splitLogical(text, keyword: " or ") {
            return .or(try parsePredicate(split.0, rule: rule), try parsePredicate(split.1, rule: rule))
        }
        if let split = splitLogical(text, keyword: " and ") {
            return .and(try parsePredicate(split.0, rule: rule), try parsePredicate(split.1, rule: rule))
        }

        if text == "last()" { return .last }

        if text.hasPrefix("not("), let close = matchingBracket(text, expecting: "(", from: text.index(text.startIndex, offsetBy: 3)),
           text.index(after: close) == text.endIndex {
            let inner = String(text[text.index(text.startIndex, offsetBy: 4)..<close])
            return .not(try parsePredicate(inner, rule: rule))
        }

        if let n = Int(text) { return .index(n) }

        // contains(@a,'v') / starts-with(@a,'v') / contains(text(),'v')
        if let call = parseFunction(text) {
            switch call.name {
            case "contains", "starts-with":
                let isContains = call.name == "contains"
                let args = splitArguments(call.args)
                guard args.count == 2 else { throw XPathError.malformed("\(call.name) 参数个数") }
                let lhs = args[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let rhs = unquote(args[1])
                if lhs.hasPrefix("@") {
                    let attr = String(lhs.dropFirst())
                    return isContains ? .attributeContains(attr, rhs) : .attributeStartsWith(attr, rhs)
                }
                if lhs == "text()" {
                    guard isContains else { throw XPathError.unsupported("starts-with(text(),…)") }
                    return .textContains(rhs)
                }
                throw XPathError.unsupported("\(call.name)(\(call.args))")
            default:
                throw XPathError.unsupported("函数 \(call.name)()")
            }
        }

        // @a='v' / @a="v" / @a!='v' / text()='v'
        if let cmp = splitComparison(text) {
            let lhs = cmp.0.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = unquote(cmp.2)
            if lhs.hasPrefix("@") {
                let attr = String(lhs.dropFirst())
                return cmp.1 == "!=" ? .attributeNotEquals(attr, rhs) : .attributeEquals(attr, rhs)
            }
            if lhs == "text()" {
                guard cmp.1 == "=" else { throw XPathError.unsupported("text() \(cmp.1) …") }
                return .textEquals(rhs)
            }
            throw XPathError.unsupported("比较式 \(text)")
        }

        // 纯属性存在判定 `[@a]`
        if text.hasPrefix("@") {
            let attr = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !attr.isEmpty else { throw XPathError.malformed(rule) }
            return .existsAttribute(attr)
        }

        if text == "text()" || text == "node()" {
            throw XPathError.unsupported("谓词 \(text)")
        }

        throw XPathError.unsupported("谓词 \(text)")
    }

    /// 顶层按关键字拆分（跳过括号与引号内部）
    private static func splitLogical(_ text: String, keyword: String) -> (String, String)? {
        let chars = Array(text)
        let kw = Array(keyword)
        var depth = 0
        var quote: Character? = nil
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
                i += 1
                continue
            }
            if c == "'" || c == "\"" { quote = c; i += 1; continue }
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if depth == 0, i + kw.count <= chars.count,
               Array(chars[i..<(i + kw.count)]) == kw {
                let left = String(chars[0..<i])
                let right = String(chars[(i + kw.count)...])
                return (left, right)
            }
            i += 1
        }
        return nil
    }

    private static func parseFunction(_ text: String) -> (name: String, args: String)? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let name = String(text[text.startIndex..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("@") else { return nil }
        let args = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        return (name, args)
    }

    private static func splitArguments(_ args: String) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        var quote: Character? = nil
        for c in args {
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "'" || c == "\"" { quote = c; current.append(c); continue }
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if c == ",", depth == 0 {
                out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            }
            current.append(c)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    private static func splitComparison(_ text: String) -> (String, String, String)? {
        var quote: Character? = nil
        var depth = 0
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if let q = quote {
                if c == q { quote = nil }
                i = text.index(after: i)
                continue
            }
            if c == "'" || c == "\"" { quote = c; i = text.index(after: i); continue }
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if depth == 0 {
                if c == "!", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "=" {
                    let lhs = String(text[text.startIndex..<i])
                    let rhs = String(text[text.index(i, offsetBy: 2)...])
                    return (lhs, "!=", rhs)
                }
                if c == "=" {
                    // 排除 `!=` 的尾巴
                    if i > text.startIndex, text[text.index(before: i)] == "!" { i = text.index(after: i); continue }
                    let lhs = String(text[text.startIndex..<i])
                    let rhs = String(text[text.index(after: i)...])
                    return (lhs, "=", rhs)
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func unquote(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 2,
           (t.hasPrefix("'") && t.hasSuffix("'")) || (t.hasPrefix("\"") && t.hasSuffix("\"")) {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    /// 找配对的中括号 / 圆括号
    private static func matchingBracket(_ s: String, from: String.Index) -> String.Index? {
        matchingBracket(s, expecting: String(s[from]), from: from)
    }

    private static func matchingBracket(_ s: String,
                                        expecting open: String,
                                        from: String.Index) -> String.Index? {
        guard let openChar = open.first else { return nil }
        let closeChar: Character = (openChar == "[" ? "]" : ")")
        var depth = 0
        var quote: Character? = nil
        var i = from
        while i < s.endIndex {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
                i = s.index(after: i)
                continue
            }
            if c == "'" || c == "\"" { quote = c; i = s.index(after: i); continue }
            if c == openChar { depth += 1 }
            if c == closeChar {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func splitTopLevel(_ s: String, separator: Character) -> [String] {
        var out: [String] = []
        var current = ""
        var bracketDepth = 0
        var quote: Character? = nil
        for c in s {
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "'" || c == "\"" { quote = c; current.append(c); continue }
            if c == "[" { bracketDepth += 1 }
            if c == "]" { bracketDepth -= 1 }
            if c == separator, bracketDepth == 0 {
                out.append(current)
                current = ""
                continue
            }
            current.append(c)
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: - 谓词求值

    private static func applyPredicates(_ predicates: [XPathPredicate],
                                        to items: [XPathItem],
                                        stepIndex: Int,
                                        path: String) -> [XPathItem] {
        guard !predicates.isEmpty else { return items }
        var result = items
        for predicate in predicates {
            result = apply(predicate, to: result)
        }
        return result
    }

    private static func apply(_ predicate: XPathPredicate, to items: [XPathItem]) -> [XPathItem] {
        switch predicate {
        case .index(let n):
            guard n != 0 else { return [] }
            let count = items.count
            let idx = n > 0 ? n - 1 : count + n
            guard idx >= 0, idx < count else { return [] }
            return [items[idx]]

        case .last:
            return items.isEmpty ? [] : [items[items.count - 1]]

        case .not(let inner):
            // `not()` 作用在单节点上；先算出对整集的布尔，再按节点判定
            return items.filter { item in
                !evaluateBoolean(inner, item: item, position: 0, size: items.count)
            }

        case .and(let a, let b):
            return items.filter { item in
                let pos = (items.firstIndex(where: { identityEqual($0, item) }) ?? 0) + 1
                return evaluateBoolean(a, item: item, position: pos, size: items.count)
                    && evaluateBoolean(b, item: item, position: pos, size: items.count)
            }

        case .or(let a, let b):
            return items.filter { item in
                let pos = (items.firstIndex(where: { identityEqual($0, item) }) ?? 0) + 1
                return evaluateBoolean(a, item: item, position: pos, size: items.count)
                    || evaluateBoolean(b, item: item, position: pos, size: items.count)
            }

        default:
            return items.filter { evaluateBoolean(predicate, item: $0, position: 0, size: items.count) }
        }
    }

    private static func identityEqual(_ a: XPathItem, _ b: XPathItem) -> Bool {
        switch (a.payload, b.payload) {
        case (.element(let x), .element(let y)): return x === y
        case (.attribute(let n1, let v1), .attribute(let n2, let v2)): return n1 == n2 && v1 == v2
        case (.text(let t1), .text(let t2)): return t1 == t2
        default: return false
        }
    }

    private static func evaluateBoolean(_ predicate: XPathPredicate,
                                        item: XPathItem,
                                        position: Int,
                                        size: Int) -> Bool {
        switch predicate {
        case .index(let n):
            guard n != 0 else { return false }
            let idx = n > 0 ? n - 1 : size + n
            return idx == position - 1
        case .last:
            return position == size
        case .existsAttribute(let name):
            guard let el = item.element else { return false }
            return el.hasAttr(name)
        case .attributeEquals(let name, let value):
            guard let el = item.element else { return false }
            return ((try? el.attr(name)) ?? "") == value
        case .attributeNotEquals(let name, let value):
            guard let el = item.element else { return false }
            return ((try? el.attr(name)) ?? "") != value
        case .attributeContains(let name, let value):
            guard let el = item.element else { return false }
            return ((try? el.attr(name)) ?? "").contains(value)
        case .attributeStartsWith(let name, let value):
            guard let el = item.element else { return false }
            return ((try? el.attr(name)) ?? "").hasPrefix(value)
        case .textEquals(let value):
            return item.stringValue() == value
        case .textContains(let value):
            return item.stringValue().contains(value)
        case .not(let inner):
            return !evaluateBoolean(inner, item: item, position: position, size: size)
        case .and(let a, let b):
            return evaluateBoolean(a, item: item, position: position, size: size)
                && evaluateBoolean(b, item: item, position: position, size: size)
        case .or(let a, let b):
            return evaluateBoolean(a, item: item, position: position, size: size)
                || evaluateBoolean(b, item: item, position: position, size: size)
        }
    }

    // MARK: - DOM 遍历

    private static func matches(_ test: XPathNodeTest?, _ el: Element) -> Bool {
        switch test {
        case .name(let n):
            return el.tagName().lowercased() == n.lowercased()
        case .wildcard, .node, .none:
            return true
        case .text:
            return false
        }
    }

    private static func childElements(of el: Element) -> [Element] {
        var out: [Element] = []
        for node in el.getChildNodes() {
            if let e = node as? Element { out.append(e) }
        }
        return out
    }

    /// descendant-or-self：文档顺序（先自己，再深度优先子节点）
    private static func descendantsOrSelf(of el: Element) -> [Element] {
        var out: [Element] = [el]
        for child in childElements(of: el) {
            out.append(contentsOf: descendantsOrSelf(of: child))
        }
        return out
    }
}
