//
//  SearchService.swift
//  ReaderCore
//
//  多书源并发搜索（P0-2 / 需求 2-6 ~ 2-8）。
//
//  三个关键点：
//    1. **并发**：默认 8 路（需求建议值），用 TaskGroup 控制。每个源的失败/超时
//       互不影响 —— 一个源抛错不取消其他源。
//    2. **单源超时**：每个源独立 60s 超时（不是整体超时）。实现方式：
//       每个子任务内部用 `withThrowingTaskGroup` 包一层「请求任务 + 超时任务」，
//       谁先完成用谁的结果，超时即抛 `TimeoutError`。
//       注意：不用 `Task.sleep` 作整体超时后再取消，因为 URLSession 的取消
//       在 Linux 与 iOS 语义有差异；内部竞争超时更可靠。
//    3. **分桶状态**：每个源最终落到 success/empty/failed/timedOut/unsupported 之一。
//       `unsupported` 的源不发请求（含 JS / 非文本类型），但要在结果里显式列出，
//       否则用户会以为「搜了没结果」。
//

import Foundation

// MARK: - 错误

public enum SearchError: Error, CustomStringConvertible, Sendable {
    case timeout(seconds: Int)
    case ruleMissing(String)
    case ruleFailed(String)
    case unsupported(String)
    case http(String)

    public var description: String {
        switch self {
        case .timeout(let s): return "超时（\(s)s）"
        case .ruleMissing(let f): return "书源缺少必要规则：\(f)"
        case .ruleFailed(let m): return "规则求值失败：\(m)"
        case .unsupported(let m): return m
        case .http(let m): return m
        }
    }
}

// MARK: - 搜索配置

public struct SearchConfig: Sendable {
    /// 并发上限（需求建议默认 8）
    public var maxConcurrency: Int
    /// 单源超时（秒）
    public var perSourceTimeout: Int

    public init(maxConcurrency: Int = 8, perSourceTimeout: Int = 60) {
        self.maxConcurrency = maxConcurrency
        self.perSourceTimeout = perSourceTimeout
    }

    public static let `default` = SearchConfig()
}

// MARK: - 服务

public struct SearchService: Sendable {
    public var client: HTTPClient
    public var evaluator: RuleEvaluator
    public var config: SearchConfig

    public init(
        client: HTTPClient = HTTPClient(),
        evaluator: RuleEvaluator = RuleEvaluator(),
        config: SearchConfig = .default
    ) {
        self.client = client
        self.evaluator = evaluator
        self.config = config
    }

    // MARK: 主入口

    /// 对一批书源并发搜索。
    /// - Parameters:
    ///   - keyword: 搜索词
    ///   - sources: 参与搜索的书源（调用方负责过滤 enabled）
    ///   - unsupportedSources: 已判定为不可用的源（非文本类型），会原样列入 outcomes；
    ///     含 JS 的源属 Tier B 降级兼容，**参与搜索**（不再预置为不可用）
    public func search(
        keyword: String,
        sources: [BookSource],
        unsupportedSources: [BookSource] = [],
        onOutcome: (@Sendable (SourceSearchOutcome) -> Void)? = nil
    ) async -> SearchReport {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchReport(keyword: keyword, outcomes: [], merged: [], truncatedCount: 0)
        }

        // 预置不可用源
        var outcomes: [SourceSearchOutcome] = unsupportedSources.map { src in
            let scan = JSStaticScanner.scan(src)
            let reason: String
            if !src.isTextSource {
                reason = "该源为\(src.unsupportedTypeDescription ?? "非文本")类型，本版本不支持"
            } else if scan.usesJS {
                reason = scan.userFacingReason
            } else {
                reason = "该源本版本不支持"
            }
            return SourceSearchOutcome(
                sourceKey: src.bookSourceUrl,
                sourceName: src.bookSourceName,
                state: .unsupported,
                errorMessage: reason
            )
        }

        // Tier B：含 JS 的源参与搜索（缺方法时运行到才报精确缺项，不再一刀切排除）
        let usable = sources.filter { $0.isTextSource }

        // 并发执行：用 TaskGroup + 信号量式并发控制
        let results = await runConcurrently(
            sources: usable,
            keyword: trimmed,
            limit: max(1, config.maxConcurrency),
            onOutcome: onOutcome
        )
        outcomes.append(contentsOf: results)

        let allItems = results.flatMap(\.items)
        let (merged, truncated) = BookMerger.merge(allItems, keyword: trimmed)

