//
//  JSStaticScan.swift
//  ReaderCore
//
//  导入时 JS 静态扫描（任务裁决第 1 条 / 需求 2-5、4-5）。
//
//  作用：在**不执行 JS** 的前提下，判断一条书源的哪些规则会用到 JS，
//  以及用到哪些 `java.xxx` 扩展方法，从而（P1 升级为能力探测报告，任务模块一第 5 条）：
//    · 书源仍可导入、可运行（Tier B 降级兼容），导入结果里列出「用到 N 个方法，
//      其中 x/y 本版未实现，相关字段可能异常」；
//    · 运行到缺失方法时抛带方法名的 JS 异常（JSRuntimeError.missingMethod），
//      由 UI 呈现「该步骤需要 JS 能力 x，本版未实现」；
//    · @webjs / webView / loginUi 仍是 Tier C，显式标记不支持。
//
//  扫描面（对齐架构文档二·二、二·五）：
//    · `@js:`、`<js>...</js>`、`@webjs:` —— 出现在规则串里即算 JS 段；
//    · `java.xxx` 方法名 —— 提取出来与已实现清单比对；
//    · `webJs` 字段、`loginUi`、`coverDecodeJs`、`jsLib`、`preUpdateJs`、`formatJs`、
//      `callBackJs`、`loginCheckJs` —— 这些字段本身语义就是 JS（或 WebView 注入），
//      即便字段值里没有 `@js:` 标记也算含 JS 能力依赖。
//

import Foundation

// MARK: - 扫描结果

public struct JSStaticScanResult: Sendable, Equatable {
    /// 是否依赖 JS（任一规则 / 字段命中）
    public var usesJS: Bool
    /// 命中的位置说明，例如 "ruleSearch.bookList"、"ruleContent.content"
    public var hits: [JSHit]
    /// 提取到的 java.xxx 方法名（去重、小写保留原样）
    public var javaMethods: [String]
    /// javaMethods 里本版未实现的（与 JSJavaBridge.implementedMethods 比对）
    public var missingMethods: [String]
    /// 是否用到 WebView 注入（`@webjs:` / `webJs` 字段）—— Tier C，明确不支持
    public var usesWebJS: Bool

    public init(usesJS: Bool = false,
                hits: [JSHit] = [],
                javaMethods: [String] = [],
                missingMethods: [String] = [],
                usesWebJS: Bool = false) {
        self.usesJS = usesJS
        self.hits = hits
        self.javaMethods = javaMethods
        self.missingMethods = missingMethods
        self.usesWebJS = usesWebJS
    }

    /// 给用户看的一句话（导入结果 / 搜索结果提示用）。
    /// P1 能力探测口径：书源可导入可运行，只报告缺项；@webjs 仍是 Tier C。
    public var userFacingReason: String {
        if !usesJS { return "" }
        if usesWebJS {
            return "该源依赖 WebView 注入（@webjs / webJs），本版明确不支持，相关字段不可用"
        }
        if javaMethods.isEmpty {
            return "该源规则含 JS，本版可执行（Tier B 降级兼容）"
        }
        if missingMethods.isEmpty {
            return "该源用到 \(javaMethods.count) 个 JS 方法，本版已全部实现（Tier B）"
        }
        let missing = missingMethods.map { "java.\($0)" }.joined(separator: "、")
        return "该源用到 \(javaMethods.count) 个 JS 方法，其中 \(missing) 本版未实现，"
            + "相关字段可能异常（该源仍可导入运行，运行到缺失步骤会有明确提示）"
    }
}

public struct JSHit: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case jsRule      // 规则串里出现 @js: / <js>
        case webJsRule   // 规则串里出现 @webjs:
        case jsField     // 字段本身语义是 JS（如 jsLib / formatJs）
        case javaMethod  // 出现 java.xxx 调用
    }
    public var kind: Kind
    /// 形如 "ruleSearch.bookList"
    public var location: String
    /// 命中片段（便于排查）
    public var snippet: String

    public init(kind: Kind, location: String, snippet: String) {
        self.kind = kind
        self.location = location
        self.snippet = snippet
    }
}

