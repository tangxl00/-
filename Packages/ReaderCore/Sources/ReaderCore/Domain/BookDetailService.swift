//
//  BookDetailService.swift
//  ReaderCore
//
//  详情 + 目录 + 正文（P0-3 / P0-4）。
//
//  三个要点：
//    1. 详情：`ruleBookInfo.init` 常用来做「详情页 → 真实详情页」的跳转
//       （例如搜索给的是搜索页链接，init 规则再取一次）。
//       封面取不到时返回 nil，由 UI 用占位图 —— 绝不返回半截 URL 造成裂图。
//    2. 目录：支持 `nextTocUrl` 分页追加。**失败重试时不能清空已加载部分** ——
//       所以分页拉取是「追加到已有数组」，返回结果里带 `loadedPages` 与 `hasMore`，
//       UI 侧只在 success 时替换/追加，失败时保留原数据。
//    3. 正文：取纯文本，去 HTML 标签、反转义实体；超长章节不截断。
//       解析失败要给「重试 / 打开原网页」两个动作 —— 所以错误里带 `webURL`。
//

import Foundation

// MARK: - 模型

public struct BookDetail: Sendable, Equatable {
    public var name: String
    public var author: String
    public var intro: String
    public var coverUrl: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var wordCount: String?
    /// 目录页 URL（若详情页规则给了 tocUrl 就用它，否则用 bookUrl）
    public var tocUrl: String
    /// 详情页原地址
    public var bookUrl: String
    public var origin: String
    public var originName: String
}

public struct BookChapter: Sendable, Equatable, Identifiable {
    public var id: String { url.isEmpty ? "idx-\(index)" : url }
    public var title: String
    public var url: String
    public var index: Int
    /// 是否 VIP / 付费章节（P0 不绕过，只标记不让用户白点）
    public var isVip: Bool
    public var isPay: Bool
}

/// 目录拉取结果。`chapters` 是「本章已累计的全部章节」，失败重试时调用方应保留旧值。
public struct TocResult: Sendable {
    public var chapters: [BookChapter]
    /// 已加载的分页数
    public var loadedPages: Int
    /// 是否还有下一页
    public var hasMore: Bool
    /// 下一页 URL（hasMore 为真时有效）
    public var nextPageUrl: String?
    /// 本次新追加的条数
    public var appendedCount: Int
    /// 非致命提示（如某页失败但前面已成功）
    public var warnings: [String]

    public init(
        chapters: [BookChapter],
        loadedPages: Int = 1,
        hasMore: Bool = false,
        nextPageUrl: String? = nil,
        appendedCount: Int = 0,
        warnings: [String] = []
    ) {
        self.chapters = chapters
        self.loadedPages = loadedPages
        self.hasMore = hasMore
        self.nextPageUrl = nextPageUrl
        self.appendedCount = appendedCount
        self.warnings = warnings
    }
}

/// 正文结果。
public struct ContentResult: Sendable {
    /// 已清洗的纯文本（无 HTML 标签、实体已反转义）
    public var text: String
    /// 章节标题（规则给了就用规则的，否则用章节列表里的标题）
    public var title: String
    /// 章节内下一页（`nextContentUrl` 用于把一章拆成多页的站点）
    public var nextContentUrl: String?
    /// 原文网页地址（「打开原网页」用）
    public var webURL: String
    public var wordCount: Int
}

public enum BookServiceError: Error, CustomStringConvertible, Sendable {
    case missingRule(String)
    case emptyContent
    /// JS 步骤失败（缺方法 / 超时 / 同步桥网络失败）—— 消息精确到方法名
    case jsFailed(String)
    case unsupported(String)
    case timeout(Int)
    /// 正文解析失败：带上原网页地址，供 UI 提供「重试 / 打开原网页」
    case contentParseFailed(message: String, webURL: String)
    case tocFetchFailed(message: String, pageURL: String)
    case detailFailed(message: String, bookURL: String)
    case network(String)

    public var description: String {
        switch self {
        case .missingRule(let r): return "书源缺少必要规则：\(r)"
        case .emptyContent: return "正文为空（规则未命中或页面结构变化）"
        case .unsupported(let m): return m
        case .timeout(let s): return "请求超时（\(s)s）"
        case .contentParseFailed(let m, _): return "正文解析失败：\(m)"
        case .jsFailed(let m): return m
        case .tocFetchFailed(let m, _): return "目录拉取失败：\(m)"
        case .detailFailed(let m, _): return "详情拉取失败：\(m)"
        case .network(let m): return "网络错误：\(m)"
        }
    }

