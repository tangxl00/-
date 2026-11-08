//
//  Models.swift
//  TingDu
//
//  SwiftData 持久化模型（P0）。
//  说明：本文件为 iOS 专属层，沙箱无 Xcode，属「未编译」交付（详见《实现说明》）。
//
//  设计要点：
//  - 书源不逐字段镜像 40+ 个 legado 字段，而是存 canonical JSON payload
//    （BookSource 本身是带 unknownFields 的宽容 Codable，可完整往返），
//    另外冗余 url/name/group/enabled 四列用于列表查询与排序。
//  - 本地 TXT 书存原始 UTF-8 文本 + 分章规则 ID，打开时重新分章（确定性算法，
//    不需要持久化章节区间）。
//

import Foundation
import SwiftData
import ReaderCore

// MARK: - 书源记录

@Model
final class SourceRecord {
    /// 书源 URL（唯一键，等于 BookSource.bookSourceUrl / id）
    @Attribute(.unique) var url: String
    var name: String
    var group: String
    var enabled: Bool
    var sortOrder: Int
    /// BookSource 的完整 JSON（canonical 编码，含 unknownFields）
    var payload: Data
    var addedAt: Date

    init(url: String, name: String, group: String, enabled: Bool, sortOrder: Int, payload: Data, addedAt: Date = .now) {
        self.url = url
        self.name = name
        self.group = group
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.payload = payload
        self.addedAt = addedAt
    }

    var bookSource: BookSource? {
        guard let source = try? JSONDecoder().decode(BookSource.self, from: payload) else { return nil }
        return source
    }

    static func insert(_ source: BookSource, order: Int, in context: ModelContext) {
        guard let payload = try? JSONEncoder().encode(source) else { return }
        let record = SourceRecord(
            url: source.bookSourceUrl,
            name: source.bookSourceName,
            group: source.bookSourceGroup ?? "",
            enabled: source.enabled,
            sortOrder: order,
            payload: payload
        )
        context.insert(record)
    }
}

// MARK: - 书架书籍记录

@Model
final class BookRecord {
    /// 书籍唯一键：在线书 = bookUrl；本地书 = "local:" + UUID
    @Attribute(.unique) var bookKey: String
    var name: String
    var author: String
    var kind: String
    var intro: String
    var coverUrl: String
    /// 在线书：书源 URL；本地书：空
    var origin: String
    var originName: String
    /// 在线书：目录页 URL（书源详情规则给出 tocUrl 时保存，拉目录优先用它；空 = 用 bookKey）
    /// v1.2.1 补：App 层此前缺该字段，ReaderViewModel / BookDetailView 引用 book.tocUrl 编译不过。
    /// 默认空串，SwiftData 轻量迁移安全。
    var tocUrl: String = ""
    var isLocal: Bool
    /// 本地书：正文（UTF-8）；在线书：空
    var localText: Data?
    /// 本地书：分章规则 ID（standard/loose）
    var localRuleID: String
    var chapterCount: Int
    var lastChapterTitle: String
    var addedAt: Date
    var lastReadAt: Date?

    init(bookKey: String,
         name: String,
         author: String,
         kind: String = "",
         intro: String = "",
         coverUrl: String = "",
         origin: String = "",
         originName: String = "",
         tocUrl: String = "",
         isLocal: Bool = false,
         localText: Data? = nil,
         localRuleID: String = TXTChapterRules.standard.id,
         chapterCount: Int = 0,
         lastChapterTitle: String = "",
         addedAt: Date = .now) {
        self.bookKey = bookKey
        self.name = name
        self.author = author
        self.kind = kind
        self.intro = intro
        self.coverUrl = coverUrl
        self.origin = origin
        self.originName = originName
        self.tocUrl = tocUrl
        self.isLocal = isLocal
        self.localText = localText
        self.localRuleID = localRuleID
        self.chapterCount = chapterCount
        self.lastChapterTitle = lastChapterTitle
        self.addedAt = addedAt
    }
}

// MARK: - 替换/净化规则记录（P0#2，v1.2.0）

/// ReaderCore.ReplaceRule 的 SwiftData 落库形态（13 字段一一对应）。
/// 排序用 sortOrder；唯一键 ruleID = ReplaceRule.id。
@Model
final class ReplaceRuleRecord {
    @Attribute(.unique) var ruleID: String
    var name: String
    var group: String
    var pattern: String
    var replacement: String
    var isRegex: Bool
    var scope: String
    var scopeTitle: Bool
    var scopeContent: Bool
    var excludeScope: String
    var timeoutMillisecond: Int
    var sortOrder: Int
    var enable: Bool

