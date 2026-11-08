//
//  EvalContext.swift
//  ReaderCore
//
//  规则求值的输入源与上下文。
//
//  一条规则的多段（`@css:...&&@xpath:...`）是链式的：上一段的输出是下一段的输入，
//  因此上下文里的「源」必须是可替换的。这里用一个引用类型 EvalSource 承载三种源
//  （纯文本 / HTML(已解析 DOM) / JSON），变量表用一个引用类型 VariableStore 承载，
//  保证同一次求值里 @put 写入的变量能被后续字段读到。
//

import Foundation
import SwiftSoup

// MARK: - 书籍 / 章节快照（只读，供 {{book.x}} 类变量与回调上下文使用）

public struct BookSnapshot: Sendable, Equatable {
    public var name: String
    public var author: String
    public var bookUrl: String
    public var origin: String
    public var tocUrl: String?
    public var kind: String?
    public var intro: String?
    public var coverUrl: String?
    public var latestChapterTitle: String?

    public init(name: String,
                author: String,
                bookUrl: String,
                origin: String,
                tocUrl: String? = nil,
                kind: String? = nil,
                intro: String? = nil,
                coverUrl: String? = nil,
                latestChapterTitle: String? = nil) {
        self.name = name
        self.author = author
        self.bookUrl = bookUrl
        self.origin = origin
        self.tocUrl = tocUrl
        self.kind = kind
        self.intro = intro
        self.coverUrl = coverUrl
        self.latestChapterTitle = latestChapterTitle
    }
}

public struct ChapterSnapshot: Sendable, Equatable {
    public var title: String
    public var url: String
    public var index: Int
    public var baseUrl: String?

    public init(title: String, url: String, index: Int, baseUrl: String? = nil) {
        self.title = title
        self.url = url
        self.index = index
        self.baseUrl = baseUrl
    }
}

// MARK: - 源

/// 求值输入源。三条互斥的承载方式，按需预解析。
/// SwiftSoup 的 Element 与 JsonValue 都是值语义安全的（Element 是引用但不跨并发域），
/// 因此整体标 @unchecked Sendable，与 HTMLDocument 的注释同理由。
public final class EvalSource: @unchecked Sendable {
    public enum Kind: String, Sendable {
        case text        // 纯文本
        case html        // HTML 片段，附已解析 DOM
        case json        // JSON 值
    }

    public let kind: Kind
    /// 原始文本（html 源时是 HTML 字符串，JSON 源时是压缩后的 JSON 文本）
    public let text: String
    public let element: Element?
    public let json: JsonValue?
    /// 相对 URL 的基准（当前页面的最终地址）
    public let baseURL: String?

    public init(kind: Kind, text: String, element: Element? = nil, json: JsonValue? = nil, baseURL: String? = nil) {
        self.kind = kind
        self.text = text
        self.element = element
        self.json = json
        self.baseURL = baseURL
    }

    /// 从任意文本智能判定源类型：JSON 对象/数组优先，其次含 `<` 视为 HTML。
    public static func detect(_ raw: String, baseURL: String? = nil) -> EvalSource {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let v = JsonValue.parse(trimmed) {
                return EvalSource(kind: .json, text: raw, json: v, baseURL: baseURL)
            }
        }
        if let el = try? SwiftSoup.parse(raw) {
            return EvalSource(kind: .html, text: raw, element: el, baseURL: baseURL)
        }
        return EvalSource(kind: .text, text: raw, baseURL: baseURL)
    }

    public static func text(_ raw: String, baseURL: String? = nil) -> EvalSource {
        EvalSource(kind: .text, text: raw, baseURL: baseURL)
    }

    public static func html(_ raw: String, baseURL: String? = nil) throws -> EvalSource {
        let el = try SwiftSoup.parse(raw)
        return EvalSource(kind: .html, text: raw, element: el, baseURL: baseURL)
    }

    public static func json(_ v: JsonValue, baseURL: String? = nil) -> EvalSource {
        EvalSource(kind: .json, text: v.text, json: v, baseURL: baseURL)
    }

    /// JSON 源解析（文本源尝试一次解析，失败返回 nil）。
    public func jsonValue() -> JsonValue? {
        if let json { return json }
        if kind == .json { return JsonValue.parse(text) }
        return nil
    }

    /// DOM 根（文本源尝试解析，失败返回 nil）。
    public func elementRoot() -> Element? {
        if let element { return element }
        return (kind == .text) ? (try? SwiftSoup.parse(text)) : nil
    }

    public func replacingText(_ newText: String) -> EvalSource {
        EvalSource.detect(newText, baseURL: baseURL)
    }

    /// 带基准 URL 的副本（列表条目再求值时要补上当前页地址）。
    public func withBaseURL(_ url: String?) -> EvalSource {
        EvalSource(kind: kind, text: text, element: element, json: json, baseURL: url)
    }
}

// MARK: - 变量表

/// @put / @get 变量表。引用类型，保证一次求值会话里跨字段可见。
public final class VariableStore: @unchecked Sendable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public func merge(_ other: [String: String]) {
        values.merge(other) { a, _ in a }
    }
}

// MARK: - 上下文

