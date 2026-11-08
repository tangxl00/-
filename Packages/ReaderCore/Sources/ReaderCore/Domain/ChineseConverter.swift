//
//  ChineseConverter.swift
//  ReaderCore
//
//  简繁转换（架构文档二·八流水线第 3 步；java.t2s / java.s2t 扩展共用同一实现）。
//
//  单字级映射（表见 ChineseConversionTable.swift，Unihan 数据独立生成，无 legado 代码）。
//  非映射字符原样保留。用户设置默认关闭（架构文档口径：按用户设置，默认关闭）。
//

import Foundation

public enum ChineseConverter {
    /// 繁体 -> 简体（t2s）
    public static func toSimplified(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            out.append(ChineseConversionTable.simplifiedOf[ch] ?? ch)
        }
        return out
    }

    /// 简体 -> 繁体（s2t）
    public static func toTraditional(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            out.append(ChineseConversionTable.traditionalOf[ch] ?? ch)
        }
        return out
    }
}
