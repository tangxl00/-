//
//  RuleEvaluator.swift
//  ReaderCore
//
//  规则求值流水线。严格按架构文档二·二的四步顺序：
//    分段 → 段内 $n 回填 → {{}}（嵌套规则优先于 JS）→ @get → @put → ##替换
//    → HTML 实体反转义（仅当含 &）→ 相对 URL 绝对化
//
//  三个算子（架构文档二·四：`&&`、`||`、`%%` 在 Default / XPath / JSONPath 上同样生效）：
//    · `||` 备选：依次求值，返回第一个非空结果（书源里最常见的 `A||B` 兜底写法）
//    · `&&` 并列：列表语境下把两侧元素合并；字符串语境下取第一个非空（与 || 行为一致）
//    · `%%` 拼接：两侧均对同一源求值，结果按顺序直接拼接
//  说明：架构文档只列出这三个算子存在、未给出逐字语义，上述语义是本实现的解释，
//  已在《实现说明》里作为偏差/假设单列，并有单测固化行为。
//
//  JS 段：Tier B 经 jsRuntime 求值（@js: / <js> 段、{{}} 内 JS 表达式）；
//  jsRuntime 为 nil（未接入运行时）或遇到 @webjs 时仍显式抛 jsUnsupported。
//  JSRuntimeError（缺方法 / 超时 / 同步桥失败）原样上抛，绝不静默返回空串。
//

import Foundation
import SwiftSoup

// MARK: - 算子拆分

enum RuleOperators {
    /// 在顶层（跳过 {{ }} / [] / () 内部，跳过 JS 尾段）按 token 拆分。
    static func splitTopLevel(_ rule: String, _ token: String) -> [String] {
        // 含 <js> 或 @js: 时不拆：一旦出现 JS 尾段，后面整体归 JS，拆分只会制造误判
        if rule.contains("@js:") || rule.contains("<js>") { return [rule] }
        guard rule.contains(token) else { return [rule] }

        var parts: [String] = []
        var current = ""
        var i = rule.startIndex
        var braceDepth = 0
        var bracketDepth = 0
        var parenDepth = 0
        while i < rule.endIndex {
            if rule[i] == "{", rule.index(after: i) < rule.endIndex, rule[rule.index(after: i)] == "{" {
                braceDepth += 1
                current.append("{{")
                i = rule.index(i, offsetBy: 2)
                continue
            }
            if rule[i] == "}", braceDepth > 0, rule.index(after: i) < rule.endIndex,
               rule[rule.index(after: i)] == "}" {
                braceDepth -= 1
                current.append("}}")
                i = rule.index(i, offsetBy: 2)
                continue
            }
            let c = rule[i]
            if c == "[" { bracketDepth += 1 }
            if c == "]" { bracketDepth = max(0, bracketDepth - 1) }
            if c == "(" { parenDepth += 1 }
            if c == ")" { parenDepth = max(0, parenDepth - 1) }

            if braceDepth == 0, bracketDepth == 0, parenDepth == 0,
               rule[i...].hasPrefix(token) {
                parts.append(current)
                current = ""
                i = rule.index(i, offsetBy: token.count)
                continue
            }
            current.append(c)
            i = rule.index(after: i)
        }
        parts.append(current)
        return parts
    }
}

// MARK: - 求值器

public struct RuleEvaluator: Sendable {

    /// P0 恒为 nil。P1 接入 JSRuntime 后由这里驱动 JS 段。
    public var jsRuntime: JSRuntime?

    public init(jsRuntime: JSRuntime? = nil) {
        self.jsRuntime = jsRuntime
    }

    // MARK: 公开入口

