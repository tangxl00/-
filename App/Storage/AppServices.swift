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
    /// P0#1（v1.2.0）：JS Tier B 真运行时。原实现 `RuleEvaluator()` 未传 jsRuntime，
    /// 全仓也没有 JSCRuntime 实例，导致所有 `@js:` 书源必然抛 jsUnsupported、Tier B 能力为零。
    /// 这里 App 启动即创建一个，并注入到 RuleEvaluator，搜索 / 详情 / 正文 / 导入扫描共用同一实例。
    let jsRuntime: JSRuntime?
    let evaluator: RuleEvaluator

    @Published var sourceCount: Int = 0
    @Published var enabledSourceCount: Int = 0

    init(container: ModelContainer) {
        self.container = container
        self.client = HTTPClient()
        #if canImport(JavaScriptCore)
        let runtime: JSRuntime? = JSCRuntime()
        #else
        let runtime: JSRuntime? = nil
        #endif
        self.jsRuntime = runtime
        self.evaluator = RuleEvaluator(jsRuntime: runtime)
        // P0#2（v1.2.0）：首次启动灌入 8 条默认水印规则（幂等）
        installDefaultReplaceRulesIfNeeded()
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
        persistImported(report, existingCount: existing.count)
        return report
    }

    /// 从本地文件导入书源（v1.2.3，P0-1 三入口里的「本地文件」）。
    ///
    /// App 层只负责读文件（安全作用域 + Data），编码识别 / JSON 解析 / 跨文件去重
    /// 全在 `BookSourceImportService.importFiles`，与粘贴、URL 两条入口共用同一口径。
    func importSourcesFromFiles(_ drafts: [SourceFileDraft]) -> ImportReport {
        let existing = Set(allSources().map(\.bookSourceUrl))
        let service = BookSourceImportService(existingURLs: existing)
        let report = service.importFiles(drafts)
        persistImported(report, existingCount: existing.count)
        return report
    }

    /// 落库：只写新导入成功的条目（三条导入口径一致）。
    private func persistImported(_ report: ImportReport, existingCount: Int) {
        let context = ModelContext(container)
        var order = existingCount
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
    }

    /// 通过 URL 导入（服务内部拉取远端内容；异步）。
    func importSourcesFromURL(_ urlString: String) async throws -> ImportReport {
        let existing = Set(allSources().map(\.bookSourceUrl))
        let service = BookSourceImportService(existingURLs: existing)
        let report = try await service.importRemote(url: urlString, client: client)
        persistImported(report, existingCount: existing.count)
        return report
    }

    // MARK: - 搜索 / 详情服务（每次请求用共享 client）

    func makeSearchService() -> SearchService {
        SearchService(client: client, evaluator: evaluator)
    }

    func makeBookService() -> BookService {
        BookService(client: client, evaluator: evaluator)
    }

    // MARK: - P0#2 净化规则（SwiftData 落库 + 六步流水线接线）

    /// 阅读链路用的净化输入：按 sortOrder 升序取启用规则。
    /// 注：reSegment / 繁简转换两个设置项 v1.2.0 尚未接入设置界面，按默认（关闭）
    /// 执行；用户替换规则（含 scope / excludeScope 书名过滤、超时熔断）已全量生效。
    func purifyInput() -> ContentPurifyInput? {
        let rules = replaceRules()
        guard !rules.isEmpty else { return nil }
        return ContentPurifyInput(rules: rules, options: ContentProcessOptions())
    }

    func replaceRules() -> [ReplaceRule] {
        let context = ModelContext(container)
        let records = (try? context.fetch(FetchDescriptor<ReplaceRuleRecord>())) ?? []
        return records
            .sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
            .map(\.replaceRule)
    }

    func saveReplaceRule(_ rule: ReplaceRule) {
        let context = ModelContext(container)
        let predicate = #Predicate<ReplaceRuleRecord> { $0.ruleID == rule.id }
        let existing = (try? context.fetch(FetchDescriptor<ReplaceRuleRecord>(predicate: predicate)))?.first
        let record = existing ?? ReplaceRuleRecord(rule: rule)
        record.apply(rule)
        if existing == nil { context.insert(record) }
        try? context.save()
    }

    func deleteReplaceRule(id: String) {
        let context = ModelContext(container)
        let predicate = #Predicate<ReplaceRuleRecord> { $0.ruleID == id }
        for r in (try? context.fetch(FetchDescriptor<ReplaceRuleRecord>(predicate: predicate))) ?? [] {
            context.delete(r)
        }
        try? context.save()
    }

    /// 排序：按传入 id 顺序重写 sortOrder（拖拽 / 上下移都走这里）。
    func reorderReplaceRules(ids: [String]) {
        let context = ModelContext(container)
        let records = (try? context.fetch(FetchDescriptor<ReplaceRuleRecord>())) ?? []
        var byID: [String: ReplaceRuleRecord] = [:]
        for r in records { byID[r.ruleID] = r }
        for (order, id) in ids.enumerated() { byID[id]?.sortOrder = order }
        try? context.save()
    }

    func setReplaceRuleEnabled(id: String, enabled: Bool) {
        let context = ModelContext(container)
        let predicate = #Predicate<ReplaceRuleRecord> { $0.ruleID == id }
        if let r = (try? context.fetch(FetchDescriptor<ReplaceRuleRecord>(predicate: predicate)))?.first {
            r.enable = enabled
            try? context.save()
        }
    }

    /// 首次启动灌入 8 条默认水印规则（幂等：已有规则则不动）。
    func installDefaultReplaceRulesIfNeeded() {
        let context = ModelContext(container)
        let count = (try? context.fetchCount(FetchDescriptor<ReplaceRuleRecord>())) ?? 0
        guard count == 0 else { return }
        for r in DefaultPurifyRules.rules() { context.insert(ReplaceRuleRecord(rule: r)) }
        try? context.save()
    }
}