// MARK: - 已实现的 java.* 能力清单
//
//  P0 一个都没实现（不做 JS 执行）。这个清单留空的意义是：
//  P1 接入时把已实现的方法填进来，扫描器就会自动算出「缺哪个方法」，
//  导入提示从"整源不支持"细化为"缺 java.ajax / java.base64Decode"。
//  架构文档 R1 明确要求这条：静态比对清单比运行时静默失败好排查一个数量级。
public enum JSCapabilityRegistry {
    /// P1：JSJavaBridge 已实现的 20 个方法（任务模块一第 4 条的高频子集）。
    public static let implementedMethods: Set<String> = JSJavaBridge.implementedMethods
    /// 架构文档二·五列出的全部 66 个方法名，用于识别「这是 java 扩展调用」而不是随便一个标识符。
    public static let knownMethods: Set<String> = [
        // 网络
        "ajax", "ajaxAll", "ajaxTestAll", "connect", "head", "post",
        "webView", "webViewGetSource", "webViewGetOverrideUrl",
        // 编解码
        "base64Encode", "base64Decode", "base64DecodeToByteArray",
        "hexEncodeToString", "hexDecodeToString", "hexDecodeToByteArray",
        "strToBytes", "bytesToStr", "encodeURI", "htmlFormat", "toURL",
        // 文本
        "t2s", "s2t", "replaceFont", "getVerificationCode", "toNumChapter",
        "timeFormat", "timeFormatUTC", "randomUUID", "getTxtInFolder",
        // 文件与压缩
        "readTxtFile", "readFile", "writeFile", "deleteFile", "getFile", "cacheFile",
        "unzipFile", "un7zFile", "unrarFile", "unArchiveFile",
        "getZipStringContent", "get7zStringContent", "getRarStringContent",
        "getZipByteArrayContent", "get7zByteArrayContent", "getRarByteArrayContent",
        // 应用与交互
        "toast", "longToast", "log", "logType", "openUrl",
        "startBrowser", "startBrowserAwait", "importScript",
        "getReadBookConfig", "getThemeConfig", "getWebViewUA",
        "queryTTF", "queryBase64TTF",
        // 其他常见（上游 JsExtensions 里同时存在、按能力归类）
        "getCookie", "setCookie", "clearCookie", "md5Encode", "md5Encode16",
        "digestHex", "aesBase64", "desBase64", "desDecode", "rsaEncode",
    ]

    public static func missing(_ method: String) -> Bool {
        !implementedMethods.contains(method)
    }
}

// MARK: - 扫描器

public enum JSStaticScanner {

    /// 规则串里的 JS 标记
    private static let jsMarkers = ["@js:", "<js>", "@webjs:"]

    /// java.xxx 方法名提取（`java.` 后可跟标识符）
    private static let javaCallRegex = try! NSRegularExpression(
        pattern: "java\\.([A-Za-z_][A-Za-z0-9_]*)", options: []
    )

    /// 扫一条规则串（位置标签用于报给用户）。
    public static func scanRule(_ rule: String?, location: String) -> [JSHit] {
        guard let rule, !rule.isEmpty else { return [] }
        var hits: [JSHit] = []
        if rule.contains("@webjs:") {
            hits.append(JSHit(kind: .webJsRule, location: location, snippet: "@webjs:"))
        }
        if rule.contains("@js:") {
            hits.append(JSHit(kind: .jsRule, location: location, snippet: "@js:"))
        }
        if rule.contains("<js>") {
            hits.append(JSHit(kind: .jsRule, location: location, snippet: "<js>"))
        }
        for m in javaCallRegex.matches(in: rule, range: NSRange(rule.startIndex..., in: rule)) {
            guard let r = Range(m.range(at: 1), in: rule) else { continue }
            let method = String(rule[r])
            hits.append(JSHit(kind: .javaMethod, location: location, snippet: "java.\(method)"))
        }
        return hits
    }

