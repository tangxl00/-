//
//  CoreTextMeasurer.swift
//  TingDu
//
//  iOS 端真实文本度量：实现 ReaderCore 的 TextMeasuring 协议。
//  基于 CTTypesetter 逐段排版；分页（Paginator）与渲染（CoreTextPageView）
//  共用同一份行数据，保证「看到的行 == 分页算出的行」。
//  iOS 专属层，未编译（沙箱无 Xcode / 无 CoreText）。
//

import Foundation
import CoreText
import UIKit
import ReaderCore

/// 一条待渲染的行：渲染视图需要的全部信息。
struct RenderLine {
    /// 该行文本（String.CharacterView 子串已转 String）
    var text: String
    /// 在章节布局文本中的起始偏移
    var start: Int
    /// 该行顶部 y 坐标（相对页面顶部，pt）
    var top: Double
    /// 行高（pt）
    var height: Double
    /// 是否段落首行（需要首行缩进时由 ViewModel 决定，渲染端只画）
    var isParagraphStart: Bool
}

struct CoreTextMeasurer: TextMeasuring {
    var settings: ReadingSettings

    /// 基准行高 = 字号 × 行距倍数
    private var baseLineHeight: Double { settings.fontSize * settings.lineSpacing }

    func lines(in text: String, width: Double, lineHeight: Double) -> [TextLine] {
        // 协议的 lineHeight 参数即 baseLineHeight；这里以内部 settings 为准计算
        // 段落间距（段间空白），使分页高度与渲染高度一致。
        //
        // P1-16（v1.2.0）修复：旧实现把 paraExtra 加到「段内除首行外的每一行」
        // （afterParagraphBreak 在段首行之后即 false），表现为行距被二次放大、
        // 段间距反而为零，与「段距」语义正好相反。现在 paraExtra 只加在
        // 段间——即除首个段落外，每段首行的行高里。
        let paraExtra = settings.paragraphSpacing
        var out: [TextLine] = []
        let chars = Array(text)
        let n = chars.count
        var idx = 0
        var isFirstParagraph = true

        while idx < n {
            // 找到段落末尾（\n 或文本结束）
            var paraEnd = idx
            while paraEnd < n, chars[paraEnd] != "\n" { paraEnd += 1 }

            let paragraph = String(chars[idx..<paraEnd])
            // 段间额外空白：首个段落不加；空行本身即视觉分隔，也不加
            let leadExtra = (isFirstParagraph || paragraph.isEmpty) ? 0 : paraExtra
            if paragraph.isEmpty {
                // 空行（连续 \n）：按一行高度计（与 ApproximateMeasurer 的硬换行语义一致）
                out.append(TextLine(start: idx, end: min(paraEnd + 1, n), height: baseLineHeight))
                idx = paraEnd + 1
                isFirstParagraph = false
                continue
            }

            // CTTypesetter 逐行切
            let attrString = NSAttributedString(string: paragraph, attributes: [
                .font: Self.font(for: settings)
            ])
            // v1.2.1：CTTypesetterCreateWithAttributedString 在 Apple 平台返回非 Optional
            //（iOS/macOS 均是），`guard let` 属条件绑定非 Optional 编译错，改直接绑定。
            let typesetter = CTTypesetterCreateWithAttributedString(attrString)
            var lineStartOffset = 0   // 段内偏移（UTF-16）
            let utf16Len = paragraph.utf16.count
            // 段内 Character 边界的 UTF-16 偏移集合（极窄宽度降级断行用，避免拆代理对）
            var boundaries: Set<Int> = [0, utf16Len]
            var acc = 0
            for ch in paragraph {
                acc += ch.utf16.count
                boundaries.insert(acc)
            }
            var isParagraphFirstLine = true
            while lineStartOffset < utf16Len {
                var count = CTTypesetterSuggestLineBreak(typesetter, lineStartOffset, Double(width))
                if count <= 0 {
                    // P1-16 附带修复：极窄宽度下 SuggestLineBreak 可能返回 0，旧代码
                    // break 会丢弃该段剩余文本。降级为前进到下一个 Character 边界
                    //（至少 1 个 UTF-16 单位），保证不丢字且必然前进。
                    let next = boundaries.first { $0 > lineStartOffset } ?? utf16Len
                    count = next - lineStartOffset
                    if count <= 0 { break }
                }
                // 段内 UTF-16 偏移 → 全局 Character 偏移
                let globalStart = idx + Self.characterIndex(utf16Offset: lineStartOffset, in: chars, base: idx, paragraph: paragraph)
                let lineEnd16 = lineStartOffset + count
                let globalEnd = lineEnd16 >= utf16Len ? paraEnd : idx + Self.characterIndex(utf16Offset: lineEnd16, in: chars, base: idx, paragraph: paragraph)
                let h = baseLineHeight + (isParagraphFirstLine ? leadExtra : 0)
                out.append(TextLine(start: globalStart, end: globalEnd, height: h))
                isParagraphFirstLine = false
                lineStartOffset = lineEnd16
            }
            idx = paraEnd + 1
            isFirstParagraph = false
        }
        return out
    }

    /// 把渲染行组装出来（渲染视图用）。lines 为度量结果中落在当前页的行。
    static func renderLines(for page: PageRange, in text: String, measured: [TextLine], settings: ReadingSettings) -> [RenderLine] {
        let chars = Array(text)
        var result: [RenderLine] = []
        var y = 0.0
        let base = settings.fontSize * settings.lineSpacing
        var prevEnd: Int? = nil
        for line in measured where line.start >= page.start && line.start < page.end {
            let end = min(line.end, page.end)
            guard end > line.start else { continue }
            let isParaStart = prevEnd == nil || (prevEnd! > 0 && chars[prevEnd! - 1] == "\n")
            result.append(RenderLine(
                text: String(chars[line.start..<end]),
                start: line.start,
                top: y,
                height: line.height,
                isParagraphStart: isParaStart
            ))
            y += line.height
            prevEnd = end
        }
        _ = base
        return result
    }

    static func font(for settings: ReadingSettings) -> UIFont {
        let size = CGFloat(settings.fontSize)
        switch settings.font {
        case .system:
            return UIFont.systemFont(ofSize: size)
        case .serif:
            for name in settings.font.iOSExtraCandidates + ["Songti SC", "STSong"] {
                if let f = UIFont(name: name, size: size) { return f }
            }
            return UIFont.systemFont(ofSize: size)
        case .sans:
            return UIFont.systemFont(ofSize: size, weight: .regular)
        case .rounded:
            if #available(iOS 17.0, *) {
                return UIFont.systemFont(ofSize: size, weight: .regular)
            }
            return UIFont.systemFont(ofSize: size)
        }
    }

    /// UTF-16 偏移 → Character 偏移（同一段内）
    private static func characterIndex(utf16Offset: Int, in chars: [Character], base: Int, paragraph: String) -> Int {
        // 大多数段落是 BMP 内文本；逐字符累计 UTF-16 长度即可
        var acc = 0
        var i = 0
        for ch in paragraph {
            if acc >= utf16Offset { break }
            acc += ch.utf16.count
            i += 1
        }
        return i
    }
}
