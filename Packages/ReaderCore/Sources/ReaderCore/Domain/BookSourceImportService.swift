//
//  BookSourceImportService.swift
//  ReaderCore
//
//  书源导入与校验（P0-1 / 需求 2-1 ~ 2-5 / 4-2）。
//
//  导入三种入口：本地文件、网络 URL、剪贴板 —— 三者最终都落到「一段文本」，
//  所以核心只有 `importPayload(_ text:)`，入口差异在外层（读文件 / 下载 / 读剪贴板）。
//
//  硬要求：
//    · 结果必须有「成功 N / 失败 M」，每条失败要有可查原因 → 见 `ImportReport`。
//    · 按 `bookSourceUrl` 去重（同 URL 后到者跳过，并计为「重复跳过」而非失败）。
//    · 含 JS 的书源按 Tier B 降级兼容导入（需求 2-5 / 任务模块一第 5 条）：
//      静态扫描升级为能力探测报告 —— 列出 java.* 缺项，书源仍可导入、可运行。
//    · bookSourceType ≥ 1 的源标记「该源为音频/图片/视频类型，本版本不支持」。
//
//  注意：标记不等于拒绝导入。产品上「导入成功但标记不可用」比「直接拒绝导入」更友好：
//  用户能看到这条源为什么用不了，也便于后续版本升级后自动可用。
//

import Foundation

// MARK: - 单条结果

public enum ImportOutcome: String, Sendable {
    /// 导入成功且可用于搜索/阅读
    case ok
    /// 导入成功，含 JS —— Tier B 降级兼容（能力探测报告缺项，源仍可运行）
    case jsDegraded
    /// 导入成功，但类型为音频/图片/文件/视频 —— 本版本不支持
    case unsupportedType
    /// 重复（bookSourceUrl 已存在）
    case duplicate
    /// 解析失败（JSON 非法 / 结构不符）
    case failed
}

public struct ImportItemResult: Sendable, Identifiable {
    public var id: String { String(index) + "|" + (sourceName ?? "") }
    public var index: Int
    public var sourceName: String?
    public var sourceURL: String?
    public var outcome: ImportOutcome
    /// 失败原因 / 不可用原因；`ok` 时为 nil
    public var reason: String?
    /// 命中的 JS 位置明细（outcome == .jsDegraded 时非空）
    public var jsHits: [JSHit]
    public var source: BookSource?
    /// 来源描述（v1.2.3）：如「文件：xxx.json」「手动粘贴」「https://…」。
    /// 多文件导入时用于把失败条目定位到具体文件；单文件/粘贴入口下仅供 UI 补充说明。
    public var originDescription: String? = nil
    /// 该源用到的 java.* 方法（能力探测）
    public var javaMethods: [String] = []
    /// 其中本版未实现的方法（能力探测缺项，UI 提示精确到方法名）
    public var missingMethods: [String] = []

    public var isImported: Bool {
        switch outcome {
        case .ok, .jsDegraded, .unsupportedType: return true
        case .duplicate, .failed: return false
        }
    }
    /// 是否可用于实际搜索（Tier B：jsDegraded 的源也可用，运行到缺项方法时精确报错）
    public var isUsable: Bool { outcome == .ok || outcome == .jsDegraded }
}

// MARK: - 汇总报告

public struct ImportReport: Sendable {
    public var items: [ImportItemResult]
    /// 新增入库条数（ok + jsDegraded + unsupportedType）
    public var successCount: Int
    public var failureCount: Int
    public var duplicateCount: Int
    public var jsDegradedCount: Int
    public var unsupportedTypeCount: Int

    /// 跨模块（App 层）构造用；v1.2.1 补 public（原 memberwise init 为 internal）。
    public init(
        items: [ImportItemResult],
        successCount: Int,
        failureCount: Int,
        duplicateCount: Int,
        jsDegradedCount: Int,
        unsupportedTypeCount: Int
    ) {
        self.items = items
        self.successCount = successCount
        self.failureCount = failureCount
        self.duplicateCount = duplicateCount
        self.jsDegradedCount = jsDegradedCount
        self.unsupportedTypeCount = unsupportedTypeCount
    }

    public var usableCount: Int { items.filter(\.isUsable).count }

    /// 「成功 N / 失败 M」文案（需求 2-1 要求导入结果必须显示）
    public var headline: String {
        "成功 \(successCount) / 失败 \(failureCount)"
            + (duplicateCount > 0 ? "（重复跳过 \(duplicateCount)）" : "")
            + (jsDegradedCount > 0 ? "（含 JS 降级 \(jsDegradedCount)，可运行）" : "")
    }