    /// 是否可重试（给 UI 决定要不要显示重试按钮）
    public var isRetryable: Bool {
        switch self {
        case .detailFailed, .tocFetchFailed, .contentParseFailed, .network, .timeout:
            return true
        case .missingRule, .unsupported, .emptyContent, .jsFailed:
            return false
        }
    }
}

// MARK: - 服务

public struct BookService: Sendable {
    public var client: HTTPClient
    public var evaluator: RuleEvaluator
    public var perRequestTimeout: Int

    public init(
        client: HTTPClient = HTTPClient(),
        evaluator: RuleEvaluator = RuleEvaluator(),
        perRequestTimeout: Int = 60
    ) {
        self.client = client
        self.evaluator = evaluator
        self.perRequestTimeout = perRequestTimeout
    }

    // MARK: 详情（P0-3）

    public func fetchDetail(
        bookUrl: String,
        source: BookSource,
        searchName: String? = nil,
        searchAuthor: String? = nil
    ) async throws -> BookDetail {
        guard source.isTextSource else {
            throw BookServiceError.unsupported(
                "该源为\(source.unsupportedTypeDescription ?? "非文本")类型，本版本不支持"
            )
        }
        let rule = source.bookInfoRule

        // ① 起始请求：有 init 规则时先跑 init（它可能改写 URL 或直接给 HTML）
        var currentURL = bookUrl
        var html: String
        var finalURL: String

        do {
            (html, finalURL) = try await get(url: currentURL, source: source)
        } catch {
            throw BookServiceError.detailFailed(
                message: SearchService.describe(error), bookURL: bookUrl
            )
        }

        var ctx = EvalContext(
            source: EvalSource.detect(html, baseURL: finalURL),
            baseURL: finalURL,
            variables: VariableStore(builtinVariables(book: nil, chapter: nil)),
            isFromBookInfo: true
        )

        if let initRule = rule.`init`, !initRule.isEmpty {
            // init 规则的输出：空 → 原页面；整段 HTML → 用它；一个 URL → 再请求一次
            let initOut = (try? evaluator.evaluate(rule: initRule, in: ctx)) ?? ""
            let trimmedOut = initOut.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOut.isEmpty {
                if trimmedOut.hasPrefix("http://") || trimmedOut.hasPrefix("https://") {
                    currentURL = trimmedOut
                    do {
                        (html, finalURL) = try await get(url: currentURL, source: source)
                        ctx = EvalContext(
                            source: EvalSource.detect(html, baseURL: finalURL),
                            baseURL: finalURL,
                            variables: VariableStore(builtinVariables(book: nil, chapter: nil)),
                            isFromBookInfo: true
                        )
                    } catch {
                        throw BookServiceError.detailFailed(
                            message: SearchService.describe(error), bookURL: currentURL
                        )
                    }
                } else if trimmedOut.contains("<") {
                    // 直接是 HTML 片段
                    ctx = EvalContext(
                        source: EvalSource.detect(trimmedOut, baseURL: finalURL),
                        baseURL: finalURL,
                        variables: VariableStore(builtinVariables(book: nil, chapter: nil)),
                        isFromBookInfo: true,
                        jsLib: source.jsLib
                    )
                } else {
                    // 其它（纯文本）→ 当作 HTML 片段处理，不覆盖页面
                    ctx = EvalContext(
                        source: EvalSource.detect(trimmedOut, baseURL: finalURL),
                        baseURL: finalURL,
                        variables: VariableStore(builtinVariables(book: nil, chapter: nil)),
                        isFromBookInfo: true,
                        jsLib: source.jsLib
                    )
                }
            }
        }

        let name = field(rule.name, ctx) ?? searchName ?? ""
        let author = field(rule.author, ctx) ?? searchAuthor ?? ""
        let intro = field(rule.intro, ctx) ?? ""
        let coverRaw = urlField(rule.coverUrl, ctx)
        let cover = sanitizeCoverURL(coverRaw)
        let tocUrlRaw = urlField(rule.tocUrl, ctx) ?? currentURL

        return BookDetail(
            name: name,
            author: author,
            intro: intro,
            coverUrl: cover,
            kind: field(rule.kind, ctx),
            lastChapter: field(rule.lastChapter, ctx),
            updateTime: field(rule.updateTime, ctx),
            wordCount: field(rule.wordCount, ctx),
            tocUrl: tocUrlRaw.isEmpty ? currentURL : tocUrlRaw,
            bookUrl: bookUrl,
            origin: source.bookSourceUrl,
            originName: source.bookSourceName
        )
    }

