//
//  AppServices.swift
//  TingDu
//
//  共享服务容器：HTTP 客户端 / 规则求值器 / 搜索 / 详情 / 导入。
//  iOS 专属层，未编译（沙箱无 Xcode）。
//

import Foundation
import SwiftData
import ReaderCore

/// 全局共享服务。App 启动时创建一次，经 environment 注入。
@MainActor
final class AppServices: ObservableObject {
    let container: ModelContainer

    /// 全局 HTTP 客户端（带限速与重试；User-Agent 与 legado 观测值一致）
    let client: HTTPClient
    let evaluator: RuleEvaluator

    @Published var sourceCount: Int = 0
    @Published var enabledSourceCount: Int = 0

    init(container: ModelContainer) {
        self.container = container
        self.client = HTTPClient()
        self.evaluator = RuleEvaluator()
        refreshSourceCounts()
    }

    // MARK: - 书源

    func refreshSourceCounts() {
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<SourceRecord>())) ?? []
        sourceCount = all.count
        enabledSourceCount = all.filter(\.enabled).count
    }

    /// 全部书源（按 customOrder 排序）
    func allSources() -> [BookSource] {
        let context = ModelContext(container)
        let records = (try? context.fetch(FetchDescriptor<SourceRecord>())) ?? []
        return records
            .sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
            .compactMap(\.bookSource)
    }

    /// 参与搜索的书源：已启用
    func enabledSources() -> [BookSource] {
        allSources().filter(\.enabled)
    }

    /// 指定 URL 的书源
    func source(url: String) -> BookSource? {
        let context = ModelContext(container)
        let predicate = #Predicate<SourceRecord> { $0.url == url }
        let record = (try? context.fetch(FetchDescriptor<SourceRecord>(predicate: predicate)))?.first
        return record?.bookSource
    }

    func setSourceEnabled(url: String, enabled: Bool) {
        let context = ModelContext(container)
        let predicate = #Predicate<SourceRecord> { $0.url == url }
        if let record = (try? context.fetch(FetchDescriptor<SourceRecord>(predicate: predicate)))?.first {
            record.enabled = enabled
            try? context.save()
        }
        refreshSourceCounts()
    }

    func deleteSource(url: String) {
        let context = ModelContext(container)
        let predicate = #Predicate<SourceRecord> { $0.url == url }
        if let record = (try? context.fetch(FetchDescriptor<SourceRecord>(predicate: predicate)))?.first {
            context.delete(record)
            try? context.save()
        }
        refreshSourceCounts()
    }

    /// 导入书源（粘贴 JSON / 远程 URL）。返回导入报告。
    func importSources(text: String, remoteURL: String? = nil) -> ImportReport {
        let existing = Set(allSources().map(\.bookSourceUrl))
        let service = BookSourceImportService(existingURLs: existing)
        let payload = ImportPayload(
            text: text,
            originDescription: remoteURL ?? "手动粘贴",
            remoteURL: remoteURL
        )
        let report = service.importPayload(payload)

        // 落库：只写新导入成功的
        let context = ModelContext(container)
        var order = existing.count
        for item in report.items where item.isImported {
            guard let source = item.source,
                  let data = try? JSONEncoder().encode(source) else { continue }
            context.insert(SourceRecord(
                url: source.bookSourceUrl,
                name: source.bookSourceName,
                group: source.bookSourceGroup ?? "",
                enabled: source.enabled,
                sortOrder: order,
                payload: data
            ))
            order += 1
        }
        try? context.save()
        refreshSourceCounts()
        return report
    }

    /// 通过 URL 导入（服务内部拉取远端内容；异步）。
    func importSourcesFromURL(_ urlString: String) async throws -> ImportReport {
        let existing = Set(allSources().map(\.bookSourceUrl))
        let service = BookSourceImportService(existingURLs: existing)
        let report = try await service.importRemote(url: urlString, client: client)
        let context = ModelContext(container)
        var order = existing.count
        for item in report.items where item.isImported {
            guard let source = item.source,
                  let data = try? JSONEncoder().encode(source) else { continue }
            context.insert(SourceRecord(
                url: source.bookSourceUrl,
                name: source.bookSourceName,
                group: source.bookSourceGroup ?? "",
                enabled: source.enabled,
                sortOrder: order,
                payload: data
            ))
            order += 1
        }
        try? context.save()
        refreshSourceCounts()
        return report
    }

    // MARK: - 搜索 / 详情服务（每次请求用共享 client）

    func makeSearchService() -> SearchService {
        SearchService(client: client, evaluator: evaluator)
    }

    func makeBookService() -> BookService {
        BookService(client: client, evaluator: evaluator)
    }
}
