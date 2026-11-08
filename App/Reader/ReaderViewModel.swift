//
//  ReaderViewModel.swift
//  TingDu
//
//  阅读器编排：章节加载（在线源 / 本地 TXT）→ 分页 → 翻页 → 进度保存。
//  iOS 专属层，未编译（沙箱无 Xcode）。
//
//  进度语义（与 ReaderCore 一致）：
//  - 位置 = (chapterIndex, characterOffset)；characterOffset 是章节布局文本内的偏移
//  - 切章立即落盘；同章翻页走 1s 节流；退出 flush
//

import Foundation
import SwiftUI
import SwiftData
import ReaderCore

enum ReaderLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class ReaderViewModel: ObservableObject {
    // 输入
    let book: BookRecord
    private let services: AppServices
    private let settingsStore: SettingsStore

    // 章节表
    private(set) var chapters: [BookChapter] = []
    private var localChapters: [TXTChapter] = []
    private let localText: String?

    // 当前章
    @Published var loadState: ReaderLoadState = .idle
    @Published var chapterTitle: String = ""
    @Published var currentPageIndex: Int = 0
    @Published var pageCount: Int = 0

    // 渲染数据
    @Published var renderLines: [RenderLine] = []
    private var layoutText: String = ""
    private var pagination: PaginationResult?
    private var measured: [TextLine] = []
    private var coordinator: ProgressCoordinator?

    // 视口（ReaderView onGeometryChange 回填）
    var viewportWidth: Double = 0
    var viewportHeight: Double = 0

    var settings: ReadingSettings { settingsStore.settings }
    var theme: ReaderTheme { settingsStore.settings.theme }

    private var bookService: BookService { services.makeBookService() }

    init(book: BookRecord, services: AppServices, settingsStore: SettingsStore) {
        self.book = book
        self.services = services
        self.settingsStore = settingsStore
        self.localText = book.isLocal ? (book.localText.flatMap { String(data: $0, encoding: .utf8) }) : nil
    }

    // MARK: - 打开

    func open() async {
        // 1) 章节表
        if book.isLocal, let text = localText {
            let ruleID = book.localRuleID
            let rule = TXTChapterRules.rule(id: ruleID) ?? TXTChapterRules.standard
            let result = TXTImporter.chapterize(text: text, bookName: book.name, rule: rule)
            localChapters = result.chapters
            chapters = result.chapters.enumerated().map { idx, ch in
                BookChapter(title: ch.title, url: "", index: idx, isVip: false, isPay: false)
            }
        } else {
            // 在线书：拉目录
            guard let source = services.source(url: book.origin) else {
                loadState = .failed("书源不存在或已被删除")
                return
            }
            loadState = .loading
            do {
                let snapshot = BookSnapshot(
                    name: book.name,
                    author: book.author,
                    bookUrl: book.bookKey,
                    origin: source.bookSourceUrl,
                    tocUrl: nil,
                    kind: book.kind.isEmpty ? nil : book.kind,
                    intro: book.intro.isEmpty ? nil : book.intro,
                    coverUrl: book.coverUrl.isEmpty ? nil : book.coverUrl,
                    latestChapterTitle: book.lastChapterTitle.isEmpty ? nil : book.lastChapterTitle
                )
                let toc = try await bookService.fetchAllToc(
                    tocUrl: book.tocUrl.isEmpty ? book.bookKey : book.tocUrl,
                    source: source,
                    book: snapshot
                )
                chapters = toc.chapters
                if chapters.isEmpty {
                    loadState = .failed("目录为空（规则未命中或站点结构变化）")
                    return
                }
            } catch {
                loadState = .failed("目录加载失败：\(describe(error))")
                return
            }
        }

        // 2) 进度恢复
        let store = SwiftDataProgressStore(container: services.container)
        let coordinator = ProgressCoordinator(store: store, bookKey: book.bookKey)
        self.coordinator = coordinator
        let target = ProgressResolver.openTarget(progress: coordinator.snapshot, chapterCount: chapters.count)
            ?? ReadingLocator(chapterIndex: 0, characterOffset: 0)

        await loadChapter(index: target.chapterIndex, restoreOffset: target.characterOffset)
    }

    /// 按 UTF-16 偏移安全切片（越界收敛到字符串边界；落点若落在代理对中间则外扩到完整字符）。
    static func utf16Slice(_ text: String, from: Int, to: Int) -> String {
        let ns = text as NSString
        let n = ns.length
        let s = min(max(0, from), n)
        let e = min(max(s, to), n)
        var range = NSRange(location: s, length: e - s)
        // 收敛到组合字符边界，避免把代理对 / 组合序列切成半个
        let safe = ns.rangeOfComposedCharacterSequences(for: range)
        range = safe
        return ns.substring(with: range)
    }

    // MARK: - 章节加载 + 分页

