//
//  SearchModels.swift
//  ReaderCore
//
//  搜索相关的领域模型与四桶合并（P0-2 / 需求 2-6 ~ 2-8 / 4-3 / 4-4）。
//

import Foundation

// MARK: - 搜索结果项

/// 单个书源返回的一条搜索结果。
public struct SearchResultItem: Sendable, Equatable {
    /// 书名（规则 `name` 求值结果）
    public var name: String
    /// 作者
    public var author: String
    /// 详情页 URL（已绝对化）
    public var bookUrl: String
    /// 书源地址（bookSourceUrl）——用于后续换源/回溯
    public var origin: String
    /// 书源名（展示用）
    public var originName: String
    public var coverUrl: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var wordCount: String?

    public init(
        name: String,
        author: String,
        bookUrl: String,
        origin: String,
        originName: String,
        coverUrl: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        wordCount: String? = nil
    ) {
        self.name = name
        self.author = author
        self.bookUrl = bookUrl
        self.origin = origin
        self.originName = originName
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.wordCount = wordCount
    }
}

// MARK: - 单源状态

/// 单源搜索的终态。需求 2-7：单源超时/失败要单独标记，不能阻塞其他源。
public enum SourceSearchState: String, Sendable {
    /// 返回了至少一条结果
    case success
    /// 请求成功但结果为 0 条
    case empty
    /// 请求失败（网络错误 / 规则求值失败）
    case failed
    /// 超时（单独标记）
    case timedOut
    /// 该源不可用（含 JS / 非文本类型），未发起请求
    case unsupported

    public var displayName: String {
        switch self {
        case .success: return "成功"
        case .empty: return "无结果"
        case .failed: return "失败"
        case .timedOut: return "超时"
        case .unsupported: return "本版本不支持"
        }
    }
}

/// 单源搜索明细。
public struct SourceSearchOutcome: Sendable, Identifiable {
    public var id: String { sourceKey }
    public var sourceKey: String
    public var sourceName: String
    public var state: SourceSearchState
    public var items: [SearchResultItem]
    public var errorMessage: String?
    /// 该源耗时（毫秒），用于展示与排查
    public var elapsedMs: Int

    public init(
        sourceKey: String,
        sourceName: String,
        state: SourceSearchState,
        items: [SearchResultItem] = [],
        errorMessage: String? = nil,
        elapsedMs: Int = 0
    ) {
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.state = state
        self.items = items
        self.errorMessage = errorMessage
        self.elapsedMs = elapsedMs
    }
}

// MARK: - 汇总

/// 搜索汇总。
/// 需求 2-8 的关键区分：「全部返回空」vs「全部失败」必须区分 —— 见 `aggregateState`。
public struct SearchReport: Sendable {
    public var keyword: String
    public var outcomes: [SourceSearchOutcome]
    /// 四桶合并后的最终列表（已按优先级排序，上限 1000）
    public var merged: [MergedBook]
    /// 被上限截断的条数（>0 说明发生了截断）
    public var truncatedCount: Int

    public init(
        keyword: String,
        outcomes: [SourceSearchOutcome],
        merged: [MergedBook],
        truncatedCount: Int = 0
    ) {
        self.keyword = keyword
        self.outcomes = outcomes
        self.merged = merged
        self.truncatedCount = truncatedCount
    }

    /// 整体状态：区分「全部失败 / 全部空 / 有结果」
    public var aggregateState: SearchAggregateState {
        let relevant = outcomes.filter { $0.state != .unsupported }
        if relevant.isEmpty {
            return outcomes.isEmpty ? .noSource : .allUnsupported
        }
        if relevant.contains(where: { $0.state == .success }) {
            return .hasResults
        }
        let allFailedLike = relevant.allSatisfy { $0.state == .failed || $0.state == .timedOut }
        if allFailedLike { return .allFailed }
        // 有 empty 也有 failed/timedOut
        if relevant.contains(where: { $0.state == .empty }) { return .allEmpty }
        return .allFailed
    }

    public var emptySourceCount: Int { outcomes.filter { $0.state == .empty }.count }
    public var failedSourceCount: Int {
        outcomes.filter { $0.state == .failed || $0.state == .timedOut }.count
    }
    public var successSourceCount: Int { outcomes.filter { $0.state == .success }.count }
    public var unsupportedSourceCount: Int { outcomes.filter { $0.state == .unsupported }.count }

