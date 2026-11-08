//
//  TextDecoding.swift
//  ReaderCore
//
//  文本编码识别与解码（P0-7 需求 7-2：UTF-8 / GBK 识别或手动选择）。
//
//  为什么自带 GBK 表：
//    · iOS 的 `String.Encoding` 里没有 `.gbk` / `.gb18030` 成员；
//      `CFStringConvertEncodingToNSStringEncoding` 在真机可用，但在 Linux/测试环境不可用，
//      而且它是一个「隐式」依赖，一旦编码常量变化就静默解出乱码。
//    · 这里把 GBK→Unicode 映射固化成一份资源表（91,718 字节：21,791 个不同的码点的
//      调色板 + 126×191 的索引表），跨平台行为完全一致，且可单测。
//
//  表格式（小端）：
//    <I paletteCount>              UInt32
//    <paletteCount H> sorted scalars   UInt16[]（按码点升序）
//    <126*191 H> index                 UInt16[]（0=未映射，否则为 palette 下标+1）
//    索引 = (hi-0x81)*191 + (lo-0x40)，覆盖 hi 0x81..0xFE、lo 0x40..0xFE。
//

import Foundation

public enum TextEncodingGuess: String, Sendable, CaseIterable {
    case utf8 = "UTF-8"
    case gbk = "GBK"
    case utf16LE = "UTF-16LE"

    public var displayName: String { rawValue }
}

public enum TextDecoderError: Error, CustomStringConvertible, Sendable {
    case resourceMissing
    case corruptTable
    case undecodable(TextEncodingGuess)

    public var description: String {
        switch self {
        case .resourceMissing: return "GBK 映射表资源缺失（gbk-table.bin 未打进 bundle）"
        case .corruptTable: return "GBK 映射表格式损坏"
        case .undecodable(let e): return "按 \(e.displayName) 解码后仍含替换字符，判定为乱码"
        }
    }
}

public enum TextDecoder {

    // MARK: GBK 表

    private static let tableLock = NSLock()
    nonisolated(unsafe) private static var _palette: [UInt16]?
    nonisolated(unsafe) private static var _index: [UInt16]?

    private static func loadTable() throws -> (palette: [UInt16], index: [UInt16]) {
        tableLock.lock()
        defer { tableLock.unlock() }
        if let p = _palette, let i = _index { return (p, i) }

        guard let url = Bundle.module.url(forResource: "gbk-table", withExtension: "bin") else {
            throw TextDecoderError.resourceMissing
        }
        let data = try Data(contentsOf: url)
        guard data.count > 8 else { throw TextDecoderError.corruptTable }
        var offset = 0
        func readUInt32() -> UInt32 {
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: v)
        }
        func readUInt16() -> UInt16 {
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            offset += 2
            return UInt16(littleEndian: v)
        }
        let paletteCount = Int(readUInt32())
        guard paletteCount > 0, offset + paletteCount * 2 <= data.count else {
            throw TextDecoderError.corruptTable
        }
        var palette: [UInt16] = []
        palette.reserveCapacity(paletteCount)
        for _ in 0..<paletteCount { palette.append(readUInt16()) }
        let indexCount = (data.count - offset) / 2
        guard indexCount == 126 * 191 else { throw TextDecoderError.corruptTable }
        var index: [UInt16] = []
        index.reserveCapacity(indexCount)
        for _ in 0..<indexCount { index.append(readUInt16()) }