    /// 失败与不可用的明细，逐条可查（需求 2-2）
    public var problemItems: [ImportItemResult] {
        items.filter { $0.outcome != .ok }
    }
}

// MARK: - 输入形态

/// 一段待导入的文本，附带来源描述。
public struct ImportPayload: Sendable {
    public var text: String
    /// 展示用来源：如「剪贴板」「文件：xxx.json」「https://...」
    public var originDescription: String
    /// 网络导入时的原始 URL
    public var remoteURL: String?

    public init(text: String, originDescription: String, remoteURL: String? = nil) {
        self.text = text
        self.originDescription = originDescription
        self.remoteURL = remoteURL
    }
}

// MARK: - 服务

public struct BookSourceImportService: Sendable {
    /// 已存在的 bookSourceUrl 集合（由调用方从库中查出传入，避免依赖具体持久层）
    public var existingURLs: Set<String>

    public init(existingURLs: Set<String> = []) {
        self.existingURLs = existingURLs
    }

    /// 核心：解析一段文本并逐条判定。
    /// 支持三种形态：
    ///   ① 单个 JSON 对象（一个书源）
    ///   ② JSON 数组（多个书源）
    ///   ③ `{"sources":[...]}` 这类民间变体
    public func importPayload(_ payload: ImportPayload) -> ImportReport {
        var seen = existingURLs
        return summarize(parsePayload(payload, seen: &seen, startIndex: 1))
    }

    /// 解析单份文本。`index` 从 `startIndex` 起连续编号，`seen` 跨调用累积。
    func parsePayload(
        _ payload: ImportPayload,
        seen: inout Set<String>,
        startIndex: Int
    ) -> [ImportItemResult] {
        var items: [ImportItemResult] = []

        guard let root = JsonValue.parse(payload.text) else {
            let preview = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(
                ImportItemResult(
                    index: startIndex,
                    sourceName: nil,
                    sourceURL: nil,
                    outcome: .failed,
                    reason: preview.isEmpty
                        ? "内容为空（来源：\(payload.originDescription)）"
                        : "不是合法 JSON（来源：\(payload.originDescription)）；开头片段：\(String(preview.prefix(40)))",
                    jsHits: [],
                    source: nil
                )
            )
            return stamped(items, payload: payload)
        }

        let candidates = extractCandidates(from: root)
        if candidates.isEmpty {
            items.append(
                ImportItemResult(
                    index: startIndex,
                    sourceName: nil,
                    sourceURL: nil,
                    outcome: .failed,
                    reason: "JSON 合法但不是书源结构（未找到含 bookSourceUrl 的对象）",
                    jsHits: [],
                    source: nil
                )
            )
            return stamped(items, payload: payload)
        }

        for (offset, candidate) in candidates.enumerated() {
            let index = startIndex + offset
            guard case .object(let obj) = candidate else { continue }
            let name = obj["bookSourceName"]?.text
            let url = obj["bookSourceUrl"]?.text
            let displayName = (name?.isEmpty == false) ? name : url

            // ① 必填字段
            guard let urlText = url, !urlText.trimmingCharacters(in: .whitespaces).isEmpty else {
                items.append(
                    ImportItemResult(
                        index: index, sourceName: displayName, sourceURL: url,
                        outcome: .failed,
                        reason: "缺少 bookSourceUrl（书源必须声明唯一地址）",
                        jsHits: [], source: nil
                    )
                )
                continue
            }

            // ② 反序列化（规则子对象兼容「对象 / 字符串」两形态）
            guard let source = decodeSource(candidate) else {
                items.append(
                    ImportItemResult(
                        index: index, sourceName: displayName, sourceURL: urlText,
                        outcome: .failed,
                        reason: "字段类型不符，无法解析该书源规则（bookSourceUrl=\(urlText)）",
                        jsHits: [], source: nil
                    )
                )
                continue
            }

            // ②.5 规则字段可解析性（P1-20：畸形规则不再静默变空）
            let ruleIssues = source.ruleDecodeIssues + source.validateRuleDecoding()
            if !ruleIssues.isEmpty {
                items.append(
                    ImportItemResult(
                        index: index, sourceName: displayName, sourceURL: urlText,
                        outcome: .failed,
                        reason: "规则字段无法解析，导入后该源无法搜索/阅读，已按失败处理："
                            + ruleIssues.joined(separator: "；"),
                        jsHits: [], source: nil
                    )
                )
                continue
            }

            // ③ 去重
            if seen.contains(urlText) {
                items.append(
                    ImportItemResult(
                        index: index, sourceName: displayName, sourceURL: urlText,
                        outcome: .duplicate,
                        reason: "bookSourceUrl 已存在，已跳过（\(urlText)）",
                        jsHits: [], source: source
                    )
                )
                continue
            }
            seen.insert(urlText)

            // ④ 类型不支持（优先于 JS 判定：音频源的规则字段本来也可能带 JS，
            //    但对用户来说「类型不支持」是更根本的原因）
            if !source.isTextSource {
                items.append(
                    ImportItemResult(
                        index: index, sourceName: displayName, sourceURL: urlText,
                        outcome: .unsupportedType,
                        reason: "该源为\(source.unsupportedTypeDescription ?? "非文本")类型，本版本不支持",
                        jsHits: [], source: source
                    )
                )
                continue
            }

            // ⑤ JS 能力探测（Tier B：可导入可运行，报告 java.* 缺项）
            let scan = JSStaticScanner.scan(source)
            if scan.usesJS {
                items.append(
                    ImportItemResult(
                        index: index, sourceName: displayName, sourceURL: urlText,
                        outcome: .jsDegraded,
                        reason: scan.userFacingReason,
                        jsHits: scan.hits, source: source,
                        javaMethods: scan.javaMethods,
                        missingMethods: scan.missingMethods
                    )
                )
                continue
            }

            items.append(
                ImportItemResult(
                    index: index, sourceName: displayName, sourceURL: urlText,
                    outcome: .ok, reason: nil, jsHits: [], source: source
                )
            )
        }

        return stamped(items, payload: payload)
    }