    /// 单值求值。未命中返回空串（对齐 legado 的 getString 口径，调用方可据此判断命中）。
    public func evaluate(rule: String, in ctx: EvalContext) throws -> String {
        let values = try run(rule: rule, ctx: ctx.materializingBuiltinVariables(), isList: false)
        // 多元素命中：字段文本按 legado getString 口径用 \n 连接；URL 类字段取第一个非空
        var text: String
        if ctx.isURL {
            text = values.first(where: { !$0.isEmpty }) ?? values.first ?? ""
        } else {
            text = values.count > 1 ? values.joined(separator: "\n") : (values.first ?? "")
        }
        text = HTMLEntities.decode(text, onlyIfNeeded: true)
        if ctx.isURL {
            text = URLResolution.absolute(text, base: ctx.baseURL)
        }
        return text
    }

    /// 列表求值（返回文本列表）。
    public func evaluateList(rule: String, in ctx: EvalContext) throws -> [String] {
        var values = try run(rule: rule, ctx: ctx.materializingBuiltinVariables(), isList: true)
        values = values.map { HTMLEntities.decode($0, onlyIfNeeded: true) }
        if ctx.isURL {
            values = values.map { URLResolution.absolute($0, base: ctx.baseURL) }
        }
        return values
    }

    /// 列表求值，但每个元素保留为可再求值的源（搜索列表 / 目录列表用）。
    /// 这样 Domain 层可以对每个条目再跑字段规则（名称 / 作者 / 链接），而不必接触 SwiftSoup 类型。
    ///
    /// v1.2.0 修正（P1#1）：原实现对「多段 / 含 @put / 含 ##替换」的列表规则**静默退回
    /// 纯文本列表**，调用方再对文本做字段规则必然取空且不报错。现在按算子结构递归求值，
    /// 确实无法做元素级求值的形态显式抛 `RuleEvalError.selectorFailed`：
    ///   · `||` 备选：逐分支求值，第一个非空胜出（保持元素态）
    ///   · `&&` 并列：两侧元素合并（保持元素态）
    ///   · `%%` 拼接：字符串语义，结果必然是单个文本源（按定义不是降级）
    ///   · `-` 前缀：元素列表倒序
    ///   · JS 段 / 多段 / `@put` / `##替换`：显式报错并带定位片段
    public func evaluateListSources(rule: String, in baseCtx: EvalContext) throws -> [EvalSource] {
        try listSources(rule: rule, ctx: baseCtx.materializingBuiltinVariables(), depth: 0)
    }

    private func listSources(rule: String, ctx: EvalContext, depth: Int) throws -> [EvalSource] {
        guard depth <= 8 else { throw RuleEvalError.recursionLimit }
        var text = rule
        var reverse = false
        if text.hasPrefix("-") {
            reverse = true
            text = String(text.dropFirst())
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [ctx.source]
        }

        let orParts = RuleOperators.splitTopLevel(text, "||")
        if orParts.count > 1 {
            for part in orParts {
                let r = try listSources(rule: part, ctx: ctx, depth: depth + 1)
                if !r.isEmpty { return r }
            }
            return []
        }

        let andParts = RuleOperators.splitTopLevel(text, "&&")
        if andParts.count > 1 {
            var merged: [EvalSource] = []
            for part in andParts {
                merged += try listSources(rule: part, ctx: ctx, depth: depth + 1)
            }
            return merged
        }

        let concatParts = RuleOperators.splitTopLevel(text, "%%")
        if concatParts.count > 1 {
            var joined = ""
            for part in concatParts {
                joined += (try? evaluate(rule: part, in: ctx)) ?? ""
            }
            return [EvalSource.detect(joined, baseURL: ctx.baseURL)]
        }

        let segments = RuleParser.parse(text)
        guard segments.count == 1, let seg = segments.first, seg.kind == .plain else {
            throw RuleEvalError.selectorFailed(
                "列表规则含 JS 或多段，无法产出可逐项求值的元素：\(text.prefix(48))"
            )
        }
        guard seg.puts.isEmpty, seg.replacement == nil else {
            throw RuleEvalError.selectorFailed(
                "列表规则含 @put / ##替换，无法产出可逐项求值的元素：\(text.prefix(48))"
            )
        }

        var elements: [EvalSource] = []
        switch seg.mode {
        case .default:
            guard let root = ctx.source.elementRoot() else { break }
            let found = try DefaultSelector.evaluateElements(rule: seg.rule, from: [root])
            if !found.isEmpty {
                elements = found.map {
                    EvalSource(kind: .html, text: (try? $0.outerHtml()) ?? "", element: $0, baseURL: ctx.baseURL)
                }
            }
        case .xpath:
            // XPathSelector.nodes 直接返回可再求值的源（元素 / 属性值 / 文本节点三形态）
            let nodes = try XPathSelector.nodes(rule: seg.rule, html: ctx.source.text)
            elements = nodes.map { $0.withBaseURL(ctx.baseURL) }
        case .json:
            guard let json = ctx.source.jsonValue() else { break }
            let nodes = try JsonPath.query(seg.rule, on: json)
            if !nodes.isEmpty {
                elements = nodes.map { EvalSource.json($0, baseURL: ctx.baseURL) }
            }
        case .regex:
            break
        }

        if elements.isEmpty {
            // 元素级未命中：正则模式与「选择器未命中」按文本列表口径兜底
            elements = try evaluateList(rule: text, in: ctx).map {
                EvalSource.detect($0, baseURL: ctx.baseURL)
            }
        }
        return reverse ? Array(elements.reversed()) : elements
    }