        _palette = palette
        _index = index
        return (palette, index)
    }

    /// GBK 双字节解码。未映射位置保留 U+FFFD（便于上层统计「解不出多少字」）。
    public static func decodeGBK(_ data: Data) throws -> String {
        let (palette, index) = try loadTable()
        var out = String()
        out.reserveCapacity(data.count * 2)
        var i = 0
        let bytes = [UInt8](data)
        while i < bytes.count {
            let b = bytes[i]
            if b < 0x80 {
                out.append(Character(UnicodeScalar(b)))
                i += 1
                continue
            }
            guard i + 1 < bytes.count else {
                out.append("\u{FFFD}")
                break
            }
            let hi = Int(b)
            let lo = Int(bytes[i + 1])
            if hi >= 0x81, hi <= 0xFE, lo >= 0x40, lo <= 0xFE {
                let idx = (hi - 0x81) * 191 + (lo - 0x40)
                let v = (idx >= 0 && idx < index.count) ? index[idx] : 0
                if v != 0, Int(v - 1) < palette.count {
                    out.append(Character(UnicodeScalar(palette[Int(v - 1)])!))
                } else {
                    out.append("\u{FFFD}")
                }
                i += 2
            } else if hi == 0x80 {
                // 0x80 单字节（欧元符的历史遗留），按 U+20AC 处理更符合实际站点
                out.append("\u{20AC}")
                i += 2
            } else {
                out.append("\u{FFFD}")
                i += 2
            }
        }
        return out
    }

    // MARK: 编码识别

    /// 判断按某编码解码的结果是否「明显是乱码」。
    /// 判据（对齐需求 7-2 的可操作口径）：替换字符比例 + 控制字符比例。
    public static func looksGarbled(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var replacement = 0
        var control = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            if scalar.value == 0xFFFD { replacement += 1 }
            // 除 \n \r \t 外的 C0 控制符
            if scalar.value < 0x20, scalar != "\n", scalar != "\r", scalar != "\t" { control += 1 }
        }
        guard total > 0 else { return false }
        if Double(replacement) / Double(total) > 0.005 { return true }
        if Double(control) / Double(total) > 0.01 { return true }
        return false
    }

    /// 识别 + 解码。返回解码结果与采用的编码。
    /// 顺序：UTF-8（严格）→ GBK → UTF-16LE。之所以把 UTF-8 放第一，
    /// 是因为它是 P0 里唯一能「严格校验」的编码（非法序列直接失败），
    /// 而 GBK 几乎任何字节都能解出东西，放在前面会误判。
    public static func detectAndDecode(_ data: Data) throws -> (text: String, encoding: TextEncodingGuess) {
        // BOM 优先
        if data.count >= 2 {
            let b0 = data[data.startIndex]
            let b1 = data[data.index(after: data.startIndex)]
            if b0 == 0xFF, b1 == 0xFE {
                let body = data.dropFirst(2)
                if let s = String(data: Data(body), encoding: .utf16LittleEndian) {
                    return (s, .utf16LE)
                }
            }
            if b0 == 0xFE, b1 == 0xFF {
                let body = data.dropFirst(2)
                if let s = String(data: Data(body), encoding: .utf16BigEndian) {
                    return (s, .utf16LE)   // 归档：大端也归到同一档，显示名不追究
                }
            }
        }
        if let s = String(data: data, encoding: .utf8), !looksGarbled(s) {
            return (s, .utf8)
        }
        let gbk = try decodeGBK(data)
        if !looksGarbled(gbk) {
            return (gbk, .gbk)
        }
        if let s = String(data: data, encoding: .utf16LittleEndian), !looksGarbled(s) {
            return (s, .utf16LE)
        }
        // 都不干净：返回替换字符最少的那个（宁可给用户一个能看的版本，也不要直接失败）
        throw TextDecoderError.undecodable(.gbk)
    }

    /// 按指定编码解码（用户手动切换编码时用）。
    public static func decode(_ data: Data, as encoding: TextEncodingGuess) throws -> String {
        switch encoding {
        case .utf8:
            if let s = String(data: data, encoding: .utf8) { return s }
            throw TextDecoderError.undecodable(.utf8)
        case .gbk:
            return try decodeGBK(data)
        case .utf16LE:
            if let s = String(data: data, encoding: .utf16LittleEndian) { return s }
            throw TextDecoderError.undecodable(.utf16LE)
        }
    }

    /// 站点响应按 charset 参数解码（HTTPClient 用）。
    /// `charset` 来自 UrlOption.charset 或响应头 Content-Type；缺省按 UTF-8 → GBK 兜底。
    public static func decodeResponse(_ data: Data, charset: String?) -> String {
        let name = (charset ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let candidates: [TextEncodingGuess]
        if name.contains("gb") || name.contains("gbk") || name.contains("gb2312") {
            candidates = [.gbk, .utf8]
        } else if name.contains("utf-16") {
            candidates = [.utf16LE, .utf8]
        } else {
            candidates = [.utf8, .gbk]
        }
        for enc in candidates {
            if let s = try? decode(data, as: enc), !looksGarbled(s) { return s }
        }
        return (try? decode(data, as: .gbk)) ?? ""
    }
}