    /// 给用户的整体说明文案（保证「全空」与「全失败」不会混）
    public var summaryText: String {
        switch aggregateState {
        case .noSource:
            return "没有启用的书源，请先在书源管理里导入并启用"
        case .allUnsupported:
            return "启用书源均含 JS 或为音视频类型，本版本不支持"
        case .allFailed:
            return "全部书源搜索失败（\(failedSourceCount) 个），可查看各源原因后重试"
        case .allEmpty:
            return "全部书源均未搜索到「\(keyword)」（\(emptySourceCount) 个源正常返回 0 条）"
        case .hasResults:
            return searchSummaryLine
        }
    }

    /// 有结果时的明细行：成功/空/失败/超时各几个
    public var searchSummaryLine: String {
        var parts: [String] = []
        if successSourceCount > 0 { parts.append("\(successSourceCount) 个源有结果") }
        if emptySourceCount > 0 { parts.append("\(emptySourceCount) 个源无结果") }
        if failedSourceCount > 0 { parts.append("\(failedSourceCount) 个源失败/超时") }
        if unsupportedSourceCount > 0 { parts.append("\(unsupportedSourceCount) 个源不支持") }
        let tail = truncatedCount > 0 ? "，已按上限截断 \(truncatedCount) 条" : ""
        return "共 \(merged.count) 条" + (parts.isEmpty ? "" : "（" + parts.joined(separator: "，") + "）") + tail
    }
}

public enum SearchAggregateState: String, Sendable {
    case noSource
    case allUnsupported
    case allFailed
    case allEmpty
    case hasResults
}

// MARK: - 合并后的书

/// 同一本书（按 归一化书名+作者）跨多源的聚合结果。
public struct MergedBook: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { key.raw }
    public var key: BookKey
    public var name: String
    public var author: String
    public var coverUrl: String?
    public var intro: String?
    public var kind: String?
    /// 命中的源数量（桶内排序依据之一）
    public var sourceCount: Int
    /// 参与聚合的原始条目（每个源至多一条）
    public var sources: [SearchResultItem]
    /// 命中的桶（用于调试与测试断言）
    public var bucket: MergeBucket

    public init(
        key: BookKey,
        name: String,
        author: String,
        coverUrl: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        sourceCount: Int,
        sources: [SearchResultItem],
        bucket: MergeBucket
    ) {
        self.key = key
        self.name = name
        self.author = author
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.sourceCount = sourceCount
        self.sources = sources
        self.bucket = bucket
    }

    /// v1.2.1：App 层 navigationDestination / Picker(value:) 需要 Hashable。
    /// 手动实现（按归一化 key 哈希，与 Identifiable 的 id 同源），避免要求
    /// sources / bucket 成员全员 Hashable；等值语义仍用合成 ==。
    public func hash(into hasher: inout Hasher) {
        hasher.combine(key.raw)
    }
}

/// 归一化书籍标识：(书名, 作者) 各自做全角半角/空白/大小写归一。
public struct BookKey: Sendable, Hashable, Equatable {
    public var name: String
    public var author: String
    public var raw: String { name + "\u{1}" + author }

    public init(name: String, author: String) {
        self.name = BookKey.normalize(name)
        self.author = BookKey.normalize(author)
    }

    /// 归一化：去首尾空白、压缩内部空白、全角转半角（数字/字母）、小写。
    /// 不做「去标点」——书名里的标点是语义的一部分（如「三体Ⅱ·黑暗森林」）。
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.widthInsensitive, .caseInsensitive], locale: nil)
        let collapsed = folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 四桶优先级（需求 2-9 / 4-4）。
/// 顺序即优先级：exact > category > contains > other。
public enum MergeBucket: Int, Sendable, CaseIterable {
    /// 书名或作者精确命中关键词
    case exact = 0
    /// 分类/标签命中（`kind` 字段包含关键词）
    case category = 1
    /// 书名包含关键词（非精确）
    case contains = 2
    /// 其他（仅简介命中 / 无命中 / 作者包含）
    case other = 3

    public var displayName: String {
        switch self {
        case .exact: return "精确匹配"
        case .category: return "分类匹配"
        case .contains: return "书名包含"
        case .other: return "其他"
        }
    }
}

public enum BookKeyNormalizer {}