    // MARK: 算子层

    private func run(rule: String, ctx: EvalContext, isList: Bool) throws -> [String] {
        guard ctx.depth <= 8 else { throw RuleEvalError.recursionLimit }
        // `-` 前缀 = 结果反转（chapterList 倒序目录用）
        var text = rule
        var reverse = false
        if text.hasPrefix("-") {
            reverse = true
            text = String(text.dropFirst())
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return isList ? [] : [ctx.source.text]
        }

        // ① `||` 备选：第一个非空结果胜出
        let orParts = RuleOperators.splitTopLevel(text, "||")
        if orParts.count > 1 {
            for part in orParts {
                let v = try run(rule: part, ctx: ctx, isList: isList)
                if !isEmptyResult(v) { return v }
            }
            return []
        }

        // ② `&&` 并列
        let andParts = RuleOperators.splitTopLevel(text, "&&")
        if andParts.count > 1 {
            if isList {
                var merged: [String] = []
                for part in andParts {
                    merged += try run(rule: part, ctx: ctx, isList: true)
                }
                return merged
            }
            for part in andParts {
                let v = try run(rule: part, ctx: ctx, isList: false)
                if !isEmptyResult(v) { return v }
            }
            return []
        }

        // ③ `%%` 拼接
        let concatParts = RuleOperators.splitTopLevel(text, "%%")
        if concatParts.count > 1 {
            var out = ""
            for part in concatParts {
                out += try run(rule: part, ctx: ctx, isList: false).first ?? ""
            }
            return [out]
        }

        let values = try runSegments(text, ctx: ctx, isList: isList)
        return reverse ? Array(values.reversed()) : values
    }

    private func isEmptyResult(_ v: [String]) -> Bool {
        if v.isEmpty { return true }
        return v.allSatisfy { $0.isEmpty }
    }

    // MARK: 分段层

