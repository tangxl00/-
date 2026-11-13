//
//  BookSourceFileImporter.swift
//  ReaderCore
//
//  书源「从文件导入」（v1.2.3，补齐 P0-1 三入口里的「本地文件」一项）。
//
//  分层原因：
//    · 文件选择（UIDocumentPicker）、安全作用域（startAccessingSecurityScopedResource）
//      都是 App 层的事，ReaderCore 不该依赖 SwiftUI/UIKit，也不该做磁盘 I/O ——
//      这样 Windows/Linux 上的 XCTest 才能真正覆盖「解码 + 合并导入」。
//    · 所以 App 层只负责「选文件 → 读成 Data or 记下读失败原因」，把 `SourceFileDraft`
//      数组交进来；编码识别、JSON 解析、逐条判定、跨文件去重、结果汇总全在本文件。
//
//  编码口径：复用 `TextDecoder.detectAndDecode`（BOM → 严格 UTF-8 → GBK → UTF-16LE），
//  与 TXTImporter 同一套逻辑 —— 书源文件常以 GBK 分发（`.json` 后缀也一样），
//  只按 UTF-8 读会把中文源名读成乱码并最终报「不是合法 JSON」。
//

import Foundation

// MARK: - 输入：一个待导入的文件

/// App 层读完的文件草稿。
///
/// `data` 与 `readError` 二选一：
///   · 读到内容 → `data` 有值、`readError == nil`
///   · 读取失败（权限/损坏/编码） → `data == nil`、`readError` 写明原因
///
/// 把「读失败」也建模成条目而不是直接抛出，是为了满足「多文件汇总一份结果」：
/// 3 个文件里 1 个读不了，其余 2 个仍应导入，且最终「失败 M」里要包含那 1 个。
public struct SourceFileDraft: Sendable {
    public var fileName: String
    public var data: Data?
    public var readError: String?

    public init(fileName: String, data: Data?, readError: String? = nil) {
        self.fileName = fileName
        self.data = data
        self.readError = readError
    }

    /// 展示用来源描述：「文件：xxx.json」
    public var originDescription: String { "文件：" + fileName }
}

// MARK: - 解码结果

public struct SourceFileDecodeResult: Sendable {
    public var text: String
    public var encoding: TextEncodingGuess
    /// 供 UI 展示的说明（如「自动识别编码为 GBK」）
    public var notes: [String]

    public init(text: String, encoding: TextEncodingGuess, notes: [String] = []) {
        self.text = text
        self.encoding = encoding
        self.notes = notes
    }
}

// MARK: - 服务扩展

extension BookSourceImportService {

    /// 解码单个文件内容。
    ///
    /// 顺序与 `TXTImporter` 完全一致（复用 `TextDecoder`）：
    /// BOM → 严格 UTF-8 → GBK → UTF-16LE；全都不干净才抛 `undecodable`。
    /// 因此 GBK 编码的书源文件能正常识别，纯 UTF-8 文件走第一条分支、不做多余探测。
    public static func decodeFileData(_ data: Data) throws -> SourceFileDecodeResult {
        guard !data.isEmpty else {
            throw BookSourceFileImportError.emptyFile
        }
        let detected = try TextDecoder.detectAndDecode(data)
        var notes: [String] = []
        if detected.encoding != .utf8 {
            notes.append("自动识别编码为 \(detected.encoding.displayName)（非 UTF-8）")
        }
        return SourceFileDecodeResult(
            text: detected.text,
            encoding: detected.encoding,
            notes: notes
        )
    }

