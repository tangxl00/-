//
//  TXTImporter.swift
//  ReaderCore
//
//  本地 TXT 导入核心（P0-7）。
//
//  三件事：
//    1. 编码识别：BOM → 严格 UTF-8 → GBK → UTF-16LE（复用 TextDecoder），并可手动指定。
//    2. 分章：两套规则 —— 「默认规则」（覆盖常见中文章节标题）与「备选规则」
//       （更宽松/更严格的一版），都支持手动切换；另有一档「按字数切分」兜底，
//       并在结果里说明「因未匹配到章节标题，已按每 N 字切分」。
//    3. 大文件：≥10MB 也不能崩。这里按「流式读取行 + 增量匹配」处理：
//       先把 Data 按行切开（逐行扫描，不做全文正则），只在内存里保留
//       「章节标题 + 起始字符偏移」，正文按偏移区间懒加载。
//
//  为什么要按「字符偏移」而不是「行号」：需求 4.9 的续读口径是「章节 + 字符偏移」，
//  TXT 全书只有一个大字符串，章节区间用字符偏移最直接、且和阅读器进度模型一致。
//

import Foundation

// MARK: - 分章规则

/// 一套分章规则：行匹配用 `NSRegularExpression`，标题清洗用 `titleCleanup`。
public struct TXTChapterRule: Sendable, Identifiable {
    public var id: String
    public var displayName: String
    /// 行是否是章节标题
    public var pattern: String
    /// 标题里需要丢弃的前后缀（例如「正文」字样）
    public var titleCleanup: [String]
    /// 「目录行」最大长度：超过这个长度的行即使是标题格式也当正文（防误判）
    public var maxTitleLength: Int
    public var note: String

    public init(
        id: String,
        displayName: String,
        pattern: String,
        titleCleanup: [String] = [],
        maxTitleLength: Int = 40,
        note: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.pattern = pattern
        self.titleCleanup = titleCleanup
        self.maxTitleLength = maxTitleLength
        self.note = note
    }
}

public enum TXTChapterRules {
    /// 默认规则：匹配「第X章 / 第X节 / 第X回 / 第X卷」以及「序章 / 楔子 / 尾声 / 番外」。
    /// 这是 TXT 小说里覆盖率最高的一档。
    public static let standard = TXTChapterRule(
        id: "standard",
        displayName: "默认规则（第X章/节/回/卷）",
        pattern:
            "^[\\s\\u3000]*(?:正文[\\s\\u3000]*)?"
            + "(?:第[\\s\\u3000]{0,2}[0-9０-９一二三四五六七八九十百千万零〇两]{1,12}"
            + "[\\s\\u3000]{0,2}[章节回卷集话篇])"
            + "|^[\\s\\u3000]*(?:序章|序言|楔子|引子|前言|尾声|后记|终章|番外)(?:[\\s\\u3000：:．.、-]|$)",
        titleCleanup: ["正文"],
        maxTitleLength: 40,
        note: "覆盖第X章/节/回/卷与序章楔子等常见标题；对「1. 标题」「Chapter N」不生效"
    )

    /// 备选规则：在默认规则基础上放宽，额外接受
    /// 「Chapter N / CHAPTER N」「1、标题」「（一）标题」「卷X 标题」这四类排版。
    /// 用于默认规则匹配不到章节的排版变体。
    public static let loose = TXTChapterRule(
        id: "loose",
        displayName: "备选规则（Chapter N / 数字编号 / 卷X）",
        pattern:
            "^[\\s\\u3000]*(?:正文[\\s\\u3000]*)?"
            + "(?:第[\\s\\u3000]{0,2}[0-9０-９一二三四五六七八九十百千万零〇两]{1,12}"
            + "[\\s\\u3000]{0,2}[章节回卷集话篇])"
            + "|^[\\s\\u3000]*(?:序章|序言|楔子|引子|前言|尾声|后记|终章|番外)(?:[\\s\\u3000：:．.、-]|$)"
            + "|^[\\s\\u3000]*[Cc][Hh][Aa][Pp][Tt][Ee][Rr][\\s\\u3000]{1,3}[0-9IVXLCivxlc]{1,8}(?:[\\s\\u3000：:．.、-]|$)"
            + "|^[\\s\\u3000]*[0-9０-９]{1,4}[\\s\\u3000]{0,1}[、．.，,\\-][\\s\\u3000]{0,3}[^\\s\\u3000]{1,30}$"
            + "|^[\\s\\u3000]*[（(][\\s\\u3000]{0,1}[一二三四五六七八九十0-9]{1,6}[\\s\\u3000]{0,1}[）)][\\s\\u3000]{0,3}[^\\s\\u3000]{1,30}$"
            + "|^[\\s\\u3000]*卷[\\s\\u3000]{1,2}[0-9０-９一二三四五六七八九十百千万零〇两]{1,12}(?:[\\s\\u3000：:．.、-]|$)",
        titleCleanup: ["正文"],
        maxTitleLength: 40,
        note: "在默认规则上加 Chapter N、1、标题、(一)标题、卷X 四类格式，误判率略高"
    )