    func loadChapter(index: Int, restoreOffset: Int = 0) async {
        guard chapters.indices.contains(index) else { return }
        loadState = .loading
        chapterTitle = chapters[index].title

        var body: String
        if book.isLocal, let text = localText, localChapters.indices.contains(index) {
            let ch = localChapters[index]
            // P1#7（v1.2.0）：TXTChapter.start/end 是 NSString.length 口径的 UTF-16 偏移
            // （TXTImporter 用 ns.lineRange / ns.length 产生），原实现拿它当 Character 下标
            // 去切 Array(text)[...]，遇到 emoji / 组合字符会越界或错位崩溃。统一按 UTF-16 切。
            body = ReaderViewModel.utf16Slice(text, from: ch.start, to: ch.end)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard let source = services.source(url: book.origin) else {
                loadState = .failed("书源不存在或已被删除")
                return
            }
            let snapshot = BookSnapshot(
                name: book.name, author: book.author, bookUrl: book.bookKey,
                origin: source.bookSourceUrl, tocUrl: nil,
                kind: nil, intro: nil, coverUrl: nil, latestChapterTitle: nil
            )
            let chapterSnapshot = ChapterSnapshot(
                title: chapters[index].title,
                url: chapters[index].url,
                index: index
            )
            do {
                // P0#2（v1.2.0）：把用户替换规则与净化设置真正接入阅读链路。
                // 此前未传 purify:，ContentProcessor 六步流水线在 App 层从未执行。
                let content = try await bookService.fetchContent(
                    chapterUrl: chapters[index].url,
                    source: source,
                    book: snapshot,
                    chapter: chapterSnapshot,
                    purify: services.purifyInput()
                )
                body = content.text
            } catch {
                loadState = .failed("正文加载失败：\(describe(error))")
                return
            }
        }

        guard !body.isEmpty else {
            loadState = .failed("本章正文为空")
            return
        }

        layoutText = body
        paginate(restoreOffset: restoreOffset, chapterIndex: index)
        coordinator?.switchChapter(
            to: index,
            title: chapters[index].title,
            offset: currentPageStartOffset(),
            chapterCount: chapters.count
        )
        loadState = .loaded
    }

    /// 分页（字号/行距/边距变化后重跑；签名变化才重算）
    func paginate(restoreOffset: Int, chapterIndex: Int? = nil) {
        let s = settings
        guard viewportWidth > 10, viewportHeight > 10, !layoutText.isEmpty else { return }
        let width = viewportWidth - s.horizontalMargin * 2
        let lineHeight = s.fontSize * s.lineSpacing
        // 可用高度：扣除上下安全边距（边距比 1.4 倍行高）
        let verticalMargin = lineHeight * ReadingSettings.verticalMarginRatio
        let pageHeight = viewportHeight - verticalMargin * 2

        let measurer = CoreTextMeasurer(settings: s)
        measured = measurer.lines(in: layoutText, width: width, lineHeight: lineHeight)
        let result = Paginator.paginate(
            lines: measured,
            pageHeight: pageHeight,
            textLength: layoutText.count,
            signature: s.layoutSignature
        )
        pagination = result
        pageCount = result.pages.count

        // 定位页：按恢复偏移（页首字符）
        let offset = restoreOffset
        if let pageIdx = result.pageIndex(forCharacterOffset: offset) {
            currentPageIndex = pageIdx
        } else {
            currentPageIndex = max(0, result.pages.count - 1)
        }
        refreshRenderLines()
    }

    /// 字体/主题等设置变化：主题只重绘，排版参数变化则重分页并保持位置
    func settingsDidChange() {
        guard case .loaded = loadState, let pagination = pagination else { return }
        let s = settings
        if pagination.signature == s.layoutSignature {
            refreshRenderLines()   // 仅主题变化
        } else {
            let anchor = currentPageStartOffset()
            paginate(restoreOffset: anchor)
        }
    }

    private func refreshRenderLines() {
        guard let pagination = pagination,
              currentPageIndex < pagination.pages.count else {
            renderLines = []
            return
        }
        let page = pagination.pages[currentPageIndex]
        renderLines = CoreTextMeasurer.renderLines(
            for: page, in: layoutText, measured: measured, settings: settings
        )
    }

    // MARK: - 翻页

    func nextPage() {
        guard let pagination = pagination, currentPageIndex + 1 < pagination.pages.count else { return }
        currentPageIndex += 1
        refreshRenderLines()
        coordinator?.updateOffset(currentPageStartOffset())
    }

    func previousPage() {
        guard currentPageIndex > 0 else { return }
        currentPageIndex -= 1
        refreshRenderLines()
        coordinator?.updateOffset(currentPageStartOffset())
    }

    func previousChapter() {
        guard let idx = ProgressResolver.previousChapter(current: currentChapterIndex) else { return }
        Task { await loadChapter(index: idx) }
    }

    func nextChapter() {
        guard let idx = ProgressResolver.nextChapter(current: currentChapterIndex, chapterCount: chapters.count) else { return }
        Task { await loadChapter(index: idx) }
    }

    var currentChapterIndex: Int {
        // 从 coordinator 快照拿（source of truth）
        coordinator?.snapshot?.chapterIndex ?? 0
    }

    func currentPageStartOffset() -> Int {
        guard let pagination = pagination,
              currentPageIndex < pagination.pages.count else { return 0 }
        return pagination.pages[currentPageIndex].start
    }

    /// 退出阅读页：进度立即落盘
    func flush() {
        coordinator?.flush()
    }

    /// 整本书阅读百分比（书架显示用）
    var overallFraction: Double {
        coordinator?.snapshot?.fraction ?? 0
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? BookServiceError { return e.description }
        if let e = error as? SearchError { return "\(e)" }
        return "\(error)"
    }
}