        return SearchReport(
            keyword: trimmed,
            outcomes: outcomes,
            merged: merged,
            truncatedCount: truncated
        )
    }

    // MARK: 并发控制

    /// 流式并发：最多 `limit` 个源同时在跑，任一个完成立刻消费，并补一个新的进来。
    ///
    /// v1.2.0 修正（P1#10）：旧实现是「分批屏障」——一批 8 个全部完成才开下一批，
    /// 总耗时约 ceil(N/8)×单源超时（N 源各卡 60s 时可到十几分钟），且第一个结果
    /// 也要等整批。现在改为滑动窗口，单源超时只影响它自己。
    private func runConcurrently(
        sources: [BookSource],
        keyword: String,
        limit: Int,
        onOutcome: (@Sendable (SourceSearchOutcome) -> Void)? = nil
    ) async -> [SourceSearchOutcome] {
        guard !sources.isEmpty else { return [] }
        var out: [SourceSearchOutcome] = []
        out.reserveCapacity(sources.count)
        let window = max(1, limit)

        await withTaskGroup(of: SourceSearchOutcome.self) { group in
            var next = 0
            while next < min(window, sources.count) {
                let src = sources[next]
                next += 1
                group.addTask { await self.searchOne(source: src, keyword: keyword) }
            }
            while let r = await group.next() {
                out.append(r)
                onOutcome?(r)
                if next < sources.count {
                    let src = sources[next]
                    next += 1
                    group.addTask { await self.searchOne(source: src, keyword: keyword) }
                }
            }
        }
        return out
    }

    // MARK: 单源搜索

    func searchOne(source: BookSource, keyword: String) async -> SourceSearchOutcome {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        let rule = source.searchRule
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            return SourceSearchOutcome(
                sourceKey: source.bookSourceUrl, sourceName: source.bookSourceName,
                state: .failed, errorMessage: "书源缺少 searchUrl", elapsedMs: elapsed()
            )
        }
        guard let listRule = rule.bookList, !listRule.isEmpty else {
            return SourceSearchOutcome(
                sourceKey: source.bookSourceUrl, sourceName: source.bookSourceName,
                state: .failed, errorMessage: "书源缺少 ruleSearch.bookList", elapsedMs: elapsed()
            )
        }

        do {
            // ① URL 模板求值（{{key}} / {{page}} + 选项 JSON）
            let analyzed = try URLTemplateEngine.analyze(
                template: searchUrl,
                vars: ["key": keyword, "page": "1"],
                evaluator: evaluator,
                ctx: EvalContext(
                    source: EvalSource.text(""),
                    variables: VariableStore(["key": keyword, "page": "1"]),
                    jsLib: source.jsLib
                )
            )

            // ② 发请求（带单源超时）
            let resp = try await fetchWithTimeout(
                analyzed: analyzed,
                sourceKey: source.bookSourceUrl,
                seconds: config.perSourceTimeout,
                cookieJarEnabled: source.enabledCookieJar
            )

            // ③ 列表求值 + 字段求值
            let ctx = EvalContext(
                source: EvalSource.detect(resp.text, baseURL: resp.finalURL),
                baseURL: resp.finalURL,
                variables: VariableStore(builtinVariables(book: nil, chapter: nil)),
                isFromBookInfo: false,
                jsLib: source.jsLib
            )
            let listSources = try evaluator.evaluateListSources(rule: listRule, in: ctx)
            var items: [SearchResultItem] = []
            items.reserveCapacity(listSources.count)

            // P1#5：字段求值失败必须归因（条目序号 + 字段名 + 原因），不许 `try?` 吞成空串
            var fieldErrors: [String] = []
            var skipped = 0

            func field(_ label: String, _ ruleText: String?, element: EvalSource, url: Bool = false) -> String {
                guard let ruleText, !ruleText.isEmpty else { return "" }
                var c = ctx.withSource(element)
                if url { c.isURL = true }
                do {
                    return try evaluator.evaluate(rule: ruleText, in: c)
                } catch {
                    fieldErrors.append("\(label) 求值失败（\(Self.describe(error))）")
                    return ""
                }
            }

            func optionalField(_ label: String, _ ruleText: String?, element: EvalSource, url: Bool = false) -> String? {
                let v = field(label, ruleText, element: element, url: url)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }

            for (index, element) in listSources.enumerated() {
                let name = field("name", rule.name, element: element)
                let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanName.isEmpty else {
                    skipped += 1
                    continue
                }
                let author = field("author", rule.author, element: element)
                // 详情页链接必填；取不到就跳过（否则后续无法进详情）
                let bookUrl = field("bookUrl", rule.bookUrl, element: element, url: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !bookUrl.isEmpty else {
                    skipped += 1
                    fieldErrors.append("第 \(index + 1) 条 bookUrl 为空（规则未命中）")
                    continue
                }

                items.append(
                    SearchResultItem(
                        name: cleanName,
                        author: author.trimmingCharacters(in: .whitespacesAndNewlines),
                        bookUrl: bookUrl,
                        origin: source.bookSourceUrl,
                        originName: source.bookSourceName,
                        coverUrl: optionalField("coverUrl", rule.coverUrl, element: element, url: true),
                        intro: optionalField("intro", rule.intro, element: element),
                        kind: optionalField("kind", rule.kind, element: element),
                        lastChapter: optionalField("lastChapter", rule.lastChapter, element: element),
                        updateTime: optionalField("updateTime", rule.updateTime, element: element),
                        wordCount: optionalField("wordCount", rule.wordCount, element: element)
                    )
                )
            }

            // 失败原因必须能被解释：空结果的 reason 里带上字段错误与跳过条数
            var notes: [String] = []
            if skipped > 0 { notes.append("跳过 \(skipped) 条（name/bookUrl 未命中）") }
            if !fieldErrors.isEmpty {
                let head = Array(fieldErrors.prefix(5)).joined(separator: "；")
                let tail = fieldErrors.count > 5 ? "；等共 \(fieldErrors.count) 项" : ""
                notes.append(head + tail)
            }
            let reason: String?
            if items.isEmpty {
                reason = "请求成功但规则未命中任何条目（可能是站点改版或规则不匹配）"
                    + (notes.isEmpty ? "" : "；" + notes.joined(separator: "；"))
            } else {
                reason = notes.isEmpty ? nil : "部分条目异常：" + notes.joined(separator: "；")
            }
            return SourceSearchOutcome(
                sourceKey: source.bookSourceUrl, sourceName: source.bookSourceName,
                state: items.isEmpty ? .empty : .success,
                items: items,
                errorMessage: reason,
                elapsedMs: elapsed()
            )
        } catch {
            return SourceSearchOutcome(
                sourceKey: source.bookSourceUrl, sourceName: source.bookSourceName,
                state: .failed,
                errorMessage: Self.describe(error),
                elapsedMs: elapsed()
            )
        }
    }

    // MARK: 超时包装

    /// 请求 + 超时竞争。
    private func fetchWithTimeout(
        analyzed: AnalyzedUrl,
        sourceKey: String,
        seconds: Int,
        cookieJarEnabled: Bool = false
    ) async throws -> HTTPResponse {
        // P1-18（v1.2.0）修复：Box 被网络任务与计时任务两个并发任务写 finished，
        // 旧实现无锁（@unchecked Sendable 只是让编译器闭嘴）。所有读写经 NSLock 串行化。
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: HTTPResponse?
            private var _error: Error?

            var value: HTTPResponse? {
                lock.lock(); defer { lock.unlock() }
                return _value
            }
            var error: Error? {
                lock.lock(); defer { lock.unlock() }
                return _error
            }
            func complete(value: HTTPResponse?) {
                lock.lock(); defer { lock.unlock() }
                if _value == nil { _value = value }
            }
            func complete(error: Error?) {
                lock.lock(); defer { lock.unlock() }
                if _error == nil { _error = error }
            }
        }
        let box = Box()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    let r = try await self.client.fetch(
                        analyzed: analyzed,
                        sourceKey: sourceKey,
                        cookieJarEnabled: cookieJarEnabled
                    )
                    box.complete(value: r)
                } catch {
                    box.complete(error: error)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
            }
            // 等第一个完成的（计时任务只负责让 group.next() 提前返回触发 cancelAll）
            try await group.next()
            group.cancelAll()
        }

        if let r = box.value { return r }
        if let e = box.error { throw e }
        throw SearchError.timeout(seconds: seconds)
    }

    // MARK: 工具

    static func describe(_ error: Error) -> String {
        if let e = error as? SearchError { return e.description }
        if let e = error as? HTTPError { return e.description }
        if let e = error as? RuleEvalError {
            switch e {
            case .jsUnsupported(let r): return "规则含 JS 且当前未接入 JS 运行时：\(r)"
            case .selectorFailed(let m): return "选择器不匹配：\(m)"
            case .recursionLimit: return "规则递归过深"
            }
        }
        if let e = error as? TXTImportError { return e.description }
        if let e = error as? JSRuntimeError { return e.description }
        return error.localizedDescription
    }
}

/// 内置变量：让 `{{book.name}}` / `{{chapter.title}}` 在规则里可用。
public func builtinVariables(
    book: BookSnapshot?,
    chapter: ChapterSnapshot?
) -> [String: String] {
    var v: [String: String] = [:]
    if let book {
        v["book.name"] = book.name
        v["book.author"] = book.author
        v["book.bookUrl"] = book.bookUrl
        v["book.origin"] = book.origin
        if let t = book.tocUrl { v["book.tocUrl"] = t }
        if let k = book.kind { v["book.kind"] = k }
        if let i = book.intro { v["book.intro"] = i }
        if let c = book.coverUrl { v["book.coverUrl"] = c }
    }
    if let chapter {
        v["chapter.title"] = chapter.title
        v["chapter.url"] = chapter.url
        v["chapter.index"] = String(chapter.index)
    }
    return v
}