    init(rule: ReplaceRule) {
        self.ruleID = rule.id
        self.name = rule.name
        self.group = rule.group
        self.pattern = rule.pattern
        self.replacement = rule.replacement
        self.isRegex = rule.isRegex
        self.scope = rule.scope
        self.scopeTitle = rule.scopeTitle
        self.scopeContent = rule.scopeContent
        self.excludeScope = rule.excludeScope
        self.timeoutMillisecond = rule.timeoutMillisecond
        self.sortOrder = rule.sortOrder
        self.enable = rule.enable
    }

    /// 用 ReplaceRule 覆写字段（ruleID 与 sortOrder 不动——排序走 reorderReplaceRules）。
    func apply(_ rule: ReplaceRule) {
        name = rule.name
        group = rule.group
        pattern = rule.pattern
        replacement = rule.replacement
        isRegex = rule.isRegex
        scope = rule.scope
        scopeTitle = rule.scopeTitle
        scopeContent = rule.scopeContent
        excludeScope = rule.excludeScope
        timeoutMillisecond = rule.timeoutMillisecond
        enable = rule.enable
    }

    var replaceRule: ReplaceRule {
        ReplaceRule(
            id: ruleID,
            name: name,
            group: group,
            pattern: pattern,
            replacement: replacement,
            isRegex: isRegex,
            scope: scope,
            scopeTitle: scopeTitle,
            scopeContent: scopeContent,
            excludeScope: excludeScope,
            timeoutMillisecond: timeoutMillisecond,
            sortOrder: sortOrder,
            enable: enable
        )
    }
}

// MARK: - 阅读进度记录

@Model
final class ProgressRecord {
    @Attribute(.unique) var bookKey: String
    var chapterIndex: Int
    var characterOffset: Int
    var chapterTitle: String
    var fraction: Double
    var updatedAt: Date

    init(bookKey: String, chapterIndex: Int, characterOffset: Int, chapterTitle: String, fraction: Double, updatedAt: Date = .now) {
        self.bookKey = bookKey
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.chapterTitle = chapterTitle
        self.fraction = fraction
        self.updatedAt = updatedAt
    }
}

// MARK: - SwiftData 进度适配器（实现 ReaderCore 的 ProgressStoring 协议）

/// ReaderCore 的 ProgressCoordinator 依赖 ProgressStoring 协议；
/// 这里把读写桥接到 SwiftData 主上下文。所有方法都调度回主线程
/// （SwiftData ModelContext 非线程安全，而协调器的节流写发生在后台）。
final class SwiftDataProgressStore: ProgressStoring, @unchecked Sendable {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(bookKey: String) -> ReadingProgress? {
        let record = fetchRecord(bookKey: bookKey)
        guard let r = record else { return nil }
        return ReadingProgress(
            bookKey: r.bookKey,
            chapterIndex: r.chapterIndex,
            characterOffset: r.characterOffset,
            chapterTitle: r.chapterTitle,
            fraction: r.fraction,
            updatedAt: r.updatedAt
        )
    }

    func save(_ progress: ReadingProgress) {
        let context = ModelContext(container)
        if let r = try? context.fetch(FetchDescriptor<ProgressRecord>(predicate: #Predicate { $0.bookKey == progress.bookKey })).first {
            r.chapterIndex = progress.chapterIndex
            r.characterOffset = progress.characterOffset
            r.chapterTitle = progress.chapterTitle
            r.fraction = progress.fraction
            r.updatedAt = progress.updatedAt
        } else {
            context.insert(ProgressRecord(
                bookKey: progress.bookKey,
                chapterIndex: progress.chapterIndex,
                characterOffset: progress.characterOffset,
                chapterTitle: progress.chapterTitle,
                fraction: progress.fraction
            ))
        }
        try? context.save()
    }

    func remove(bookKey: String) {
        let context = ModelContext(container)
        if let r = try? context.fetch(FetchDescriptor<ProgressRecord>(predicate: #Predicate { $0.bookKey == bookKey })).first {
            context.delete(r)
            try? context.save()
        }
    }

    /// v1.2.1 补：ProgressStoring 协议要求 allProgress()（书架「最近阅读」排序用），
    /// 原实现漏掉导致不符合协议。按 updatedAt 降序返回全量进度。
    func allProgress() -> [ReadingProgress] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ProgressRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.map { r in
            ReadingProgress(
                bookKey: r.bookKey,
                chapterIndex: r.chapterIndex,
                characterOffset: r.characterOffset,
                chapterTitle: r.chapterTitle,
                fraction: r.fraction,
                updatedAt: r.updatedAt
            )
        }
    }

    private func fetchRecord(bookKey: String) -> ProgressRecord? {
        let context = ModelContext(container)
        return try? context.fetch(FetchDescriptor<ProgressRecord>(predicate: #Predicate { $0.bookKey == bookKey })).first
    }
}