    private func runSegments(_ rule: String, ctx startCtx: EvalContext, isList: Bool) throws -> [String] {
        let segments = RuleParser.parse(rule)
        guard !segments.isEmpty else { return isList ? [] : [startCtx.source.text] }

        var ctx = startCtx
        var lastValues: [String] = []

        for (idx, seg) in segments.enumerated() {
            switch seg.kind {
            case .webJs:
                // Tier C：WebView 注入类，保持显式不支持
                throw RuleEvalError.jsUnsupported("@webjs")

            case .js, .jsTail:
                // Tier B：经 JSRuntime 求值（未接入运行时仍显式抛错，不静默）
                guard let jsRuntime else {
                    throw RuleEvalError.jsUnsupported(seg.kind == .js ? "<js>" : "@js:")
                }
                let prior = lastValues.joined(separator: "\n")
                var values = try evaluateJSSegment(
                    seg.rule, runtime: jsRuntime, ctx: ctx, prior: prior, isList: isList
                )
                // 末段后处理对齐普通段：实体反转义（仅当含 &）
                values = values.map { HTMLEntities.decode($0, onlyIfNeeded: true) }
                lastValues = values

                let isLastSegment = (idx == segments.count - 1)
                if !isLastSegment {
                    // JS 输出作为下一段输入源
                    let joined = values.joined(separator: "\n")
                    ctx = ctx.withSource(EvalSource.detect(joined, baseURL: ctx.baseURL))
                }

            case .plain:
                // ① @put:{key:rule} —— 求值后写入变量表（对当前源）
                for put in seg.puts {
                    let v = try evaluate(rule: put.rule, in: ctx.nested())
                    ctx.variables[put.key] = v
                }

                var body = seg.rule
                // ② $1..$99 回填（仅当已有捕获组；否则原样保留，避免破坏 ## 替换模板）
                if let groups = ctx.regexGroups, !groups.isEmpty {
                    body = RuleEvaluator.substituteGroups(body, groups: groups)
                }
                // ③ {{}} —— 嵌套规则优先，非规则内容视为 JS
                body = try substituteBraces(body, ctx: ctx)
                // ④ @get:{key}
                body = RuleEvaluator.substituteGet(body, store: ctx.variables)

                let isLast = idx == segments.count - 1
                let listMode = isList && isLast
                // 纯模板段（整段只是 {{...}} / @get:{...}）：替换结果就是取值本身，
                // 不能再当下钻选择器跑（否则变量值 "hello" 会被当元素名查空）
                let pure = RuleEvaluator.isPureSubstitutionTemplate(seg.rule)
                var values = pure
                    ? [body]
                    : try evalPlain(body, mode: seg.mode, source: ctx.source, isList: listMode)

                // ⑤ ##匹配##替换##
                if let rep = seg.replacement {
                    values = values.map {
                        RegexUtil.replace($0,
                                          pattern: rep.pattern,
                                          replacement: rep.replacement,
                                          firstOnly: rep.replaceFirstOnly)
                    }
                }
                // ⑥ 实体反转义（仅当含 &）
                values = values.map { HTMLEntities.decode($0, onlyIfNeeded: true) }
                lastValues = values

                if !isLast {
                    // 上一段结果作为下一段输入源
                    let joined = values.joined(separator: "\n")
                    ctx = ctx.withSource(EvalSource.detect(joined, baseURL: ctx.baseURL))
                }
            }
        }
        return lastValues
    }

    // MARK: JS 求值（Tier B，任务模块一）

    /// 从求值上下文构造 JS 绑定（13 全局对象的输入面 + jsLib）。
    private func makeJSBindings(_ ctx: EvalContext, result: String) -> JSBindings {
        JSBindings(
            source: ctx.source.text,
            result: result,
            baseUrl: ctx.baseURL ?? "",
            bookName: ctx.book?.name,
            bookAuthor: ctx.book?.author,
            chapterTitle: ctx.chapter?.title,
            nextChapterUrl: ctx.nextChapterURL,
            fromBookInfo: ctx.isFromBookInfo,
            variables: ctx.variables.values,
            jsLib: ctx.jsLib,
            book: ctx.book,
            chapter: ctx.chapter
        )
    }