    public static let all: [TXTChapterRule] = [standard, loose]

    public static func rule(id: String) -> TXTChapterRule? {
        all.first { $0.id == id }
    }
}

// MARK: - 导入结果

public struct TXTChapter: Sendable, Equatable {
    public var title: String
    /// 章节标题行在全文中的起始字符偏移
    public var start: Int
    /// 章节结束字符偏移（不含）
    public var end: Int
    /// 标题后到下一章之前的正文长度
    public var length: Int { max(0, end - start) }
    /// 是否由兜底按字数切分产生
    public var isSynthetic: Bool
}

public struct TXTImportResult: Sendable {
    public var bookName: String
    public var encoding: TextEncodingGuess
    public var ruleID: String
    public var chapters: [TXTChapter]
    /// 供 UI 展示的说明（兜底切分、编码回退等）
    public var notes: [String]

    public var totalLength: Int { chapters.last?.end ?? 0 }
    public var chapterCount: Int { chapters.count }
}

public enum TXTImportError: Error, CustomStringConvertible, Sendable {
    case emptyFile
    case undecodable
    case unreadable(String)

    public var description: String {
        switch self {
        case .emptyFile: return "文件为空"
        case .undecodable: return "无法识别文件编码（UTF-8 / GBK 均解码失败）"
        case .unreadable(let m): return "读取文件失败：\(m)"
        }
    }
}

// MARK: - 导入器

public enum TXTImporter {

    /// 按字数兜底切分的目标长度。取 8000 字符：既能让单章渲染与分页可控，
    /// 也不至于把一章切得太碎导致「上一章/下一章」翻得毫无意义。
    public static let fallbackChunkSize = 8000

    /// 从 Data 导入。
    /// - Parameters:
    ///   - bookName: 书名（一般取文件名去掉扩展名）
    ///   - forcedEncoding: 手动指定编码；nil = 自动识别
    ///   - ruleID: 使用哪套分章规则；nil = 默认规则
    public static func `import`(
        data: Data,
        bookName: String,
        forcedEncoding: TextEncodingGuess? = nil,
        ruleID: String? = nil
    ) throws -> TXTImportResult {
        var notes: [String] = []
        let text: String
        let encoding: TextEncodingGuess

        if let forced = forcedEncoding {
            guard let decoded = try? TextDecoder.decode(data, as: forced), !decoded.isEmpty else {
                throw TXTImportError.undecodable
            }
            text = decoded
            encoding = forced
        } else {
            let detected = try TextDecoder.detectAndDecode(data)
            text = detected.text
            encoding = detected.encoding
            if encoding != .utf8 {
                notes.append("自动识别编码为 \(encoding.displayName)（非 UTF-8）")
            }
        }

        guard !text.isEmpty else { throw TXTImportError.emptyFile }

        let rule = TXTChapterRules.rule(id: ruleID ?? TXTChapterRules.standard.id)
            ?? TXTChapterRules.standard

        var result = try chapterize(text: text, bookName: bookName, rule: rule)
        result.encoding = encoding
        notes.forEach { result.notes.append($0) }
        return result
    }