    /// 给条目补上来源描述（多文件导入时 UI 据此定位到具体文件）并统一编号起点。
    private func stamped(_ items: [ImportItemResult], payload: ImportPayload) -> [ImportItemResult] {
        var out = items
        for i in out.indices where out[i].originDescription == nil {
            out[i].originDescription = payload.originDescription
        }
        return out
    }

    // MARK: 内部

    /// 从任意 JSON 根里捞出「书源对象」列表。
    func extractCandidates(from root: JsonValue) -> [JsonValue] {
        switch root {
        case .array(let arr):
            return arr.filter { v in
                if case .object(let o) = v, o["bookSourceUrl"] != nil { return true }
                return false
            }
        case .object(let o):
            if o["bookSourceUrl"] != nil { return [root] }
            for key in ["sources", "data", "bookSources", "items"] {
                if case .array(let arr)? = o[key] {
                    let picked = arr.filter { v in
                        if case .object(let oo) = v, oo["bookSourceUrl"] != nil { return true }
                        return false
                    }
                    if !picked.isEmpty { return picked }
                }
            }
            return []
        default:
            return []
        }
    }

    /// 用 JSONDecoder 走 BookSource 的 custom init。
    private func decodeSource(_ v: JsonValue) -> BookSource? {
        guard let data = try? JSONEncoder().encode(v) else { return nil }
        return try? JSONDecoder().decode(BookSource.self, from: data)
    }

    /// internal（v1.2.3）：`BookSourceFileImporter` 的多文件入口要共用同一汇总口径。
    func summarize(_ items: [ImportItemResult]) -> ImportReport {
        ImportReport(
            items: items,
            successCount: items.filter(\.isImported).count,
            failureCount: items.filter { $0.outcome == .failed }.count,
            duplicateCount: items.filter { $0.outcome == .duplicate }.count,
            jsDegradedCount: items.filter { $0.outcome == .jsDegraded }.count,
            unsupportedTypeCount: items.filter { $0.outcome == .unsupportedType }.count
        )
    }
}

// MARK: - 网络 URL 导入

extension BookSourceImportService {
    /// 从网络 URL 拉取书源文本再导入（P0-1 的第二种入口）。
    public func importRemote(
        url: String,
        client: HTTPClient
    ) async throws -> ImportReport {
        let request = HTTPRequest(
            url: url,
            headers: ["Accept": "application/json, text/plain, */*"],
            timeoutSeconds: 30,
            retry: 1,
            sourceKey: nil
        )
        let resp = try await client.fetch(request)
        return importPayload(
            ImportPayload(text: resp.text, originDescription: url, remoteURL: resp.finalURL)
        )
    }
}
