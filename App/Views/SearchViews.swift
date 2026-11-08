//
//  SearchViews.swift
//  TingDu
//
//  搜索页（P0-2）与详情+目录页（P0-3）。
//  iOS 专属层，未编译（沙箱无 Xcode）。
//

import SwiftUI
import SwiftData
import ReaderCore

// MARK: - 搜索页

struct SearchView: View {
    @EnvironmentObject private var services: AppServices
    @State private var keyword = ""
    @State private var searching = false
    @State private var report: SearchReport?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                if searching {
                    HStack {
                        ProgressView()
                        if let r = report {
                            Text(r.searchSummaryLine).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } else if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red).padding(.vertical, 8)
                }
                resultList
            }
            .navigationTitle("搜索")
            .navigationDestination(for: MergedBook.self) { merged in
                MergedBookDetailView(merged: merged)
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("书名 / 作者（在已启用书源中搜索）", text: $keyword)
                .submitLabel(.search)
                .onSubmit { startSearch() }
            if !keyword.isEmpty {
                Button { keyword = ""; report = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.bar)
    }

    private var resultList: some View {
        Group {
            if let report {
                if report.merged.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.slash").foregroundStyle(.secondary)
                        Text(report.summaryText).font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(report.merged) { book in
                        NavigationLink(value: book) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(book.name).font(.headline)
                                    Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                                }
                                if let intro = book.intro {
                                    Text(intro).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                HStack {
                                    if let kind = book.kind { Text(kind).font(.caption2) }
                                    Text("\(book.sourceCount) 个源命中").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    if report.truncatedCount > 0 {
                        Text("已按多源命中排序；截断 \(report.truncatedCount) 条（上限 \(BookMerger.maxResults)）")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                    }
                }
            } else {
                emptyHint
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(services.sourceCount == 0
                 ? "还没有书源：先到「书源」页导入"
                 : "已启用 \(services.enabledSourceCount)/\(services.sourceCount) 个书源")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let enabled = services.enabledSources()
        guard !enabled.isEmpty else {
            errorText = "没有可用书源：请先在「书源」页导入并启用"
            return
        }
        errorText = nil
        searching = true
        report = nil
        let service = services.makeSearchService()
        Task {
            // 不可用源（非文本 / 依赖 WebView 注入）单独传入，报告里会明确列出；
            // 含 JS 的源按 Tier B 降级兼容参与搜索（SearchService 已放宽过滤）
            let all = services.allSources()
            let unsupported = all.filter { !($0.enabled && $0.isTextSource && !JSStaticScanner.scan($0).usesWebJS) }
            let result = await service.search(keyword: trimmed, sources: enabled, unsupportedSources: unsupported)
            await MainActor.run {
                report = result
                searching = false
            }
        }
    }
}

// MARK: - 合并书详情（从搜索进入：先选源再拉详情）

struct MergedBookDetailView: View {
    let merged: MergedBook
    @EnvironmentObject private var services: AppServices
    @State private var detail: BookDetail?
    @State private var errorText: String?
    @State private var loading = false
    @State private var loadingSourceKey: String?

    var body: some View {
        List {
            Section("选择书源（\(merged.sources.count) 个）") {
                ForEach(merged.sources, id: \.origin) { item in
                    Button {
                        loadDetail(item)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.originName).font(.subheadline)
                                if let last = item.lastChapter {
                                    Text("最新：\(last)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if loadingSourceKey == item.origin {
                                ProgressView()
                            } else if detail?.origin == item.origin {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            if let errorText {
                Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
            }
            if let detail {
                Section {
                    BookDetailContentView(detail: detail) { d in
                        addToShelf(d)
                    }
                }
            }
        }
        .navigationTitle(merged.name)
    }

    private func loadDetail(_ item: SearchResultItem) {
        guard let source = services.source(url: item.origin) else {
            errorText = "书源不存在（可能已被删除）"
            return
        }
        loadingSourceKey = item.origin
        errorText = nil
        loading = true
        let service = services.makeBookService()
        Task {
            do {
                let d = try await service.fetchDetail(
                    bookUrl: item.bookUrl,
                    source: source,
                    searchName: item.name,
                    searchAuthor: item.author
                )
                await MainActor.run { detail = d; loading = false; loadingSourceKey = nil }
            } catch {
                await MainActor.run {
                    errorText = "详情加载失败：\(error)"
                    loading = false
                    loadingSourceKey = nil
                }
            }
        }
    }

    private func addToShelf(_ detail: BookDetail) {
        let context = services.container.mainContext
        let record = BookRecord(
            bookKey: detail.bookUrl,
            name: detail.name,
            author: detail.author,
            kind: detail.kind ?? "",
            intro: detail.intro,
            coverUrl: detail.coverUrl ?? "",
            origin: detail.origin,
            originName: detail.originName,
            chapterCount: 0,
            lastChapterTitle: detail.lastChapter ?? ""
        )
        context.insert(record)
        try? context.save()
    }
}

// MARK: - 书架在线书详情 + 目录（P0-3）

struct BookDetailView: View {
    let book: BookRecord
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var chapters: [BookChapter] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var tocUrl: String?
    @State private var readerPresented = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.name).font(.title3.bold())
                    Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                    if !book.kind.isEmpty { Text(book.kind).font(.caption).foregroundStyle(.secondary) }
                    if !book.intro.isEmpty {
                        Text(book.intro).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
            Section("目录\(chapters.isEmpty ? "" : "（\(chapters.count) 章）")") {
                if loading {
                    HStack { ProgressView(); Text("目录加载中…").font(.footnote).foregroundStyle(.secondary) }
                } else if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                    Button("重试") { Task { await loadToc() } }
                } else {
                    ForEach(chapters) { chapter in
                        Button {
                            openReader(chapterIndex: chapter.index)
                        } label: {
                            HStack {
                                Text(chapter.title).font(.subheadline).lineLimit(1)
                                Spacer()
                                if chapter.isVip { Text("VIP").font(.caption2).foregroundStyle(.orange) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("详情")
        .task { await loadToc() }
        .fullScreenCover(isPresented: $readerPresented) {
            NavigationStack {
                ReaderView(book: book, services: services, settingsStore: settingsStore)
            }
        }
    }

    private func loadToc() async {
        guard let source = services.source(url: book.origin) else {
            errorText = "书源不存在或已被删除"
            return
        }
        loading = true
        errorText = nil
        let service = services.makeBookService()
        let snapshot = BookSnapshot(
            name: book.name, author: book.author, bookUrl: book.bookKey,
            origin: source.bookSourceUrl, tocUrl: nil,
            kind: nil, intro: nil, coverUrl: nil,
            latestChapterTitle: book.lastChapterTitle.isEmpty ? nil : book.lastChapterTitle
        )
        do {
            let toc = try await service.fetchAllToc(
                tocUrl: book.tocUrl.isEmpty ? book.bookKey : book.tocUrl,
                source: source,
                book: snapshot
            )
            chapters = toc.chapters
            if chapters.isEmpty { errorText = "目录为空（规则未命中或站点结构变化）" }
        } catch {
            errorText = "目录加载失败：\(error)"
        }
        loading = false
    }

    private func openReader(chapterIndex: Int) {
        // ReaderView open() 从已存进度恢复；未读过的书从头开始。
        // P0 不做「点任意章节跳转」的定向恢复（进度恢复优先），此处直接打开阅读器。
        readerPresented = true
    }
}

/// 详情页展示复用块
struct BookDetailContentView: View {
    let detail: BookDetail
    var onAddToShelf: (BookDetail) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(detail.name).font(.headline)
                Spacer()
                Button("加入书架") { onAddToShelf(detail) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            Text(detail.author).font(.subheadline).foregroundStyle(.secondary)
            if let kind = detail.kind { Text(kind).font(.caption).foregroundStyle(.secondary) }
            if let last = detail.lastChapter { Text("最新：\(last)").font(.caption).foregroundStyle(.secondary) }
            if !detail.intro.isEmpty {
                Text(detail.intro).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
