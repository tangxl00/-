//
//  URLTemplate.swift
//  ReaderCore
//
//  URL 模板与请求构造（架构文档二·六）。
//
//  两件事：
//    1. `{{key}}` / `{{page}}` 模板替换 + 百分号编码（需求 2-3）。
//       legado 的做法是：模板里的 `{{key}}` 整体替换成已 encode 的关键词，
//       而模板自带的 `?a=b&c=d` 部分保持原样（否则会把 & 也编码掉，请求就废了）。
//       因此这里按「模板已被拆成 query 参数 key/value」的语义做替换：
//       - 若 `{{key}}` 出现在 `=` 之后的值位置 → 只对插入值做编码（保留模板结构）
//       - 若出现在路径位置 → 同样只对插入值编码
//    2. URL 后的选项 JSON（第一个逗号之后）：method / charset / headers / body / retry /
//       type / js / bodyJs / dnsIp。
//
//  重要：URL 本身可能含逗号（如某些站点的 query 里带 `,`），所以「第一个逗号」的判断必须
//  只看「逗号后面是不是 JSON 对象」——直接 split 会切错。这里用「从右往左找 {」+ 括号平衡判定。
//

import Foundation

// MARK: - URL 选项

public struct UrlOption: Sendable, Equatable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        public var display: String { rawValue }
    }

    public var method: Method?
    public var charset: String?
    public var headers: [String: String]?
    public var body: String?
    public var origin: String?
    public var retry: Int?
    public var type: String?
    public var webView: Bool?
    public var webJs: String?
    public var dnsIp: String?
    public var js: String?
    public var bodyJs: String?
    public var serverID: String?
    public var webViewDelayTime: Int?

    public init() {}

    public var effectiveMethod: Method { method ?? .get }

    public init(json: JsonValue) {
        guard case .object(let o) = json else { return }
        func str(_ k: String) -> String? {
            if case .string(let s)? = o[k] { return s }
            if case .number(let n)? = o[k] { return String(Int(n)) }
            return nil
        }
        func int(_ k: String) -> Int? {
            if case .number(let n)? = o[k] { return Int(n) }
            if case .string(let s)? = o[k] { return Int(s) }
            return nil
        }
        func bool(_ k: String) -> Bool? {
            if case .bool(let b)? = o[k] { return b }
            if case .string(let s)? = o[k] { return s == "true" || s == "1" }
            return nil
        }
        method = str("method").map { $0.uppercased() == "POST" ? .post : .get }
        charset = str("charset")
        if case .object(let h)? = o["headers"] {
            var d: [String: String] = [:]
            for (k, v) in h {
                if case .string(let s) = v { d[k] = s }
                else if case .number(let n) = v { d[k] = String(Int(n)) }
            }
            headers = d
        }
        body = str("body")
        origin = str("origin")
        retry = int("retry")
        type = str("type")
        webView = bool("webView")
        webJs = str("webJs")
        dnsIp = str("dnsIp")
        js = str("js")
        bodyJs = str("bodyJs")
        serverID = str("serverID")
        webViewDelayTime = int("webViewDelayTime")
    }
}

// MARK: - 分析结果

public struct AnalyzedUrl: Sendable, Equatable {
    /// 已替换模板并编码的 URL（不含选项部分）
    public var url: String
    public var option: UrlOption
    /// 是否为 POST
    public var isPost: Bool { option.effectiveMethod == .post }

    public init(url: String, option: UrlOption) {
        self.url = url
        self.option = option
    }
}

// MARK: - 模板引擎

public enum URLTemplateEngine {