    /// `@js:` / `<js>...</js>` 段求值。JSRuntimeError（缺方法 / 超时 / 网络桥失败）
    /// 原样上抛，由 Domain 层转成用户可读信息。
    private func evaluateJSSegment(_ script: String, runtime: JSRuntime,
                                   ctx: EvalContext, prior: String, isList: Bool) throws -> [String] {
        let v = try runtime.evaluate(script, bindings: makeJSBindings(ctx, result: prior), timeout: .seconds(10))
        return Self.jsResultToValues(v, isList: isList)
    }

    /// `{{...}}` 内 JS 表达式（非嵌套规则、非已声明变量时）。
    /// 绑定口径：source / result 均为当前求值源文本（解释性实现，已在实现说明登记）。
    private func evaluateJSExpression(_ expr: String, runtime: JSRuntime, ctx: EvalContext) throws -> String {
        let v = try runtime.evaluate(expr, bindings: makeJSBindings(ctx, result: ctx.source.text), timeout: .seconds(10))
        return Self.jsResultToValues(v, isList: false).first ?? ""
    }

    /// JS 返回值折算为文本/列表：数组在列表语境逐元素、单值语境按行连接。
    static func jsResultToValues(_ v: Any?, isList: Bool) -> [String] {
        guard let v else { return isList ? [] : [""] }
        if let arr = v as? [Any] {
            let texts = arr.map(Self.jsScalarToString)
            return isList ? texts : [texts.joined(separator: "\n")]
        }
        let s = Self.jsScalarToString(v)
        return isList ? [s] : [s]
    }

    static func jsScalarToString(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let n = v as? Double {
            if n.truncatingRemainder(dividingBy: 1) == 0, abs(n) < 1e15 {
                return String(Int64(n))
            }
            return String(n)
        }
        if v is NSNull { return "" }
        return String(describing: v)
    }

    // MARK: 单段模式分发

    private func evalPlain(_ rule: String, mode: RuleMode, source: EvalSource, isList: Bool) throws -> [String] {
        switch mode {
        case .default:
            // 字面 URL 兜底：规则本身就是 URL（经 $n 回填 / {{}} 替换后）时直接返回，
            // 不能当 CSS 选择器下钻（legado 同此口径）
            let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://")
                || (trimmed.contains("://") && !trimmed.contains("@")) {
                return [trimmed]
            }
            guard let root = source.elementRoot() else {
                // 纯文本源：规则无处可下钻，按 legado 的兜底返回源本身
                return isList ? [] : [source.text]
            }
            if rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return isList ? [] : [source.text]
            }
            return try DefaultSelector.evaluate(rule: rule, from: [root], isList: isList)

        case .xpath:
            return try XPathSelector.evaluate(rule: rule, html: source.text, isList: isList)

        case .json:
            guard let json = source.jsonValue() else { return [] }
            let nodes = try JsonPath.query(rule, on: json)
            guard !nodes.isEmpty else { return [] }
            if isList { return nodes.map { $0.text } }
            return [nodes.first?.text ?? ""]

        case .regex:
            guard let re = RegexUtil.compile(rule) else {
                throw RuleEvalError.selectorFailed("正则模式无法编译：\(rule)")
            }
            let ns = source.text as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = re.matches(in: source.text, options: [], range: full)
            guard !matches.isEmpty else { return [] }
            var out: [String] = []
            for m in matches {
                // 有捕获组取第 1 组，否则取整个匹配
                let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
                out.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            return isList ? out : [out.first ?? ""]
        }
    }

    // MARK: 段内替换

