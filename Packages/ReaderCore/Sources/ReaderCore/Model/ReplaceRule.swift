//
//  ReplaceRule.swift
//  ReaderCore
//
//  用户替换净化规则（架构文档二·八：13 字段全部落库）。
//
//  字段语义（对齐架构文档，语义解释见《实现说明》）：
//    · id / name / group        — 标识与分组（“默认规则组”也用 group 标记）
//    · pattern / replacement    — 匹配与替换
//    · isRegex                  — pattern 是正则还是字面量
//    · scope                    — 书名匹配（正则；多个用逗号分隔，任一命中即生效；空 = 全部书）
//    · scopeTitle / scopeContent— 是否作用于章节标题 / 正文（两者至少一个，默认只正文）
//    · excludeScope             — 排除书名（正则；多个逗号分隔；命中则本规则跳过）
//    · timeoutMillisecond       — 单条规则独立超时（默认 3000ms；正则路径按剩余时间熔断）
//    · sortOrder / enable       — 排序与启用开关
//
//  excludeScope 是验收红线：漏掉会让全局替换误伤被排除的书。
//

import Foundation

public struct ReplaceRule: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var group: String
    public var pattern: String
    public var replacement: String
    public var isRegex: Bool
    /// 书名匹配（正则，逗号分隔多项；空 = 适用于全部书）
    public var scope: String
    public var scopeTitle: Bool
    public var scopeContent: Bool
    /// 排除书名（正则，逗号分隔多项；命中任一即跳过本规则）
    public var excludeScope: String
    public var timeoutMillisecond: Int
    public var sortOrder: Int
    public var enable: Bool

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        group: String = "",
        pattern: String = "",
        replacement: String = "",
        isRegex: Bool = true,
        scope: String = "",
        scopeTitle: Bool = false,
        scopeContent: Bool = true,
        excludeScope: String = "",
        timeoutMillisecond: Int = 3000,
        sortOrder: Int = 0,
        enable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.pattern = pattern
        self.replacement = replacement
        self.isRegex = isRegex
        self.scope = scope
        self.scopeTitle = scopeTitle
        self.scopeContent = scopeContent
        self.excludeScope = excludeScope
        self.timeoutMillisecond = timeoutMillisecond
        self.sortOrder = sortOrder
        self.enable = enable
    }

    // MARK: - 编解码（宽容：未知字段忽略，缺失字段取默认）

    private enum CodingKeys: String, CodingKey {
        case id, name, group, pattern, replacement, isRegex, scope
        case scopeTitle, scopeContent, excludeScope
        case timeoutMillisecond, sortOrder, enable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? true
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        scopeTitle = try c.decodeIfPresent(Bool.self, forKey: .scopeTitle) ?? false
        scopeContent = try c.decodeIfPresent(Bool.self, forKey: .scopeContent) ?? true
        excludeScope = try c.decodeIfPresent(String.self, forKey: .excludeScope) ?? ""
        timeoutMillisecond = try c.decodeIfPresent(Int.self, forKey: .timeoutMillisecond) ?? 3000
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable) ?? true
    }
}

// MARK: - scope 匹配

public enum ReplaceRuleScope {
    /// scope 是否对该书名生效（空 scope = 全部书生效）。
    /// scope 为正则、逗号分隔多项，任一命中即生效；全部编译失败时按字面量包含匹配。
    public static func scopeMatches(_ scope: String, bookName: String) -> Bool {
        let s = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return true }
        return anyPatternMatches(s, text: bookName)
    }

    /// excludeScope 是否命中（命中 = 该规则跳过这本书）。
    public static func excludeMatches(_ excludeScope: String, bookName: String) -> Bool {
        let s = excludeScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        return anyPatternMatches(s, text: bookName)
    }

    private static func anyPatternMatches(_ scopeList: String, text: String) -> Bool {
        for part in scopeList.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                let ns = text as NSString
                if re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                    return true
                }
            } else if text.contains(p) {
                // 非法正则退化为字面量包含（与 RegexUtil 的兜底口径一致）
                return true
            }
        }
        return false
    }
}

// MARK: - 规则应用（带独立超时熔断）

public enum ReplaceRuleOutcome: Sendable, Equatable {
    case applied
    /// 未命中（规则正常执行，模式没匹配上）
    case noMatch
    /// 该规则超时被熔断（其余规则照常）
    case timedOut
    /// 该规则 pattern 为空
    case skipped
}

public enum ReplaceRuleEngine {

    /// 应用一条规则到文本。
    ///
    /// - 正则路径：**逐行应用**（对齐架构文档二·八的 mapped 路径——净化规则的
    ///   匹配对象是行级段落），每处理一批行检查一次剩余时间，超时立即熔断：
    ///   已处理行保留、剩余行保持原文，返回 `.timedOut`，其余规则照常执行。
    ///   单行内的灾难回溯无法从外部中断（ICU 引擎限制），逐行把每次匹配的
    ///   输入规模限制在单行内，实际站点正文的行长度下这是有界风险。
    /// - 字面量路径：直接全量替换（无回溯风险，不设熔断）。
    public static func apply(
        _ rule: ReplaceRule,
        to text: String,
        deadline: Date? = nil
    ) -> (text: String, outcome: ReplaceRuleOutcome) {
        let pattern = rule.pattern
        guard !pattern.isEmpty else { return (text, .skipped) }

        if !rule.isRegex {
            guard text.contains(pattern) else { return (text, .noMatch) }
            return (text.replacingOccurrences(of: pattern, with: rule.replacement), .applied)
        }

        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
            // 正则非法：退化为字面量替换，避免规则静默失效
            guard text.contains(pattern) else { return (text, .noMatch) }
            return (text.replacingOccurrences(of: pattern, with: rule.replacement), .applied)
        }

        let hardDeadline = deadline
            ?? Date().addingTimeInterval(TimeInterval(max(1, rule.timeoutMillisecond)) / 1000.0)

        var lines = text.components(separatedBy: "\n")
        var anyMatch = false
        let checkEvery = 16
        for i in 0..<lines.count {
            if i % checkEvery == 0, i > 0, Date() > hardDeadline {
                // 熔断：保留已处理行，剩余行保持原文
                return (lines.joined(separator: "\n"), .timedOut)
            }
            let line = lines[i]
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            let count = re.numberOfMatches(in: line, options: [], range: full)
            guard count > 0 else { continue }
            anyMatch = true
            lines[i] = re.stringByReplacingMatches(
                in: line, options: [], range: full, withTemplate: rule.replacement
            )
        }
        return (lines.joined(separator: "\n"), anyMatch ? .applied : .noMatch)
    }
}