    // MARK: 目录（P0-3，支持 nextTocUrl 分页追加）

    /// 拉第一页目录。
    public func fetchToc(
        tocUrl: String,
        source: BookSource,
        book: BookSnapshot
    ) async throws -> TocResult {
        guard let listRule = source.tocRule.chapterList, !listRule.isEmpty else {
            throw BookServiceError.missingRule("ruleToc.chapterList")
        }
        var result = TocResult(chapters: [], loadedPages: 0, hasMore: true, nextPageUrl: tocUrl)
        return try await appendTocPage(
            pageUrl: tocUrl,
            source: source,
            book: book,
            into: result,
            maxPages: 1
        )
    }

    /// 追加下一页（失败不清空：调用方拿到 throws 就保留原 chapters）。
    public func fetchNextTocPage(
        nextPageUrl: String,
        source: BookSource,
        book: BookSnapshot,
        existing: TocResult
    ) async throws -> TocResult {
        guard let listRule = source.tocRule.chapterList, !listRule.isEmpty else {
            throw BookServiceError.missingRule("ruleToc.chapterList")
        }
        return try await appendTocPage(
            pageUrl: nextPageUrl,
            source: source,
            book: book,
            into: existing,
            maxPages: 1
        )
    }

    /// 连续拉到没有下一页为止（带页数上限，防止死循环站点）。
    public func fetchAllToc(
        tocUrl: String,
        source: BookSource,
        book: BookSnapshot,
        maxPages: Int = 30
    ) async throws -> TocResult {
        guard let listRule = source.tocRule.chapterList, !listRule.isEmpty else {
            throw BookServiceError.missingRule("ruleToc.chapterList")
        }
        var result = TocResult(chapters: [], loadedPages: 0, hasMore: true, nextPageUrl: tocUrl)
        return try await appendTocPage(
            pageUrl: tocUrl,
            source: source,
            book: book,
            into: result,
            maxPages: maxPages
        )
    }