    /// `{{...}}`：内容以 @ / $. / $[ / // 开头按嵌套规则求值；
    /// 是已声明变量则替换；其余内容 legado 按 JS 求值 → P0 抛不支持。
    private func substituteBraces(_ rule: String, ctx: EvalContext) throws -> String {
        guard rule.contains("{") else { return rule }
        var out = rule
        // ① `{{...}}` 双括号模板
        if out.contains("{{") {
            out = try replaceDoubleBraces(out, ctx: ctx)
        }
        // ② `{$.rule}` / `{@css:...}` 单括号嵌套规则
        if out.contains("{") {
            out = try JsonNested.replacingNestedThrowing(in: out) { inner in
                let t = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { return "" }
                if t.hasPrefix("@") || t.hasPrefix("//") || t.hasPrefix("/") {
                    return try self.evaluate(rule: t, in: ctx.nested())
                }
                if t.hasPrefix("$.") || t.hasPrefix("$[") {
                    if let json = ctx.source.jsonValue() {
                        return JsonPath.firstString(t, on: json)
                    }
                    return ""
                }
                if let rt = jsRuntime {
                    return try evaluateJSExpression(t, runtime: rt, ctx: ctx)
                }
                throw RuleEvalError.jsUnsupported("{\(t.prefix(24))}")
            }
        }
        return out
    }

