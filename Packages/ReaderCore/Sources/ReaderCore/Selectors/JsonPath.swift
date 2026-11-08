//
//  JsonPath.swift
//  ReaderCore
//
//  自建 JSONPath 求值器（不依赖第三方库）。
//  覆盖 legado 书源实际使用到的子集：
//    $ / $.a / $['a'] / $[0] / $[-1] / $[*] / $..a / $..*
//    $[0,2] / $[1:5] / $[-2:] / $[::2] / $[?(@.a)] / $[?(@.a=='x')]
//    $..book[?(@.price>10)]
//  以及嵌套取值 {$.rule} 的括号平衡替换（架构文档明确要求不用正则）。
//

import Foundation

public struct JsonPathError: Error, CustomStringConvertible {
    public let message: String
    public let path: String
    public var description: String { "JSONPath 解析失败 [\(path)]: \(message)" }
}

// MARK: - 路径片段

enum JPNode {
    case child(String)
    case wildcard
    case recursiveChild(String)
    case recursiveWildcard
    case index([Int])
    case slice(JPBound, JPBound, Int)
    case filter(JPFilter)
}

struct JPBound {
    var value: Int?
    var isEnd: Bool   // 是否为「省略的尾部」（用于 [1:]）
}

struct JPFilter {
    enum Op: String {
        case eq = "==", ne = "!=", lt = "<", le = "<=", gt = ">", ge = ">="
        case regex = "=~"
        case exists   // 只判存在
    }
    var keyPath: [String]
    var op: Op
    var literal: String
    var isLength: Bool   // 形如 @.length
}

// MARK: - 解析器

struct JParser {
    private var chars: [Character] = []
    private var pos = 0
    private let original: String

    init(_ path: String) {
        self.original = path
        self.chars = Array(path)
    }

    private var isAtEnd: Bool { pos >= chars.count }
    private func peek(_ offset: Int = 0) -> Character? {
        let i = pos + offset
        return i < chars.count ? chars[i] : nil
    }

    private mutating func advance() -> Character? {
        guard pos < chars.count else { return nil }
        defer { pos += 1 }
        return chars[pos]
    }

    mutating func parse() throws -> [JPNode] {
        // 允许省略开头的 $
        if peek() == "$" { _ = advance() }
        var nodes: [JPNode] = []
        while !isAtEnd {
            let ch = peek()
            if ch == "." {
                _ = advance()
                if peek() == "." {
                    _ = advance()
                    // 递归下降：$..name 或 $..* 或 $..[0]
                    if peek() == "*" { _ = advance(); nodes.append(.recursiveWildcard) }
                    else if peek() == "[" { nodes.append(try parseBracket()) }
                    else {
                        let name = parseName()
                        if name.isEmpty { throw JsonPathError(message: "递归下降缺少名称", path: original) }
                        nodes.append(.recursiveChild(name))
                    }
                } else {
                    if peek() == "*" {
                        _ = advance()
                        nodes.append(.wildcard)
                    } else {
                        let name = parseName()
                        if name.isEmpty { throw JsonPathError(message: "点号后缺少字段名", path: original) }
                        nodes.append(.child(name))
                    }
                }
            } else if ch == "[" {
                nodes.append(try parseBracket())
            } else {
                // 裸名称（容忍 $a.b 这类缺 $ 的写法）
                let name = parseName()
                if name.isEmpty { throw JsonPathError(message: "无法识别的片段", path: original) }
                nodes.append(.child(name))
            }
        }
        return nodes
    }