    private func appendTocPage(
        pageUrl: String,
        source: BookSource,
        book: BookSnapshot,
        into existing: TocResult,
        maxPages: Int
    ) async throws -> TocResult {
        let rule = source.tocRule
        var current = existing
        var url: String? = pageUrl
        var pagesThisRound = 0
        var appendedTotal = 0

        while let u = url, pagesThisRound < maxPages {
            let (html, finalURL) = try await fetchOrThrow(url: u, source: source, book: book)
            var ctx = EvalContext(
                source: EvalSource.detect(html, baseURL: finalURL),
                baseURL: finalURL,
                variables: VariableStore(builtinVariables(book: book, chapter: nil)),
                isFromBookInfo: true,
                jsLib: source.jsLib
            )
            // 部分站点的 preUpdateJs 会改写页面 —— P0 不支持 JS，直接跳过；
            // 若书源声明了 preUpdateJs 且无 JS 运行时，这里不报错（目录仍可用）

            guard let listRule = rule.chapterList else {
                throw BookServiceError.missingRule("ruleToc.chapterList")
            }
            let listSources = try evaluator.evaluateListSources(rule: listRule, in: ctx)
            var newChapters: [BookChapter] = []
            newChapters.reserveCapacity(listSources.count)

            for el in listSources {
                let nameRule = rule.chapterName ?? ""
                let urlRule = rule.chapterUrl ?? ""
                var t = (try? evaluator.evaluate(rule: nameRule, in: ctx.withSource(el))) ?? ""
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                var c = ctx.withSource(el)
                c.isURL = true
                let curl = (try? evaluator.evaluate(rule: urlRule, in: c)) ?? ""
                guard !curl.isEmpty else { continue }

                // isVip / isPay：规则给了就判，没给当 false
                let isVip = (try? evaluator.evaluate(
                    rule: rule.isVip ?? "", in: ctx.withSource(el)
                ))?.trimmingCharacters(in: .whitespaces).isEmpty == false
                let isPay = (try? evaluator.evaluate(
                    rule: rule.isPay ?? "", in: ctx.withSource(el)
                ))?.trimmingCharacters(in: .whitespaces).isEmpty == false

                newChapters.append(
                    BookChapter(
                        title: t, url: curl,
                        index: current.chapters.count + newChapters.count,
                        isVip: isVip, isPay: isPay
                    )
                )
            }

            // `chapterList` 前的 `-` / `+` 已在规则层处理（RuleSegment），这里不再管
            if newChapters.isEmpty && current.chapters.isEmpty {
                throw BookServiceError.tocFetchFailed(
                    message: "目录规则未命中章节（可能是站点改版或规则不匹配）", pageURL: u
                )
            }

            current.chapters.append(contentsOf: newChapters)
            appendedTotal += newChapters.count
            current.loadedPages += 1
            pagesThisRound += 1

            // 下一页
            if let nextRule = rule.nextTocUrl, !nextRule.isEmpty {
                var nc = ctx
                nc.isURL = true
                var next = (try? evaluator.evaluate(rule: nextRule, in: nc)) ?? ""
                next = next.trimmingCharacters(in: .whitespacesAndNewlines)
                // 规则可能返回 JSON 数组（多候选页）
                if next.hasPrefix("[") {
                    if let arr = JsonValue.parse(next), case .array(let a) = arr,
                       let first = a.first {
                        next = first.text
                    }
                }
                url = next.isEmpty ? nil : next
            } else {
                url = nil
            }
            current.hasMore = (url != nil)
            current.nextPageUrl = url
        }

        current.appendedCount = appendedTotal
        return current
    }

    // MARK: 正文（P0-4）

    /// 取正文并清洗为纯文本。
    /// - Parameter autoFollowNextPage: 章节被拆成多页时是否自动拼接（默认 true，上限 10 页）
    public func fetchContent(
        chapterUrl: String,
        source: BookSource,
        book: BookSnapshot,
        chapter: ChapterSnapshot,
        autoFollowNextPage: Bool = true,
        purify: ContentPurifyInput? = nil
    ) async throws -> ContentResult {
        guard let contentRule = source.contentRule.content, !contentRule.isEmpty else {
            throw BookServiceError.missingRule("ruleContent.content")
        }
        guard source.isTextSource else {
            throw BookServiceError.unsupported(
                "该源为\(source.unsupportedTypeDescription ?? "非文本")类型，本版本不支持"
            )
        }

        var accumulated: [String] = []
        var url: String? = chapterUrl
        var pages = 0
        var lastFinalURL = chapterUrl
        var titleOverride: String?
        var nextContent: String?

        while let u = url, pages < 10 {
            pages += 1
            let html: String
            let finalURL: String
            do {
                (html, finalURL) = try await fetchOrThrow(url: u, source: source, book: book, chapter: chapter)
            } catch {
                if accumulated.isEmpty {
                    throw BookServiceError.contentParseFailed(
                        message: SearchService.describe(error), webURL: u
                    )
                }
                // 后续页失败：保留已取到的部分（不整章失败）
                break
            }
            lastFinalURL = finalURL

            var ctx = EvalContext(
                source: EvalSource.detect(html, baseURL: finalURL),
                baseURL: finalURL,
                variables: VariableStore(builtinVariables(book: book, chapter: chapter)),
                chapter: chapter,
                nextChapterURL: nil,
                jsLib: source.jsLib
            )

            let raw: String
            do {
                raw = try evaluator.evaluate(rule: contentRule, in: ctx)
            } catch let e as JSRuntimeError {
                // 缺方法 / 超时 / 同步桥失败：精确到方法名呈现，不吞
                throw BookServiceError.jsFailed(e.description)
            } catch {
                raw = ""
            }
            if raw.isEmpty {
                if accumulated.isEmpty {
                    throw BookServiceError.contentParseFailed(
                        message: "正文规则未取到内容（页面结构可能已变化）", webURL: finalURL
                    )
                }
                break
            }

            // title 规则（可选）
            if titleOverride == nil, let tr = source.contentRule.title, !tr.isEmpty {
                let t = (try? evaluator.evaluate(rule: tr, in: ctx)) ?? ""
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    titleOverride = t.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            accumulated.append(raw)

            // 章节内下一页
            if autoFollowNextPage, let nr = source.contentRule.nextContentUrl, !nr.isEmpty {
                var nc = ctx
                nc.isURL = true
                var n = (try? evaluator.evaluate(rule: nr, in: nc)) ?? ""
                n = n.trimmingCharacters(in: .whitespacesAndNewlines)
                if n.isEmpty || n == finalURL || n == u { n = "" }
                url = n.isEmpty ? nil : n
                nextContent = n.isEmpty ? nil : n
            } else {
                url = nil
            }
        }

        let joined = accumulated.joined(separator: "\n")
        // 关键：清洗成纯文本（去标签 + 反转义）。规则返回的可能是 HTML 片段。
        let plain = TextCleaner.toPlainText(joined)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BookServiceError.contentParseFailed(
                message: "正文清洗后为空", webURL: lastFinalURL
            )
        }

        // 净化流水线（任务模块二，架构文档二·八的 7 步固定顺序）。
        // purify 为 nil（调用方未启用）时保持 P0 行为：仅书源侧正则参与。
        var finalText = plain
        if purify != nil || source.contentRule.replaceRegex != nil || source.contentRule.sourceRegex != nil {
            let title = titleOverride ?? chapter.title
            let (processed, _) = ContentProcessor.process(
                text: plain,
                chapterTitle: title,
                bookName: book.name,
                rules: purify?.rules ?? [],
                sourceReplaceRegex: source.contentRule.replaceRegex,
                sourceRegex: source.contentRule.sourceRegex,
                options: purify?.options ?? ContentProcessOptions()
            )
            finalText = processed
        }

        return ContentResult(
            text: finalText,
            title: titleOverride ?? chapter.title,
            nextContentUrl: nextContent,
            webURL: lastFinalURL,
            wordCount: finalText.count
        )
    }