    /// 扫一条「字段本身就是 JS」的值（如 jsLib / formatJs）。
    public static func scanJSField(_ value: String?, location: String) -> [JSHit] {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var hits = [JSHit(kind: .jsField, location: location, snippet: firstLine(value))]
        for m in javaCallRegex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let r = Range(m.range(at: 1), in: value) else { continue }
            let method = String(value[r])
            hits.append(JSHit(kind: .javaMethod, location: location, snippet: "java.\(method)"))
        }
        return hits
    }

    private static func firstLine(_ s: String) -> String {
        let line = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    /// 扫整条书源。这是导入流程调用的入口。
    public static func scan(_ source: BookSource) -> JSStaticScanResult {
        var hits: [JSHit] = []

        // ① 五套规则里的每个字段
        let sr = source.searchRule
        hits += scanRule(sr.bookList, location: "ruleSearch.bookList")
        hits += scanRule(sr.name, location: "ruleSearch.name")
        hits += scanRule(sr.author, location: "ruleSearch.author")
        hits += scanRule(sr.intro, location: "ruleSearch.intro")
        hits += scanRule(sr.kind, location: "ruleSearch.kind")
        hits += scanRule(sr.lastChapter, location: "ruleSearch.lastChapter")
        hits += scanRule(sr.updateTime, location: "ruleSearch.updateTime")
        hits += scanRule(sr.bookUrl, location: "ruleSearch.bookUrl")
        hits += scanRule(sr.coverUrl, location: "ruleSearch.coverUrl")
        hits += scanRule(sr.wordCount, location: "ruleSearch.wordCount")
        hits += scanRule(sr.checkKeyWord, location: "ruleSearch.checkKeyWord")

        let er = source.exploreRule
        hits += scanRule(er.bookList, location: "ruleExplore.bookList")
        hits += scanRule(er.name, location: "ruleExplore.name")
        hits += scanRule(er.author, location: "ruleExplore.author")
        hits += scanRule(er.intro, location: "ruleExplore.intro")
        hits += scanRule(er.kind, location: "ruleExplore.kind")
        hits += scanRule(er.lastChapter, location: "ruleExplore.lastChapter")
        hits += scanRule(er.updateTime, location: "ruleExplore.updateTime")
        hits += scanRule(er.bookUrl, location: "ruleExplore.bookUrl")
        hits += scanRule(er.coverUrl, location: "ruleExplore.coverUrl")
        hits += scanRule(er.wordCount, location: "ruleExplore.wordCount")
        hits += scanRule(er.pageParam, location: "ruleExplore.pageParam")

        let bi = source.bookInfoRule
        hits += scanRule(bi.`init`, location: "ruleBookInfo.init")
        hits += scanRule(bi.name, location: "ruleBookInfo.name")
        hits += scanRule(bi.author, location: "ruleBookInfo.author")
        hits += scanRule(bi.intro, location: "ruleBookInfo.intro")
        hits += scanRule(bi.kind, location: "ruleBookInfo.kind")
        hits += scanRule(bi.lastChapter, location: "ruleBookInfo.lastChapter")
        hits += scanRule(bi.updateTime, location: "ruleBookInfo.updateTime")
        hits += scanRule(bi.coverUrl, location: "ruleBookInfo.coverUrl")
        hits += scanRule(bi.tocUrl, location: "ruleBookInfo.tocUrl")
        hits += scanRule(bi.wordCount, location: "ruleBookInfo.wordCount")
        hits += scanRule(bi.canReName, location: "ruleBookInfo.canReName")
        hits += scanRule(bi.downloadUrls, location: "ruleBookInfo.downloadUrls")
        hits += scanRule(bi.relatedBooks, location: "ruleBookInfo.relatedBooks")

        let tr = source.tocRule
        hits += scanRule(tr.chapterList, location: "ruleToc.chapterList")
        hits += scanRule(tr.chapterName, location: "ruleToc.chapterName")
        hits += scanRule(tr.chapterUrl, location: "ruleToc.chapterUrl")
        hits += scanRule(tr.isVolume, location: "ruleToc.isVolume")
        hits += scanRule(tr.isVip, location: "ruleToc.isVip")
        hits += scanRule(tr.isPay, location: "ruleToc.isPay")
        hits += scanRule(tr.updateTime, location: "ruleToc.updateTime")
        hits += scanRule(tr.nextTocUrl, location: "ruleToc.nextTocUrl")
        hits += scanJSField(tr.preUpdateJs, location: "ruleToc.preUpdateJs")
        hits += scanJSField(tr.formatJs, location: "ruleToc.formatJs")

        let cr = source.contentRule
        hits += scanRule(cr.content, location: "ruleContent.content")
        hits += scanRule(cr.subContent, location: "ruleContent.subContent")
        hits += scanRule(cr.title, location: "ruleContent.title")
        hits += scanRule(cr.nextContentUrl, location: "ruleContent.nextContentUrl")
        hits += scanRule(cr.sourceRegex, location: "ruleContent.sourceRegex")
        hits += scanRule(cr.replaceRegex, location: "ruleContent.replaceRegex")
        hits += scanJSField(cr.webJs, location: "ruleContent.webJs")
        hits += scanJSField(cr.imageDecode, location: "ruleContent.imageDecode")
        hits += scanJSField(cr.callBackJs, location: "ruleContent.callBackJs")
        hits += scanJSField(cr.payAction, location: "ruleContent.payAction")

        // ② 书源级 JS 字段
        hits += scanJSField(source.jsLib, location: "jsLib")
        hits += scanJSField(source.coverDecodeJs, location: "coverDecodeJs")
        hits += scanJSField(source.loginCheckJs, location: "loginCheckJs")
        hits += scanJSField(source.loginUi, location: "loginUi")

        // ③ 去重：同 (kind, location, snippet) 只留一条
        var seen = Set<String>()
        var unique: [JSHit] = []
        for h in hits {
            let key = "\(h.kind.rawValue)|\(h.location)|\(h.snippet)"
            if seen.insert(key).inserted { unique.append(h) }
        }

        let methods = Array(Set(unique.filter { $0.kind == .javaMethod }
            .compactMap { h -> String? in
                let s = h.snippet
                guard s.hasPrefix("java.") else { return nil }
                return String(s.dropFirst(5))
            })).sorted()

        let webJs = unique.contains { $0.kind == .webJsRule }
        let missing = methods.filter { JSCapabilityRegistry.missing($0) }
        return JSStaticScanResult(usesJS: !unique.isEmpty,
                                  hits: unique,
                                  javaMethods: methods,
                                  missingMethods: missing,
                                  usesWebJS: webJs)
    }
}