/// 单次规则求值会话的上下文。字段对齐架构文档三·二。
public struct EvalContext: @unchecked Sendable {
    /// 当前源（段链会替换它）
    public var source: EvalSource
    /// 相对 URL 基准
    public var baseURL: String?
    /// 重定向后的真实地址
    public var redirectURL: String?
    /// 变量表（书源级 / 书籍级 / 章节级已合并）
    public let variables: VariableStore
    public var book: BookSnapshot?
    public var chapter: ChapterSnapshot?
    public var nextChapterURL: String?
    public var isFromBookInfo: Bool
    /// 上一次正则匹配的捕获组（供 $1..$99 回填）
    public var regexGroups: [String]?
    /// 该规则是否是 URL 字段（末段结果做相对地址绝对化）
    public var isURL: Bool
    /// 递归深度保护
    public var depth: Int
    /// 书源 jsLib（P1：JS 段求值时先于各规则注入；nil = 无）
    public var jsLib: String?

    public init(source: EvalSource,
                baseURL: String? = nil,
                variables: VariableStore = VariableStore(),
                book: BookSnapshot? = nil,
                chapter: ChapterSnapshot? = nil,
                nextChapterURL: String? = nil,
                isFromBookInfo: Bool = false,
                isURL: Bool = false,
                depth: Int = 0,
                jsLib: String? = nil) {
        self.source = source
        self.baseURL = baseURL ?? source.baseURL
        self.redirectURL = nil
        self.variables = variables
        self.book = book
        self.chapter = chapter
        self.nextChapterURL = nextChapterURL
        self.isFromBookInfo = isFromBookInfo
        self.regexGroups = nil
        self.isURL = isURL
        self.depth = depth
        self.jsLib = jsLib
    }

    /// 换源但保留上下文（段链用）。
    public func withSource(_ s: EvalSource) -> EvalContext {
        var c = self
        c.source = s
        if c.baseURL == nil { c.baseURL = s.baseURL }
        return c
    }

    /// 递归求值（{{}} 嵌套规则用），带深度保护。
    public func nested() -> EvalContext {
        var c = self
        c.depth += 1
        return c
    }

    /// 合并书籍 / 章节到变量表，供 `{{book.name}}`、`{{chapter.title}}` 之类使用。
    public func materializingBuiltinVariables() -> EvalContext {
        var c = self
        if let book {
            c.variables["book.name"] = book.name
            c.variables["book.author"] = book.author
            c.variables["book.bookUrl"] = book.bookUrl
            if let v = book.tocUrl { c.variables["book.tocUrl"] = v }
            if let v = book.latestChapterTitle { c.variables["book.latestChapterTitle"] = v }
            if let v = book.kind { c.variables["book.kind"] = v }
        }
        if let chapter {
            c.variables["chapter.title"] = chapter.title
            c.variables["chapter.url"] = chapter.url
            c.variables["chapter.index"] = String(chapter.index)
        }
        if let nextChapterURL { c.variables["nextChapterUrl"] = nextChapterURL }
        return c
    }
}

// MARK: - 求值错误

public enum RuleEvalError: Error, CustomStringConvertible, Sendable {
    /// 规则含 JS 且当前无 JS 运行时（P0 的确定性结果，不是异常）
    case jsUnsupported(String)
    /// 规则求值本身无法继续（选择器语法错误等）
    case selectorFailed(String)
    /// 递归过深
    case recursionLimit

    public var description: String {
        switch self {
        case .jsUnsupported(let where_):
            return "规则含 JS，本版本不支持（\(where_)）"
        case .selectorFailed(let msg):
            return "规则求值失败：\(msg)"
        case .recursionLimit:
            return "规则嵌套层数过深（>8）"
        }
    }
}

// MARK: - URL 绝对化

public enum URLResolution {
    /// 相对地址绝对化。空串返回空串（不做任何猜测）。
    public static func absolute(_ raw: String, base: String?) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉可能残留的零宽字符
        s = s.replacingOccurrences(of: "\u{200B}", with: "")
        guard !s.isEmpty else { return "" }
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("data:") || s.hasPrefix("mailto:") {
            return s
        }
        guard let base, !base.isEmpty, let baseURL = URL(string: base) else { return s }
        if s.hasPrefix("//") {
            let scheme = baseURL.scheme ?? "https"
            return "\(scheme):\(s)"
        }
        guard let u = URL(string: s, relativeTo: baseURL) else { return s }
        return u.absoluteString
    }
}

public enum RegexUtil {
    /// 编译正则（失败返回 nil，调用方降级为字面量处理）。
    public static func compile(_ pattern: String, ignoreCase: Bool = false) -> NSRegularExpression? {
        var opts: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if ignoreCase { opts.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: opts)
    }

    /// 应用 `##匹配##替换##`。pattern 是正则，replacement 支持 $1..$9。
    public static func replace(_ text: String,
                               pattern: String,
                               replacement: String,
                               firstOnly: Bool) -> String {
        guard let re = compile(pattern) else {
            // 正则非法 → 退回字面量替换，避免整条规则静默失效
            if firstOnly, let r = text.range(of: pattern) {
                return text.replacingCharacters(in: r, with: replacement)
            }
            return text.replacingOccurrences(of: pattern, with: replacement)
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        if firstOnly {
            guard let m = re.firstMatch(in: text, options: [], range: full) else { return text }
            let rep = re.replacementString(for: m, in: text, offset: 0, template: replacement)
            return ns.replacingCharacters(in: m.range, with: rep)
        }
        return re.stringByReplacingMatches(in: text, options: [], range: full, withTemplate: replacement)
    }

    /// 取所有匹配的捕获组（`$n` 回填用）。
    public static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let re = compile(pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }
}