    /// 多文件合并导入。
    ///
    /// 语义与 `importPayload` 完全一致，只是：
    ///   · 每个文件先解码（GBK/UTF-16 也能进来）；
    ///   · 单一 `seen` 集合跨文件累积 —— 同一 `bookSourceUrl` 在多个文件里出现时，
    ///     后到的记为 `duplicate`（和单段导入里「数组内重复」同口径），不会重复入库；
    ///   · 条目编号跨文件连续（1..N），每条都带 `originDescription`，失败可定位到具体文件。
    ///
    /// 单个文件解码失败不会中断整批：它会变成一条 `failed` 条目（原因含文件名），
    /// 其余文件照常导入。
    public func importFiles(_ drafts: [SourceFileDraft]) -> ImportReport {
        var seen = existingURLs
        var items: [ImportItemResult] = []

        for draft in drafts {
            let startIndex = items.count + 1

            if let readError = draft.readError, draft.data == nil {
                items.append(
                    ImportItemResult(
                        index: startIndex,
                        sourceName: draft.fileName,
                        sourceURL: nil,
                        outcome: .failed,
                        reason: "无法读取文件：\(readError)（来源：\(draft.originDescription)）",
                        jsHits: [],
                        source: nil,
                        originDescription: draft.originDescription
                    )
                )
                continue
            }

            guard let data = draft.data else {
                items.append(
                    ImportItemResult(
                        index: startIndex,
                        sourceName: draft.fileName,
                        sourceURL: nil,
                        outcome: .failed,
                        reason: "文件内容缺失（来源：\(draft.originDescription)）",
                        jsHits: [],
                        source: nil,
                        originDescription: draft.originDescription
                    )
                )
                continue
            }

            let decoded: SourceFileDecodeResult
            do {
                decoded = try Self.decodeFileData(data)
            } catch {
                items.append(
                    ImportItemResult(
                        index: startIndex,
                        sourceName: draft.fileName,
                        sourceURL: nil,
                        outcome: .failed,
                        reason: "\(describeDecodeFailure(error))（来源：\(draft.originDescription)）",
                        jsHits: [],
                        source: nil,
                        originDescription: draft.originDescription
                    )
                )
                continue
            }

            items.append(
                contentsOf: parsePayload(
                    ImportPayload(
                        text: decoded.text,
                        originDescription: draft.originDescription
                    ),
                    seen: &seen,
                    startIndex: startIndex
                )
            )
        }

        return summarize(items)
    }

    private func describeDecodeFailure(_ error: Error) -> String {
        if let e = error as? BookSourceFileImportError { return e.description }
        if let e = error as? TextDecoderError {
            switch e {
            case .undecodable:
                return "无法识别文件编码（UTF-8 / GBK 均解码失败），请另存为 UTF-8 后重试"
            case .resourceMissing, .corruptTable:
                return e.description
            }
        }
        return "解析文件失败：\(error)"
    }
}

// MARK: - 错误

public enum BookSourceFileImportError: Error, CustomStringConvertible, Sendable {
    case emptyFile

    public var description: String {
        switch self {
        case .emptyFile: return "文件为空（0 字节）"
        }
    }
}

// MARK: - 按来源汇总（UI 逐文件展示用）

extension ImportReport {
    /// 单个来源的汇总。
    public struct OriginSummary: Sendable, Identifiable {
        public var id: String { origin }
        public var origin: String
        public var successCount: Int
        public var failureCount: Int
        public var duplicateCount: Int

        public var line: String {
            "成功 \(successCount) / 失败 \(failureCount)"
                + (duplicateCount > 0 ? "（重复跳过 \(duplicateCount)）" : "")
        }
    }

    /// 按 `originDescription` 分组，顺序取首次出现顺序（多文件时即文件选择顺序）。
    ///
    /// 单文件/粘贴/URL 入口下只会有一组，UI 可只展示 `headline`、忽略这里。
    public var originSummaries: [OriginSummary] {
        var order: [String] = []
        var map: [String: OriginSummary] = [:]
        for item in items {
            let key = item.originDescription ?? ""
            if map[key] == nil {
                order.append(key)
                map[key] = OriginSummary(origin: key, successCount: 0, failureCount: 0, duplicateCount: 0)
            }
            switch item.outcome {
            case .ok, .jsDegraded, .unsupportedType:
                map[key]?.successCount += 1
            case .duplicate:
                map[key]?.duplicateCount += 1
            case .failed:
                map[key]?.failureCount += 1
            }
        }
        return order.compactMap { map[$0] }
    }
}
