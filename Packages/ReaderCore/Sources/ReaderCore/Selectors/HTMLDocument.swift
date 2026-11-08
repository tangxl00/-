//
//  HTMLDocument.swift
//  ReaderCore
//
//  DOM 容器与取值动作。Default 与 XPath 两个后端共用同一套节点表示，
//  这样「取 text / html / attr」的语义只需要实现一次。
//

import Foundation
import SwiftSoup

/// 取值动作。legado 的集合是固定五个 + 属性名兜底。
public enum ExtractAction: Sendable, Equatable {
    case text
    case textNodes
    case ownText
    case html
    case all
    case attr(String)

    /// 解析末段字符串为取值动作；无法判定时返回 nil（交给上层按选择器处理）。
    public static func parse(_ raw: String) -> ExtractAction? {
        switch raw {
        case "text": return .text
        case "textNodes": return .textNodes
        case "ownText": return .ownText
        case "html": return .html
        case "all": return .all
        default: return nil
        }
    }
}

/// 一个已解析的 HTML 文档。`source` 保留原始 HTML，供 XPath 修补复用。
/// SwiftSoup 的 Element 是引用类型且非 Sendable，这里标记 @unchecked：
/// 文档只在单次求值会话内使用，不跨并发域共享。
public struct HTMLDocument: @unchecked Sendable {
    public let element: Element
    public let source: String

    public init(html: String) throws {
        self.source = html
        self.element = try SwiftSoup.parse(html)
    }

    public init(element: Element, source: String) {
        self.element = element
        self.source = source
    }

    /// 文档根（html 元素）。
    public var root: Element { element }
}

// MARK: - 取值

public enum NodeExtractor {
    /// 对一个元素取单值文本（用于字段取值的默认行为）。
    public static func extract(_ action: ExtractAction, from element: Element) throws -> String {
        switch action {
        case .text:
            return try cleanedText(element)
        case .textNodes:
            var out: [String] = []
            for node in element.getChildNodes() {
                if let t = node as? TextNode {
                    let s = t.getWholeText()
                    if !s.isEmpty { out.append(s) }
                }
            }
            return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        case .ownText:
            return element.ownText().trimmingCharacters(in: .whitespacesAndNewlines)
        case .html:
            return try cleanedHTML(element)
        case .all:
            return try element.outerHtml()
        case .attr(let name):
            return (try? element.attr(name)) ?? ""
        }
    }

    /// 取完整文本。legado 的 `text` 语义（Jsoup text()）：行内元素拼接、
    /// 块级元素边界换行，块内空白归一为单空格。
    static func cleanedText(_ element: Element) throws -> String {
        var lines: [String] = []
        var current = ""
        for node in element.getChildNodes() {
            appendNodeText(node, current: &current, lines: &lines)
        }
        flushLine(&current, into: &lines)
        if lines.isEmpty {
            return try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var text = lines.joined(separator: "\n")
        // 压缩连续空行
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "blockquote", "pre", "dd", "dt", "ul", "ol", "table", "hr"
    ]

    private static func flushLine(_ current: inout String, into lines: inout [String]) {
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { lines.append(t) }
        current = ""
    }

    /// 文本节点与行内元素并入当前行；块级元素 / `<br>` 先收行再递归。
    private static func appendNodeText(_ node: Node, current: inout String, lines: inout [String]) {
        if let t = node as? TextNode {
            current += normalizeWhitespace(t.getWholeText())
            return
        }
        guard let el = node as? Element else { return }
        let tag = el.tagName().lowercased()
        if tag == "br" {
            flushLine(&current, into: &lines)
            return
        }
        if blockTags.contains(tag) {
            flushLine(&current, into: &lines)
            for child in el.getChildNodes() {
                appendNodeText(child, current: &current, lines: &lines)
            }
            flushLine(&current, into: &lines)
            return
        }
        // 行内元素：继续并入当前行
        for child in el.getChildNodes() {
            appendNodeText(child, current: &current, lines: &lines)
        }
    }

    /// 块内空白归一：连续空白压成单个空格（对齐 Jsoup text()）。
    private static func normalizeWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `html` 动作：先移除 script / style（legado 明确行为）。
    static func cleanedHTML(_ element: Element) throws -> String {
        var copy = element
        // SwiftSoup 没有 clone，直接在节点上移除后再输出（调用方传入的是一次性文档时可行，
        // 为安全这里重新解析一次）
        copy = try SwiftSoup.parse(element.outerHtml()).body() ?? element
        for script in try copy.select("script") { try script.remove() }
        for style in try copy.select("style") { try style.remove() }
        return try copy.html()
    }
}
