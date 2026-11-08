//
//  Pagination.swift
//  ReaderCore
//
//  分页接口（架构文档要求：P0 用滚动阅读，但必须为 P1 的覆盖/仿真翻页预留
//  「字符区间数组 [PageRange]」）。
//
//  分层：
//    · `PageRange` / `PaginationResult` —— 纯值类型，P0/P1 通用。
//    · `TextMeasuring` —— 一个「把文本切成行、并给出每行高度」的抽象。
//      iOS 侧由 CoreText 实现（`CoreTextMeasurer`，在 App 层）；
//      这里用一个「等宽近似」实现，让 Linux 上能跑分页算法测试。
//    · `Paginator` —— 纯算法：行 → 页（按可视高度装箱）。可测。
//
//  ★ 为什么不把 CoreText 直接写在这里：CoreText 只在 Apple 平台可用，
//  写进来会让整个 ReaderCore 无法在 Linux 上编译/测试。
//  把「度量」抽象成协议，正好也符合「为 P1 预留」的要求。
//

import Foundation

// MARK: - 页区间

/// 一页在「章内字符坐标」里的区间 [start, end)。
public struct PageRange: Sendable, Equatable, Codable {
    public var start: Int
    public var end: Int
    public var pageIndex: Int

    public init(start: Int, end: Int, pageIndex: Int) {
        self.start = start
        self.end = end
        self.pageIndex = pageIndex
    }

    public var length: Int { max(0, end - start) }
}

/// 分页结果。
public struct PaginationResult: Sendable, Equatable {
    public var pages: [PageRange]
    /// 排版签名（字号/行距/边距/视口变化都会变），用于缓存
    public var signature: String
    /// 总行数（调试用）
    public var lineCount: Int
    /// 全文长度，便于校验页区间覆盖完整性
    public var textLength: Int

    public init(pages: [PageRange], signature: String, lineCount: Int, textLength: Int) {
        self.pages = pages
        self.signature = signature
        self.lineCount = lineCount
        self.textLength = textLength
    }

    /// 校验：页区间是否「无缝、无重叠、覆盖全文」。
    /// P1 翻页必须靠这个性质，否则会出现漏字/重字。
    public var isContiguous: Bool {
        guard !pages.isEmpty else { return textLength == 0 }
        if pages[0].start != 0 { return false }
        for i in 1..<pages.count where pages[i].start != pages[i - 1].end {
            return false
        }
        return pages.last?.end == textLength
    }

    /// 给定字符偏移，落在第几页（P0 滚动→P1 翻页切换、以及「跳转到进度」都用它）
    public func pageIndex(forCharacterOffset offset: Int) -> Int? {
        guard !pages.isEmpty else { return nil }
        let o = max(0, offset)
        // 二分：pages 按 start 升序
        var lo = 0, hi = pages.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if o < pages[mid].start { hi = mid - 1 }
            else if o >= pages[mid].end { lo = mid + 1 }
            else { return mid }
        }
        return pages.count - 1
    }
}

// MARK: - 一行

/// 一行文本：章内字符区间 + 渲染高度（pt）。
public struct TextLine: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var height: Double

    public init(start: Int, end: Int, height: Double) {
        self.start = start
        self.end = end
        self.height = height
    }
}

// MARK: - 度量抽象

/// 文本度量：把一段文本按给定宽度切成行。
/// iOS 实现基于 `CTTypesetter`；测试实现基于「字符宽度近似」。
public protocol TextMeasuring: Sendable {
    /// 把字符串切成行，返回每行的字符区间与高度。
    /// - Parameters:
    ///   - text: 待排版文本（阅读器传入的是「章节纯文本 + 段间换行」）
    ///   - width: 可用宽度（pt）
    ///   - lineHeight: 单行高度（pt）
    func lines(in text: String, width: Double, lineHeight: Double) -> [TextLine]
}

/// 可用于 Linux 测试的近似度量：中文字符按 1 个「字宽」，ASCII 按 0.5 个「字宽」。
/// 字宽 = lineHeight（近似实际排版里 1em ≈ 行高）。
/// 这**不追求像素精度**，只用于验证分页算法的性质（连续、覆盖、按高度装箱）。
public struct ApproximateMeasurer: TextMeasuring {
    /// 每个字符的宽度系数
    public var cjkWidthFactor: Double
    public var asciiWidthFactor: Double

    public init(cjkWidthFactor: Double = 1.0, asciiWidthFactor: Double = 0.5) {
        self.cjkWidthFactor = cjkWidthFactor
        self.asciiWidthFactor = asciiWidthFactor
    }

    public func lines(in text: String, width: Double, lineHeight: Double) -> [TextLine] {
        guard !text.isEmpty else { return [] }
        var out: [TextLine] = []
        var lineStart = 0
        var used = 0.0
        var idx = 0

        for ch in text {
            if ch == "\n" {
                // 硬换行：闭合当前行（换行符算入上一行的区间）
                out.append(TextLine(start: lineStart, end: idx + 1, height: lineHeight))
                lineStart = idx + 1
                used = 0
                idx += 1
                continue
            }
            let w = (ch.unicodeScalars.first.map { $0.value < 128 } == true)
                ? asciiWidthFactor * lineHeight
                : cjkWidthFactor * lineHeight
            if used > 0, used + w > width {
                // 折行：不吞字符
                out.append(TextLine(start: lineStart, end: idx, height: lineHeight))
                lineStart = idx
                used = 0
            }
            used += w
            idx += 1
        }
        if lineStart < idx {
            out.append(TextLine(start: lineStart, end: idx, height: lineHeight))
        }
        return out
    }
}

// MARK: - 分页器

public enum Paginator {
    /// 把 行 装箱成 页。
    /// - Parameters:
    ///   - lines: 度量结果
    ///   - pageHeight: 单页可用高度（pt）
    ///   - textLength: 全文长度（用于完整性校验）
    ///   - signature: 排版签名
    /// - Note: 若单行高度 > pageHeight（异常：字号极大 + 视口极小），
    ///   仍保证每页至少一行，避免死循环。
    public static func paginate(
        lines: [TextLine],
        pageHeight: Double,
        textLength: Int,
        signature: String
    ) -> PaginationResult {
        guard !lines.isEmpty else {
            return PaginationResult(pages: [], signature: signature, lineCount: 0, textLength: textLength)
        }
        var pages: [PageRange] = []
        var pageStart = lines[0].start
        var acc = 0.0
        var count = 0

        for line in lines {
            let h = max(0.1, line.height)
            if count > 0, acc + h > pageHeight + 0.5 {
                pages.append(
                    PageRange(start: pageStart, end: line.start, pageIndex: pages.count)
                )
                pageStart = line.start
                acc = 0
                count = 0
            }
            acc += h
            count += 1
        }
        // 最后一页
        if count > 0 {
            pages.append(PageRange(start: pageStart, end: textLength, pageIndex: pages.count))
        }
        // 修尾：确保最后一页 end == textLength
        if var last = pages.last, last.end != textLength {
            last.end = textLength
            pages[pages.count - 1] = last
        }
        return PaginationResult(
            pages: pages,
            signature: signature,
            lineCount: lines.count,
            textLength: textLength
        )
    }

    /// 便捷：直接度量 + 装箱。
    public static func paginate(
        text: String,
        width: Double,
        pageHeight: Double,
        lineHeight: Double,
        signature: String,
        measurer: TextMeasuring
    ) -> PaginationResult {
        let lines = measurer.lines(in: text, width: width, lineHeight: lineHeight)
        return paginate(
            lines: lines,
            pageHeight: pageHeight,
            textLength: text.count,
            signature: signature
        )
    }
}
