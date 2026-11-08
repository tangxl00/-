//
//  BookMerger.swift
//  ReaderCore
//
//  四桶优先级合并（P0-2 / 需求 2-9 / 4-4）。
//
//  规则（按需求文档 4.4 逐条落地）：
//    1. 先按 (归一化书名, 归一化作者) 去重聚合，同一本书跨多源只出一条。
//    2. 分四桶，桶顺序即优先级：
//         ① exact    —— 书名精确 == 关键词，或作者精确 == 关键词
//         ② category —— 分类/标签字段包含关键词
//         ③ contains —— 书名包含关键词（但不是精确）
//         ④ other    —— 其余（仅简介命中、作者包含、甚至完全不命中）
//    3. 桶内排序：多源命中数降序（同数时按书名长度升序、再按书名字典序，保证稳定可测）。
//    4. 总条数上限 1000；超出计入 `truncatedCount`。
//
//  注意「精确」的口径：归一化后整串相等。关键词本身先归一化，
//  因此「三体 」与「三体」等价，全角字母与半角字母等价。
//

import Foundation

public enum BookMerger {

    /// 合并上限（需求 2-9 明确 1000）
    public static let maxResults = 1000

    /// 桶判定。抽出来单独可测。
    public static func bucket(
        item: SearchResultItem,
        keyword: String
    ) -> MergeBucket {
        let k = BookKey.normalize(keyword)
        guard !k.isEmpty else { return .other }

        let name = BookKey.normalize(item.name)
        let author = BookKey.normalize(item.author)
        let kind = BookKey.normalize(item.kind ?? "")
        let intro = BookKey.normalize(item.intro ?? "")

        if name == k || author == k { return .exact }
        if !kind.isEmpty, kind.contains(k) { return .category }
        if name.contains(k) { return .contains }
        // 作者包含 / 简介命中也归 other（需求把它们排在「包含」之后）
        _ = intro
        return .other
    }

    /// 合并主流程。
    /// - Parameter maxCount: 上限，默认 1000；测试可传小值验证截断。
    public static func merge(
        _ items: [SearchResultItem],
        keyword: String,
        maxCount: Int = maxResults
    ) -> (books: [MergedBook], truncated: Int) {
        guard !items.isEmpty else { return ([], 0) }

        // ① 聚合：key → 每个 key 保留一条代表 + 所有源的条目
        var grouped: [BookKey: [SearchResultItem]] = [:]
        var order: [BookKey] = []   // 保留首次出现顺序，保证桶内稳定
        for it in items {
            let key = BookKey(name: it.name, author: it.author)
            if grouped[key] == nil {
                grouped[key] = []
                order.append(key)
            }
            // 同一源重复条目（同一书的多个版本）只保留第一条
            if grouped[key]!.contains(where: { $0.origin == it.origin }) { continue }
            grouped[key]!.append(it)
        }

        // ② 生成 MergedBook
        var books: [MergedBook] = []
        books.reserveCapacity(grouped.count)
        for key in order {
            guard let srcs = grouped[key], let first = srcs.first else { continue }
            let b = bucket(item: first, keyword: keyword)
            // 多个源对同一本书的桶判定可能不同（某源给了 kind、某源没给）→ 取最优桶
            let best = srcs.map { self.bucket(item: $0, keyword: keyword) }
                .min(by: { $0.rawValue < $1.rawValue }) ?? b
            books.append(
                MergedBook(
                    key: key,
                    name: first.name,
                    author: first.author,
                    coverUrl: srcs.compactMap(\.coverUrl).first,
                    intro: srcs.compactMap(\.intro).first { !$0.isEmpty },
                    kind: srcs.compactMap(\.kind).first { !$0.isEmpty },
                    sourceCount: srcs.count,
                    sources: srcs,
                    bucket: best
                )
            )
        }

        // ③ 排序：桶优先 → 多源命中数降序 → 书名长度升序 → 书名字典序
        let sorted = books.sorted { lhs, rhs in
            if lhs.bucket.rawValue != rhs.bucket.rawValue {
                return lhs.bucket.rawValue < rhs.bucket.rawValue
            }
            if lhs.sourceCount != rhs.sourceCount { return lhs.sourceCount > rhs.sourceCount }
            if lhs.name.count != rhs.name.count { return lhs.name.count < rhs.name.count }
            return lhs.name < rhs.name
        }

        // ④ 上限
        if sorted.count > maxCount {
            return (Array(sorted.prefix(maxCount)), sorted.count - maxCount)
        }
        return (sorted, 0)
    }
}