    /// 从文件 URL 导入（大文件也走这条：先整体读入 Data，再流式按行扫描）。
    /// 说明：≥10MB 的文件整体读入 Data 在现代 iOS 上不成问题（10MB 文本约 10~20MB 内存），
    /// 真正的风险来自「全文一次性正则匹配」——这里按行扫描可避免回溯爆炸。
    public static func `import`(
        fileURL: URL,
        bookName: String? = nil,
        forcedEncoding: TextEncodingGuess? = nil,
        ruleID: String? = nil
    ) throws -> TXTImportResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw TXTImportError.unreadable(error.localizedDescription)
        }
        let name = bookName ?? fileURL.deletingPathExtension().lastPathComponent
        return try `import`(data: data, bookName: name, forcedEncoding: forcedEncoding, ruleID: ruleID)
    }

    // MARK: - 分章

    /// 分章主流程：逐行扫描 → 命中标题即开新章 → 没有命中则兜底按字数切分。
    public static func chapterize(
        text: String,
        bookName: String,
        rule: TXTChapterRule
    ) throws -> TXTImportResult {
        var chapters: [TXTChapter] = []
        var notes: [String] = []

        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: []) else {
            // 规则写错不该让导入失败：退化为兜底切分并说明
            notes.append("分章规则编译失败（\(rule.id)），已改为按字数切分")
            return TXTImportResult(
                bookName: bookName,
                encoding: .utf8,
                ruleID: "fallback",
                chapters: syntheticChapters(text: text),
                notes: notes
            )
        }

        // 逐行扫描。用 NSString 的逐行枚举，避免把全文按 \n split 成巨大的数组。
        let ns = text as NSString
        var cursor = 0
        var currentTitle: String? = nil
        var currentStart = 0
        var pendingBodyStart: Int? = nil

        while cursor < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lineStart = lineRange.location

            var isTitle = false
            var title = ""
            // 防误判：以句读结尾的行（如正文「第二章的正文内容。」）不当作标题
            let endsWithPunct = trimmed.last.map { "。！？；，…、".contains($0) } == true
            if !trimmed.isEmpty, trimmed.count <= rule.maxTitleLength, !endsWithPunct {
                let full = NSRange(location: 0, length: (trimmed as NSString).length)
                if regex.firstMatch(in: trimmed, options: [], range: full) != nil {
                    isTitle = true
                    title = cleanTitle(trimmed, rule: rule)
                }
            }

            if isTitle {
                // 收尾上一章：正文到本标题行之前
                if let t = currentTitle {
                    let end = lineStart
                    chapters.append(
                        TXTChapter(
                            title: t,
                            start: currentStart,
                            end: max(end, currentStart),
                            isSynthetic: false
                        )
                    )
                } else if lineStart > 0 {
                    // 第一个标题之前的「前言」部分：有内容就单独成章
                    let head = ns.substring(with: NSRange(location: 0, length: lineStart))
                    if !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        chapters.append(
                            TXTChapter(title: "前言", start: 0, end: lineStart, isSynthetic: false)
                        )
                    }
                }
                currentTitle = title
                currentStart = lineStart
                pendingBodyStart = lineRange.location + lineRange.length  // 仅用于判断标题行长度，区间起点仍取标题行
            }

            cursor = lineRange.location + lineRange.length
            if lineRange.length == 0 { break }
        }

        // 最后一章收尾
        if let t = currentTitle {
            chapters.append(
                TXTChapter(
                    title: t,
                    start: currentStart,
                    end: ns.length,
                    isSynthetic: false
                )
            )
        }

        if chapters.isEmpty {
            notes.append(
                "未匹配到章节标题（规则：\(rule.displayName)），已按每 \(fallbackChunkSize) 字切分"
            )
            return TXTImportResult(
                bookName: bookName,
                encoding: .utf8,
                ruleID: rule.id,
                chapters: syntheticChapters(text: text),
                notes: notes
            )
        }

        // 修补：某章 end < start（空章）→ 丢弃；保证区间连续单调
        var normalized: [TXTChapter] = []
        for ch in chapters where ch.end > ch.start {
            if let last = normalized.last, ch.start > last.end {
                // 中间有未归属的文本（极少见，例如标题行被跳过）→ 并入上一章
                normalized[normalized.count - 1].end = ch.start
            }
            normalized.append(ch)
        }
        // 最后一章必须覆盖到全文末尾
        if var last = normalized.last {
            if last.end < ns.length {
                last.end = ns.length
                normalized[normalized.count - 1] = last
            }
        }
        if normalized.isEmpty {
            notes.append("章节区间解析为空，已按字数切分")
            return TXTImportResult(
                bookName: bookName,
                encoding: .utf8,
                ruleID: rule.id,
                chapters: syntheticChapters(text: text),
                notes: notes
            )
        }

        return TXTImportResult(
            bookName: bookName,
            encoding: .utf8,
            ruleID: rule.id,
            chapters: normalized,
            notes: notes
        )
    }

    /// 兜底：按每 `fallbackChunkSize` 字符切分。标题写成「第 N 节（自动切分）」，
    /// 让用户在目录里一眼看出这不是原文的章节标题。
    public static func syntheticChapters(text: String) -> [TXTChapter] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var out: [TXTChapter] = []
        var start = 0
        var index = 1
        while start < ns.length {
            let end = min(start + fallbackChunkSize, ns.length)
            out.append(
                TXTChapter(
                    title: "第 \(index) 节（按字数自动切分）",
                    start: start,
                    end: end,
                    isSynthetic: true
                )
            )
            start = end
            index += 1
        }
        return out
    }

    /// 标题清洗：去掉规则声明的杂物（如行首「正文」），并压缩空白。
    static func cleanTitle(_ raw: String, rule: TXTChapterRule) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in rule.titleCleanup {
            if t.hasPrefix(token) { t = String(t.dropFirst(token.count)) }
            if t.hasSuffix(token) { t = String(t.dropLast(token.count)) }
        }
        t = t.replacingOccurrences(of: "\u{3000}", with: " ")
        t = t.replacingOccurrences(of: "  ", with: " ")
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// 取某章正文（含标题行）。阅读器渲染与测试都用它。
    public static func body(of chapter: TXTChapter, in text: String) -> String {
        let ns = text as NSString
        let start = max(0, min(chapter.start, ns.length))
        let end = max(start, min(chapter.end, ns.length))
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}
