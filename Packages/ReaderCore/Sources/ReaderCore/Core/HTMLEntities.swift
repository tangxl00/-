//
//  HTMLEntities.swift
//  ReaderCore
//
//  HTML 实体反转义。legado 的后处理里有一句「HTML 实体反转义（仅当结果含 &）」，
//  这里独立实现，用于正文与字段取值两条路径共用。
//
//  覆盖：命名实体常用集 + 十进制 &#123; + 十六进制 &#x1F600;。
//  不覆盖全部 2000+ HTML5 命名实体（书源里实际出现的基本都在下面的表里），
//  未命中的一律原样保留（宁可留 &foo; 也不要吞字符）。
//

import Foundation

public enum HTMLEntities {
    /// 常用命名实体表（含 &nbsp; 这类高频项）。
    static let named: [String: String] = [
        "quot": "\"", "apos": "'", "amp": "&", "lt": "<", "gt": ">",
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "shy": "\u{00AD}", "ndash": "\u{2013}", "mdash": "\u{2014}",
        "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "sbquo": "\u{201A}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "bdquo": "\u{201E}", "dagger": "\u{2020}", "Dagger": "\u{2021}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "times": "\u{00D7}",
        "divide": "\u{00F7}", "plusmn": "\u{00B1}", "minus": "\u{2212}",
        "deg": "\u{00B0}", "permil": "\u{2030}", "prime": "\u{2032}",
        "Prime": "\u{2033}", "larr": "\u{2190}", "rarr": "\u{2192}",
        "uarr": "\u{2191}", "darr": "\u{2193}", "harr": "\u{2194}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "cent": "\u{00A2}", "pound": "\u{00A3}", "yen": "\u{00A5}",
        "euro": "\u{20AC}", "curren": "\u{00A4}", "sect": "\u{00A7}",
        "para": "\u{00B6}", "frac12": "\u{00BD}", "frac14": "\u{00BC}",
        "frac34": "\u{00BE}", "sup1": "\u{00B9}", "sup2": "\u{00B2}",
        "sup3": "\u{00B3}", "micro": "\u{00B5}", "ordf": "\u{00AA}",
        "ordm": "\u{00BA}", "not": "\u{00AC}", "aelig": "\u{00E6}",
        "AElig": "\u{00C6}", "oslash": "\u{00F8}", "Oslash": "\u{00D8}",
        "szlig": "\u{00DF}", "agrave": "\u{00E0}", "aacute": "\u{00E1}",
        "acirc": "\u{00E2}", "atilde": "\u{00E3}", "auml": "\u{00E4}",
        "aring": "\u{00E5}", "ccedil": "\u{00E7}", "egrave": "\u{00E8}",
        "eacute": "\u{00E9}", "ecirc": "\u{00EA}", "euml": "\u{00EB}",
        "igrave": "\u{00EC}", "iacute": "\u{00ED}", "icirc": "\u{00EE}",
        "iuml": "\u{00EF}", "ntilde": "\u{00F1}", "ograve": "\u{00F2}",
        "oacute": "\u{00F3}", "ocirc": "\u{00F4}", "otilde": "\u{00F5}",
        "ouml": "\u{00F6}", "ugrave": "\u{00F9}", "uacute": "\u{00FA}",
        "ucirc": "\u{00FB}", "uuml": "\u{00FC}", "yacute": "\u{00FD}",
        "yuml": "\u{00FF}", "Alpha": "\u{0391}", "Beta": "\u{0392}",
        "Gamma": "\u{0393}", "Delta": "\u{0394}", "Omega": "\u{03A9}",
        "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}",
        "delta": "\u{03B4}", "omega": "\u{03C9}", "pi": "\u{03C0}",
        "sigma": "\u{03C3}", "lambda": "\u{03BB}", "mu": "\u{03BC}",
    ]

    /// 反转义。`onlyIfNeeded` 为真且文本不含 `&` 时直接返回（对应 legado 的「仅当含 &」）。
    public static func decode(_ text: String, onlyIfNeeded: Bool = true) -> String {
        if onlyIfNeeded && !text.contains("&") { return text }
        guard text.contains("&") else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex

        while i < text.endIndex {
            guard text[i] == "&" else {
                out.append(text[i])
                i = text.index(after: i)
                continue
            }
            // 找分号，限制长度避免把正常文本里的 & 当实体扫描太远
            var j = text.index(after: i)
            var body = ""
            var found = false
            while j < text.endIndex, body.count < 32 {
                let c = text[j]
                if c == ";" { found = true; break }
                if c == "&" || c == " " || c == "<" { break }
                body.append(c)
                j = text.index(after: j)
            }
            guard found else {
                out.append("&")
                i = text.index(after: i)
                continue
            }

            if let decoded = decodeEntityBody(body) {
                out.append(decoded)
                i = text.index(after: j)
            } else {
                // 未识别的实体原样保留（含 & 和分号）
                out.append(String(text[i...j]))
                i = text.index(after: j)
            }
        }
        return out
    }

    private static func decodeEntityBody(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let num = String(body.dropFirst())
            if num.hasPrefix("x") || num.hasPrefix("X") {
                let hex = String(num.dropFirst())
                guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else { return nil }
                return String(Character(scalar))
            }
            guard let v = UInt32(num, radix: 10), let scalar = Unicode.Scalar(v) else { return nil }
            return String(Character(scalar))
        }
        return named[body]
    }
}