    /// 双括号模板扫描替换。找不到配对 `}}` 时原样保留。
    private func replaceDoubleBraces(_ input: String, ctx: EvalContext) throws -> String {
        var out = ""
        var i = input.startIndex
        while i < input.endIndex {
            guard input[i] == "{",
                  let next = input.index(i, offsetBy: 1, limitedBy: input.endIndex),
                  next < input.endIndex, input[next] == "{" else {
                out.append(input[i])
                i = input.index(after: i)
                continue
            }
            let bodyStart = input.index(after: next)
            guard let close = input.range(of: "}}", range: bodyStart..<input.endIndex) else {
                // 无配对：原样保留剩余部分
                out.append(input[i])
                i = input.index(after: i)
                continue
            }
            let inner = String(input[bodyStart..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 规则形态：以规则标记开头，或体内含 @ / $.（如「#kw@value」这类默认语法）
            let ruleLike = inner.hasPrefix("@") || inner.hasPrefix("//") || inner.hasPrefix("/")
                || inner.hasPrefix("$.") || inner.hasPrefix("$[")
                || inner.contains("@") || inner.contains("$.")
            if inner.isEmpty {
                out.append("")
            } else if inner.hasPrefix("@") || inner.hasPrefix("//") || inner.hasPrefix("/") {
                out.append(try evaluate(rule: inner, in: ctx.nested()))
            } else if inner.hasPrefix("$.") || inner.hasPrefix("$[") {
                if let json = ctx.source.jsonValue() {
                    out.append(JsonPath.firstString(inner, on: json))
                }
            } else if ruleLike {
                // 含规则标记但非显式前缀（默认语法，如「#kw@value」）→ 按规则求值
                out.append(try evaluate(rule: inner, in: ctx.nested()))
            } else if let v = ctx.variables[inner] {
                out.append(v)
            } else if let rt = jsRuntime {
                // 非规则、非已声明变量 → legado 按 JS 求值（Tier B）
                out.append(try evaluateJSExpression(inner, runtime: rt, ctx: ctx))
            } else {
                throw RuleEvalError.jsUnsupported("{{\(inner.prefix(24))}}")
            }
            i = close.upperBound
        }
        return out
    }

    /// 整段是否只由 `{{...}}` / `@get:{...}` 模板构成（替换结果即取值本身）。
    static func isPureSubstitutionTemplate(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        var i = t.startIndex
        while i < t.endIndex {
            if t[i...].hasPrefix("{{") {
                let bodyStart = t.index(after: i)
                guard let close = t.range(of: "}}", range: bodyStart..<t.endIndex) else {
                    return false
                }
                i = close.upperBound
            } else if t[i...].hasPrefix("@get:{") {
                // 跳过 "@get:{" 共 6 个字符，j 指向 '{' 之后
                var j = i
                for _ in 0..<6 { j = t.index(after: j) }
                var depth = 1
                var closed = false
                while j < t.endIndex {
                    if t[j] == "{" { depth += 1 }
                    if t[j] == "}" {
                        depth -= 1
                        if depth == 0 { closed = true; break }
                    }
                    j = t.index(after: j)
                }
                guard closed else { return false }
                i = t.index(after: j)
            } else {
                return false
            }
        }
        return true
    }

    /// `$1..$99` 单遍扫描替换，避免 `$1` 与 `$10` 的顺序碰撞。
    static func substituteGroups(_ text: String, groups: [String]) -> String {
        guard text.contains("$") else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "$" {
                var j = text.index(after: i)
                guard j < text.endIndex, text[j].isNumber else {
                    out.append("$")
                    i = text.index(after: i)
                    continue
                }
                var digits = ""
                while j < text.endIndex, text[j].isNumber {
                    digits.append(text[j])
                    j = text.index(after: j)
                }
                let n = Int(digits) ?? 0
                out.append(n >= 0 && n < groups.count ? groups[n] : "")
                i = j
                continue
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }

    /// `@get:{key}` 与 `@get:key`
    static func substituteGet(_ text: String, store: VariableStore) -> String {
        guard text.contains("@get:") else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i...].hasPrefix("@get:") else {
                out.append(text[i])
                i = text.index(after: i)
                continue
            }
            let after = text.index(i, offsetBy: 5)
            if after < text.endIndex, text[after] == "{" {
                // 括号平衡取 key
                var j = text.index(after: after)
                var depth = 1
                var key = ""
                var closed = false
                while j < text.endIndex {
                    let c = text[j]
                    if c == "{" { depth += 1 }
                    if c == "}" {
                        depth -= 1
                        if depth == 0 { closed = true; break }
                    }
                    key.append(c)
                    j = text.index(after: j)
                }
                if closed {
                    out.append(store[key.trimmingCharacters(in: .whitespaces)] ?? "")
                    i = text.index(after: j)
                    continue
                }
                out.append("@get:")
                i = after
                continue
            }
            // 裸 key：到下一个 @ 或空白为止
            var j = after
            var key = ""
            while j < text.endIndex, text[j] != "@", !text[j].isWhitespace, text[j] != "/" {
                key.append(text[j])
                j = text.index(after: j)
            }
            out.append(store[key.trimmingCharacters(in: .whitespaces)] ?? "")
            i = j
        }
        return out
    }
}

// MARK: - 结果文本清洗

/// 正文与字段的纯文本化。P0 不做替换净化（那是 P1），
/// 但需求 P0-4 要求「无 HTML 标签残留、实体已反转义」，这两条在这里兜底：
/// 有些站点的 content 规则命中后返回的其实是 HTML 片段（尤其 JSON 接口 + regex 模式）。
public enum TextCleaner {
    public static func toPlainText(_ raw: String) -> String {
        var s = raw
        // 块级标签 → 换行；<br> → 换行
        s = s.replacingOccurrences(of: "<br\\s*\\/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</(p|div|li|tr|h[1-6])>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<(p|div|li|tr|h[1-6])(\\s[^>]*)?>", with: "", options: .regularExpression)
        // 残留标签
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // 实体
        s = HTMLEntities.decode(s, onlyIfNeeded: true)
        // scripts 残留（极少见，防一手）
        s = s.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        // 逐行 trim
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // 连续空行收敛为单空行
        while s.contains("\n\n\n") {
            s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 段落化：把正文按空行/单行切成段落数组（阅读层按段落渲染，P0-4「按段落渲染」）。
    public static func paragraphs(_ raw: String) -> [String] {
        let plain = toPlainText(raw)
        guard !plain.isEmpty else { return [] }
        let blocks = plain.components(separatedBy: "\n")
        var out: [String] = []
        for rawLine in blocks {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if out.last != "" { out.append("") }
                continue
            }
            out.append(line)
        }
        while out.last == "" { out.removeLast() }
        // 若全文没有换行（单块），再按中文句号兜底分段？不做：
        // 需求 4-1 要求「段落数与站点原文段落数一致（±0）」，靠换行才是可信信号。
        return out
    }
}