    private mutating func parseName() -> String {
        var out = ""
        while let c = peek(), c != ".", c != "[", c != "]" {
            out.append(c)
            _ = advance()
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private mutating func parseBracket() throws -> JPNode {
        guard advance() == "[" else { throw JsonPathError(message: "缺少 [", path: original) }
        skipSpaces()
        // 过滤器
        if peek() == "?" {
            _ = advance()
            skipSpaces()
            if peek() == "(" { _ = advance() }
            var body = ""
            var depth = 1
            while let c = advance() {
                if c == "(" { depth += 1 }
                if c == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(c)
            }
            skipSpaces()
            if peek() == "]" { _ = advance() }
            return .filter(try parseFilter(body))
        }
        // 引号字段
        if peek() == "'" || peek() == "\"" {
            let quote = advance()!
            var name = ""
            while let c = advance(), c != quote { name.append(c) }
            skipSpaces()
            if peek() == "]" { _ = advance() }
            return .child(name)
        }
        // * / 索引 / 切片 / 联合
        if peek() == "*" {
            _ = advance()
            skipSpaces()
            if peek() == "]" { _ = advance() }
            return .wildcard
        }
        var body = ""
        while let c = advance(), c != "]" { body.append(c) }
        body = body.trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return .wildcard }
        if body.contains(":") {
            let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let start = parts.count > 0 ? Int(parts[0].trimmingCharacters(in: .whitespaces)) : nil
            let end = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            let step = (parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespaces)) : nil) ?? 1
            return .slice(JPBound(value: start, isEnd: parts.count > 0 && parts[0].isEmpty ? true : false),
                          JPBound(value: end, isEnd: parts.count > 1 && parts[1].isEmpty ? true : false),
                          step)
        }
        if body.contains(",") {
            let idx = body.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return .index(idx)
        }
        if let i = Int(body) { return .index([i]) }
        return .child(body)
    }

    private mutating func skipSpaces() {
        while let c = peek(), c == " " { _ = advance() }
    }

    private func parseFilter(_ body: String) throws -> JPFilter {
        var text = body.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("@") { text = String(text.dropFirst()) }
        if text.hasPrefix(".") { text = String(text.dropFirst()) }

        // 运算符识别（按长度优先）
        let ops: [JPFilter.Op] = [.eq, .ne, .le, .ge, .lt, .gt, .regex]
        for op in ops {
            if let r = text.range(of: op.rawValue) {
                let lhs = String(text[text.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                var rhs = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                rhs = rhs.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                var keyPath = lhs.split(separator: ".").map(String.init)
                var isLength = false
                if let last = keyPath.last, last == "length" || last == "size()" {
                    keyPath.removeLast()
                    isLength = true
                }
                return JPFilter(keyPath: keyPath, op: op, literal: rhs, isLength: isLength)
            }
        }
        var keyPath = text.split(separator: ".").map(String.init)
        var isLength = false
        if let last = keyPath.last, last == "length" || last == "size()" {
            keyPath.removeLast()
            isLength = true
        }
        return JPFilter(keyPath: keyPath, op: .exists, literal: "", isLength: isLength)
    }
}

// MARK: - 求值器

public enum JsonPath {
    /// 求值入口。返回命中的节点列表；语法错误抛 JsonPathError。
    public static func query(_ path: String, on root: JsonValue) throws -> [JsonValue] {
        var parser = JParser(path.trimmingCharacters(in: .whitespacesAndNewlines))
        let nodes = try parser.parse()
        var current: [JsonValue] = [root]
        for node in nodes {
            current = apply(node, to: current)
        }
        return current
    }

    /// 取第一个命中的文本，等价于 legado 的 `getString`。未命中返回 ""。
    public static func firstString(_ path: String, on root: JsonValue) -> String {
        (try? query(path, on: root))?.first?.text ?? ""
    }

    private static func apply(_ node: JPNode, to nodes: [JsonValue]) -> [JsonValue] {
        switch node {
        case .child(let name):
            return nodes.compactMap { child(name, of: $0) }
        case .wildcard:
            return nodes.flatMap { children(of: $0) }
        case .recursiveChild(let name):
            return nodes.flatMap { (v: JsonValue) -> [JsonValue] in recursiveCollect(name, in: v) }
        case .recursiveWildcard:
            return nodes.flatMap { allDescendants($0) }
        case .index(let idxs):
            return nodes.flatMap { n -> [JsonValue] in
                guard case .array(let arr) = n else { return [] }
                return idxs.compactMap { i in
                    let real = i < 0 ? arr.count + i : i
                    return (real >= 0 && real < arr.count) ? arr[real] : nil
                }
            }
        case .slice(let start, let end, let step):
            return nodes.flatMap { n -> [JsonValue] in
                guard case .array(let arr) = n else { return [] }
                var s = start.isEnd ? 0 : (start.value ?? 0)
                var e = end.isEnd ? arr.count : (end.value ?? arr.count)
                if s < 0 { s += arr.count }
                if e < 0 { e += arr.count }
                s = max(0, min(s, arr.count))
                e = max(0, min(e, arr.count))
                guard step != 0 else { return [] }
                var out: [JsonValue] = []
                var i = s
                if step > 0 {
                    while i < e { out.append(arr[i]); i += step }
                } else {
                    if start.isEnd && end.value != nil { i = min(s, arr.count - 1) }
                    while i > e - 1 && i >= 0 && i < arr.count { out.append(arr[i]); i += step }
                }
                return out
            }
        case .filter(let f):
            return nodes.flatMap { n -> [JsonValue] in
                guard case .array(let arr) = n else { return [] }
                return arr.filter { match(f, on: $0) }
            }
        }
    }

    private static func child(_ name: String, of value: JsonValue) -> JsonValue? {
        if case .object(let o) = value { return o[name] }
        return nil
    }

    private static func children(of value: JsonValue) -> [JsonValue] {
        switch value {
        case .array(let a): return a
        case .object(let o): return o.sorted { $0.key < $1.key }.map(\.value)
        default: return []
        }
    }

    private static func allDescendants(_ value: JsonValue) -> [JsonValue] {
        var out: [JsonValue] = [value]
        switch value {
        case .array(let a):
            for item in a { out.append(contentsOf: allDescendants(item)) }
        case .object(let o):
            for (_, v) in o.sorted(by: { $0.key < $1.key }) { out.append(contentsOf: allDescendants(v)) }
        default: break
        }
        return out
    }

    private static func recursiveCollect(_ name: String, in value: JsonValue) -> [JsonValue] {
        var out: [JsonValue] = []
        if case .object(let o) = value, let v = o[name] { out.append(v) }
        switch value {
        case .array(let a): for item in a { out.append(contentsOf: recursiveCollect(name, in: item)) }
        case .object(let o):
            for (k, v) in o.sorted(by: { $0.key < $1.key }) where k != name {
                out.append(contentsOf: recursiveCollect(name, in: v))
            }
            // 命中字段自身的子树也要继续下钻
            if let v = o[name] { out.append(contentsOf: recursiveCollect(name, in: v)) }
        default: break
        }
        return out
    }

    private static func match(_ f: JPFilter, on value: JsonValue) -> Bool {
        var target: JsonValue? = value
        for key in f.keyPath {
            guard let t = target else { return false }
            target = child(key, of: t)
        }
        let base: JsonValue
        if f.isLength {
            guard let t = target else { return false }
            if case .array(let a) = t { base = .number(Double(a.count)) }
            else if case .string(let s) = t { base = .number(Double(s.count)) }
            else { base = .null }
        } else {
            guard let t = target else {
                return f.op == .exists ? false : false
            }
            base = t
        }
        switch f.op {
        case .exists: return !base.isNull
        case .eq: return compare(base, f.literal) == .orderedSame
        case .ne: return compare(base, f.literal) != .orderedSame
        case .lt: return compare(base, f.literal) == .orderedAscending
        case .le:
            let r = compare(base, f.literal)
            return r == .orderedAscending || r == .orderedSame
        case .gt: return compare(base, f.literal) == .orderedDescending
        case .ge:
            let r = compare(base, f.literal)
            return r == .orderedDescending || r == .orderedSame
        case .regex:
            guard let re = try? NSRegularExpression(pattern: f.literal) else { return false }
            let t = base.text
            let range = NSRange(t.startIndex..<t.endIndex, in: t)
            return re.firstMatch(in: t, options: [], range: range) != nil
        }
    }

    private static func compare(_ value: JsonValue, _ literal: String) -> ComparisonResult {
        if case .number(let d) = value, let l = Double(literal) {
            if d == l { return .orderedSame }
            return d < l ? .orderedAscending : .orderedDescending
        }
        if case .bool(let b) = value {
            let l = literal.lowercased() == "true"
            if b == l { return .orderedSame }
            return b ? .orderedDescending : .orderedAscending
        }
        let a = value.text
        if a == literal { return .orderedSame }
        return a < literal ? .orderedAscending : .orderedDescending
    }
}

// MARK: - 嵌套取值 {$.rule}

public enum JsonNested {
    /// 可抛错版本：resolver 抛出「含 JS 不支持」等错误时向上传播，
    /// 避免求值链路把不支持静默成空串（任务裁决第 1 条）。
    public static func replacingNestedThrowing(
        in rule: String,
        resolver: (String) throws -> String
    ) throws -> String {
        guard rule.contains("{") else { return rule }
        var out = ""
        var i = rule.startIndex
        while i < rule.endIndex {
            guard rule[i] == "{" else {
                out.append(rule[i])
                i = rule.index(after: i)
                continue
            }
            var j = rule.index(after: i)
            var depth = 1
            var inner = ""
            var closed = false
            while j < rule.endIndex {
                let c = rule[j]
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { closed = true; break }
                }
                inner.append(c)
                j = rule.index(after: j)
            }
            if closed {
                let trimmed = inner.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("$") || trimmed.hasPrefix("@") || trimmed.hasPrefix("/") {
                    out.append(try resolver(trimmed))
                } else {
                    out.append("{")
                    out.append(inner)
                    out.append("}")
                }
                i = rule.index(after: j)
            } else {
                out.append(String(rule[i...]))
                break
            }
        }
        return out
    }

    /// 把形如 `{$.a.b}` 的占位替换成取值结果。
    /// 用括号平衡法而不是正则（架构文档明确要求）：
    /// 旧实现用正则匹配 `{...}` 时，若内部 JSON 文本自带 `}` 会解析错误。
    public static func replacingNested(
        in rule: String,
        resolver: (String) -> String
    ) -> String {
        guard rule.contains("{") else { return rule }
        var out = ""
        var i = rule.startIndex
        while i < rule.endIndex {
            guard rule[i] == "{" else {
                out.append(rule[i])
                i = rule.index(after: i)
                continue
            }
            // 向内平衡查找配对 }
            var j = rule.index(after: i)
            var depth = 1
            var inner = ""
            var closed = false
            while j < rule.endIndex {
                let c = rule[j]
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { closed = true; break }
                }
                inner.append(c)
                j = rule.index(after: j)
            }
            if closed {
                let trimmed = inner.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("$") || trimmed.hasPrefix("@") {
                    out.append(resolver(trimmed))
                } else {
                    out.append("{")
                    out.append(inner)
                    out.append("}")
                }
                i = rule.index(after: j)
            } else {
                out.append(String(rule[i...]))
                break
            }
        }
        return out
    }
}