    // MARK: 内部

    private func get(url: String, source: BookSource) async throws -> (html: String, finalURL: String) {
        let analyzed = try URLTemplateEngine.analyze(
            template: url,
            vars: [:],
            evaluator: evaluator,
            ctx: EvalContext(source: EvalSource.text(""), jsLib: source.jsLib)
        )
        let resp = try await client.fetch(analyzed: analyzed, sourceKey: source.bookSourceUrl)
        return (resp.text, resp.finalURL)
    }

    private func fetchOrThrow(
        url: String,
        source: BookSource,
        book: BookSnapshot?,
        chapter: ChapterSnapshot? = nil
    ) async throws -> (html: String, finalURL: String) {
        let analyzed = try URLTemplateEngine.analyze(
            template: url,
            vars: [:],
            evaluator: evaluator,
            ctx: EvalContext(
                source: EvalSource.text(""),
                variables: VariableStore(builtinVariables(book: book, chapter: chapter)),
                book: book,
                chapter: chapter,
                jsLib: source.jsLib
            )
        )
        let resp = try await client.fetch(analyzed: analyzed, sourceKey: source.bookSourceUrl)
        return (resp.text, resp.finalURL)
    }

    private func field(_ rule: String?, _ ctx: EvalContext) -> String? {
        guard let rule, !rule.isEmpty else { return nil }
        let v = (try? evaluator.evaluate(rule: rule, in: ctx)) ?? ""
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func urlField(_ rule: String?, _ ctx: EvalContext) -> String? {
        guard let rule, !rule.isEmpty else { return nil }
        var c = ctx
        c.isURL = true
        let v = (try? evaluator.evaluate(rule: rule, in: c)) ?? ""
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 封面 URL 清洗：规则常返回 `//host/x.jpg`、`/x.jpg`、或带协议头的半截串。
    /// 取不到（空 / 非 http(s)）时返回 nil → UI 用占位图，绝不裂图（需求 4-6）。
    func sanitizeCoverURL(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        // 去掉可能的包裹引号 / 空白
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t"))
        if s.hasPrefix("//") { s = "https:" + s }
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            // 基本合法性：host 存在
            if let u = URL(string: s), u.host?.isEmpty == false { return s }
            return nil
        }
        return nil
    }
}