    /// 百分号编码：保留 RFC 3986 的 unreserved 字符，其余全部编码。
    /// 与 `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)` 的区别：
    /// 后者会保留 `&`、`=`、`+`，用在 query 值里就会出现参数注入，
    /// 这里对「插入值」用严格的 allowed 集。
    public static func encodeValue(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// 路径段编码（保留 `/`，因为模板里 `{{key}}` 允许插到路径中，值本身一般不含 `/`）。
    public static func encodePathValue(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// 判断 `{{...}}` 出现的位置是否是「路径中」还是「query 值中」。
    /// 做法：看该占位之前最后一个分隔符是 `=`（值中）还是 `?`/`&`/`/`（路径或参数名中）。
    private static func isValuePosition(_ text: String, upTo index: String.Index) -> Bool {
        var i = index
        while i > text.startIndex {
            i = text.index(before: i)
            let c = text[i]
            if c == "=" { return true }
            if c == "?" || c == "&" || c == "/" { return false }
        }
        return false
    }

    /// 替换模板。`vars` 里的 key 对应 `{{key}}`；未提供的 key 替换为空串。
    public static func apply(template: String, vars: [String: String]) -> String {
        guard template.contains("{{") else { return template }
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            guard template[i...].hasPrefix("{{") else {
                out.append(template[i])
                i = template.index(after: i)
                continue
            }
            guard let close = template.range(of: "}}", range: template.index(i, offsetBy: 2)..<template.endIndex) else {
                out.append(String(template[i...]))
                break
            }
            let key = String(template[template.index(i, offsetBy: 2)..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if let value = vars[key] {
                out.append(encodeValue(value))
            } else if Self.looksLikeRule(key) {
                // 非变量、但形如规则的模板（{{@css:…}} / {{$…}} 等）：
                // 保留原样，交给 query / body 阶段的规则求值（对齐 legado 的 {{}} 语义）
                out.append(String(template[i..<close.upperBound]))
            } else {
                out.append("")
            }
            i = close.upperBound
        }
        return out
    }

    /// 模板内容是否「形如规则」而非变量名。
    static func looksLikeRule(_ key: String) -> Bool {
        key.contains("@") || key.contains("$.") || key.hasPrefix("$[")
            || key.hasPrefix("//") || key.hasPrefix("/") || key.hasPrefix("js:")
    }

    /// 拆出 URL 与选项 JSON。
    /// 规则：从右向左找第一个 `{`，若其后括号平衡且能解析成 JSON 对象，
    /// 且它在某个逗号之后，则把它前面的逗号视作「URL 与选项的分隔符」。
    public static func splitOption(_ raw: String) -> (urlPart: String, optionJson: JsonValue?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // legado 语义：选项 JSON 是「紧跟在某个逗号之后、并一直延伸到串尾」的平衡对象。
        // 逐个逗号找第一个满足条件的 `,{`；嵌套对象（如 headers）与 URL 自带的逗号都天然兼容。
        var searchStart = text.startIndex
        while let comma = text[searchStart...].firstIndex(of: ",") {
            let after = text.index(after: comma)
            if after < text.endIndex, text[after] == "{" {
                var depth = 0
                var i = after
                var closedAt: String.Index?
                while i < text.endIndex {
                    if text[i] == "{" { depth += 1 }
                    if text[i] == "}" {
                        depth -= 1
                        if depth == 0 { closedAt = i; break }
                    }
                    i = text.index(after: i)
                }
                if let close = closedAt, text.index(after: close) == text.endIndex,
                   case .object? = JsonValue.parse(String(text[after...close])) {
                    let urlPart = String(text[text.startIndex..<comma])
                        .trimmingCharacters(in: .whitespaces)
                    return (urlPart, JsonValue.parse(String(text[after...close])))
                }
            }
            searchStart = text.index(after: comma)
        }
        return (text, nil)
    }

    /// 完整分析：模板替换 → 选项解析 → GET query 逐参数求值 / POST 表单逐字段求值。
    /// - Parameters:
    ///   - template: 原始书源 URL 模板（含 {{key}} 与可能的选项 JSON）
    ///   - vars: 模板变量（key / page 等）
    ///   - evaluator: 用于对 query / body 里的规则求值
    ///   - ctx: 求值上下文
    public static func analyze(template: String,
                               vars: [String: String],
                               evaluator: RuleEvaluator,
                               ctx: EvalContext) throws -> AnalyzedUrl {
        let (urlTemplate, optionJson) = splitOption(template)
        var option = optionJson.map { UrlOption(json: $0) } ?? UrlOption()

        // ① 模板替换
        var url = apply(template: urlTemplate, vars: vars)
        url = url.trimmingCharacters(in: .whitespacesAndNewlines)

        // ② `js` 选项：解析完 URL 后执行，结果回写为新 URL（Tier B，任务模块一）
        if let js = option.js, !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let rt = evaluator.jsRuntime else {
                throw RuleEvalError.jsUnsupported("UrlOption.js")
            }
            let bindings = JSBindings(
                source: url,
                result: url,
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
            let v = try rt.evaluate(js, bindings: bindings, timeout: .seconds(10))
            let newURL = RuleEvaluator.jsScalarToString(v ?? "")
            if !newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // WebView 注入类：Tier C 明确不支持
        if let webJs = option.webJs, !webJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RuleEvalError.jsUnsupported("UrlOption.webJs")
        }
        if option.webView == true {
            throw RuleEvalError.jsUnsupported("UrlOption.webView")
        }
        // ③ bodyJs：拿到响应后二次处理 —— 本版不执行响应后 JS（记录在案，
        //    AnalyzedUrl.option.bodyJs 原样保留，供上层标注能力缺口），不阻断请求。

        // ④ GET：query 逐参数求值；POST：body 逐字段求值
        if option.effectiveMethod == .get {
            url = try rewriteQuery(url, evaluator: evaluator, ctx: ctx)
        } else if let body = option.body {
            // body 里含 `{{`/`@` 才是规则，否则原样（可能是 JSON 字符串）
            if body.contains("{{") || body.contains("@") {
                let rewritten = try rewriteFormBody(body, evaluator: evaluator, ctx: ctx)
                option.body = rewritten
            }
        }

        return AnalyzedUrl(url: url, option: option)
    }

    /// GET query 逐参数求值：把每个参数值当规则跑一次（值里没有规则标记就原样保留）。
    private static func rewriteQuery(_ url: String,
                                     evaluator: RuleEvaluator,
                                     ctx: EvalContext) throws -> String {
        guard let qIndex = url.firstIndex(of: "?") else { return url }
        let head = String(url[url.startIndex...qIndex])
        let query = String(url[url.index(after: qIndex)...])
        guard !query.isEmpty else { return url }
        var pairs: [String] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let p = String(pair)
            guard let eq = p.firstIndex(of: "=") else {
                pairs.append(p)
                continue
            }
            let name = String(p[p.startIndex..<eq])
            var value = String(p[p.index(after: eq)...])
            // 已编码的值里 `%` 已存在，规则标记则不会编码（`{{` 会被编码成 %7B%7B），
            // 所以这里只需判断原始标记是否还在。
            if value.contains("{{") || value.hasPrefix("@") || value.contains("$.") {
                let decoded = value.removingPercentEncoding ?? value
                if decoded.contains("{{") || decoded.hasPrefix("@") || decoded.contains("$.") {
                    let v = try evaluator.evaluate(rule: decoded, in: ctx)
                    value = encodeValue(v)
                }
            }
            pairs.append("\(name)=\(value)")
        }
        return head + pairs.joined(separator: "&")
    }

    /// POST 表单逐字段求值。也处理 JSON body（对 JSON 的每个字符串值求值）。
    private static func rewriteFormBody(_ body: String,
                                        evaluator: RuleEvaluator,
                                        ctx: EvalContext) throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            // JSON body：只对含规则标记的字符串值求值
            if var json = JsonValue.parse(trimmed) {
                json = try rewriteJSONRules(json, evaluator: evaluator, ctx: ctx)
                return JsonValue.encodeCompact(json) ?? body
            }
            return body
        }
        var parts: [String] = []
        for field in body.split(separator: "&", omittingEmptySubsequences: false) {
            let f = String(field)
            guard let eq = f.firstIndex(of: "=") else { parts.append(f); continue }
            let name = String(f[f.startIndex..<eq])
            let raw = String(f[f.index(after: eq)...]).removingPercentEncoding ?? String(f[f.index(after: eq)...])
            let v = try evaluator.evaluate(rule: raw, in: ctx)
            parts.append("\(name)=\(encodeValue(v))")
        }
        return parts.joined(separator: "&")
    }

    private static func rewriteJSONRules(_ v: JsonValue,
                                         evaluator: RuleEvaluator,
                                         ctx: EvalContext) throws -> JsonValue {
        switch v {
        case .string(let s):
            if s.contains("{{") || s.hasPrefix("@") || s.contains("$.") {
                return .string(try evaluator.evaluate(rule: s, in: ctx))
            }
            return v
        case .array(let a):
            var out: [JsonValue] = []
            for item in a { out.append(try rewriteJSONRules(item, evaluator: evaluator, ctx: ctx)) }
            return .array(out)
        case .object(let o):
            var out: [String: JsonValue] = [:]
            for (k, item) in o { out[k] = try rewriteJSONRules(item, evaluator: evaluator, ctx: ctx) }
            return .object(out)
        default:
            return v
        }
    }
}
