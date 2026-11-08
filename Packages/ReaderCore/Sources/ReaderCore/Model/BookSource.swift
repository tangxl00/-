//
//  BookSource.swift
//  ReaderCore
//
//  书源根对象的镜像：33 个顶层字段，字段名与 legado 一致（bookSourceUrl 而非 sourceURL），
//  这样导入导出、调试对照、社区书源都能零转换。
//
//  规则子对象在 legado 里是 Gson 序列化到单个 TEXT 列，这里同样存成 Data，
//  不拆关系表——拆表只会增加迁移成本，且与上游结构不一致。
//

import Foundation

public struct BookSource: Codable, Sendable, Identifiable, Equatable {
    // 标识与分组
    public var bookSourceUrl: String
    public var bookSourceName: String
    public var bookSourceGroup: String?
    public var bookSourceType: Int
    public var bookUrlPattern: String?
    public var customOrder: Int
    public var weight: Int
    public var lastUpdateTime: Int64
    public var respondTime: Int

    // 开关
    public var enabled: Bool
    public var enabledExplore: Bool
    public var enabledCookieJar: Bool
    public var eventListener: Bool
    public var customButton: String?

    // 网络
    public var header: String?
    public var concurrentRate: String?
    public var loginUrl: String?
    public var loginUi: String?
    public var loginCheckJs: String?
    public var coverDecodeJs: String?
    public var jsLib: String?

    // 入口
    public var searchUrl: String?
    public var exploreUrl: String?
    public var exploreScreen: String?
    public var homepageModules: String?

    // 五套规则（存 Data，保持与 legado 单列序列化一致）
    public var ruleSearch: Data
    public var ruleExplore: Data
    public var ruleBookInfo: Data
    public var ruleToc: Data
    public var ruleContent: Data
    public var ruleReview: Data?
    /// P1-20（v1.2.0）：规则字段在解码阶段发现的问题（字段名 + 原因）。
    /// 瞬时态：不参与 Codable（CodingKeys 不含它），导入流程在建档时消费。
    public var ruleDecodeIssues: [String] = []
    /// 未被识别的其它字段，用于无损往返（导入导出不丢数据）。
    public var unknownFields: [String: JsonValue]

    // 注释
    public var bookSourceComment: String?
    public var variableComment: String?

    public var id: String { bookSourceUrl }

    public init(bookSourceUrl: String, bookSourceName: String) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
        self.bookSourceType = 0
        self.customOrder = 0
        self.weight = 0
        self.lastUpdateTime = 0
        self.respondTime = 180000
        self.enabled = true
        self.enabledExplore = false
        self.enabledCookieJar = false
        self.eventListener = false
        self.ruleSearch = Data()
        self.ruleExplore = Data()
        self.ruleBookInfo = Data()
        self.ruleToc = Data()
        self.ruleContent = Data()
        self.unknownFields = [:]
    }

    // MARK: 规则解码（惰性解析，避免每次读都 JSON decode）

    public var searchRule: SearchRule { decodeRule(ruleSearch) ?? SearchRule() }
    public var exploreRule: ExploreRule { decodeRule(ruleExplore) ?? ExploreRule() }
    public var bookInfoRule: BookInfoRule { decodeRule(ruleBookInfo) ?? BookInfoRule() }
    public var tocRule: TocRule { decodeRule(ruleToc) ?? TocRule() }
    public var contentRule: ContentRule { decodeRule(ruleContent) ?? ContentRule() }

    private func decodeRule<T: Decodable>(_ data: Data) -> T? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// P1-20（v1.2.0）：五个规则字段的真实类型解码复验。
    /// 旧实现 ruleSearch 解码失败静默退化成空 SearchRule()，叠加导入后表现为
    /// 「导入成功但该源搜不到书」。现在导入流程消费本方法，畸形规则按失败明细上报。
    public func validateRuleDecoding() -> [String] {
        var issues: [String] = []
        func check<T: Decodable>(_ data: Data, _ name: String, _ type: T.Type) {
            guard !data.isEmpty else { return }
            do {
                _ = try JSONDecoder().decode(T.self, from: data)
            } catch {
                issues.append("\(name) 结构无法解析（\(error.localizedDescription)）")
            }
        }
        check(ruleSearch, "ruleSearch", SearchRule.self)
        check(ruleExplore, "ruleExplore", ExploreRule.self)
        check(ruleBookInfo, "ruleBookInfo", BookInfoRule.self)
        check(ruleToc, "ruleToc", TocRule.self)
        check(ruleContent, "ruleContent", ContentRule.self)
        return issues
    }

    // MARK: 便捷判断

    public var isTextSource: Bool { bookSourceType == 0 }

    /// 非文本类型（音频/图片/文件/视频）在 P0 明确不支持。
    public var unsupportedTypeDescription: String? {
        switch bookSourceType {
        case 0: return nil
        case 1: return "音频"
        case 2: return "图片"
        case 3: return "文件"
        case 4: return "视频"
        default: return "未知类型(\(bookSourceType))"
        }
    }
}

// MARK: - 自己实现 init(from:)，兼容 33 字段 + 未知字段保存

extension BookSource {
    enum CodingKeys: String, CodingKey {
        case bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType,
             bookUrlPattern, customOrder, weight, lastUpdateTime, respondTime,
             enabled, enabledExplore, enabledCookieJar, eventListener, customButton,
             header, concurrentRate, loginUrl, loginUi, loginCheckJs, coverDecodeJs, jsLib,
             searchUrl, exploreUrl, exploreScreen, homepageModules,
             ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent, ruleReview,
             bookSourceComment, variableComment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookSourceUrl = try c.decodeFlexibleString(.bookSourceUrl) ?? ""
        bookSourceName = try c.decodeFlexibleString(.bookSourceName) ?? ""
        bookSourceGroup = try c.decodeFlexibleString(.bookSourceGroup)
        bookSourceType = (try? c.decodeFlexibleInt(.bookSourceType)) ?? 0
        bookUrlPattern = try c.decodeFlexibleString(.bookUrlPattern)
        customOrder = (try? c.decodeFlexibleInt(.customOrder)) ?? 0
        weight = (try? c.decodeFlexibleInt(.weight)) ?? 0
        lastUpdateTime = Int64((try? c.decodeFlexibleInt(.lastUpdateTime)) ?? 0)
        respondTime = (try? c.decodeFlexibleInt(.respondTime)) ?? 180000

        enabled = (try? c.decodeFlexibleBool(.enabled)) ?? true
        enabledExplore = (try? c.decodeFlexibleBool(.enabledExplore)) ?? false
        enabledCookieJar = (try? c.decodeFlexibleBool(.enabledCookieJar)) ?? false
        eventListener = (try? c.decodeFlexibleBool(.eventListener)) ?? false
        customButton = try c.decodeFlexibleString(.customButton)

        header = try c.decodeFlexibleString(.header)
        concurrentRate = try c.decodeFlexibleString(.concurrentRate)
        loginUrl = try c.decodeFlexibleString(.loginUrl)
        loginUi = try c.decodeFlexibleString(.loginUi)
        loginCheckJs = try c.decodeFlexibleString(.loginCheckJs)
        coverDecodeJs = try c.decodeFlexibleString(.coverDecodeJs)
        jsLib = try c.decodeFlexibleString(.jsLib)

        searchUrl = try c.decodeFlexibleString(.searchUrl)
        exploreUrl = try c.decodeFlexibleString(.exploreUrl)
        exploreScreen = try c.decodeFlexibleString(.exploreScreen)
        homepageModules = try c.decodeFlexibleString(.homepageModules)

        ruleDecodeIssues = []
        ruleSearch = try c.encodeRuleToData(.ruleSearch, fieldName: "ruleSearch", issues: &ruleDecodeIssues)
        ruleExplore = try c.encodeRuleToData(.ruleExplore, fieldName: "ruleExplore", issues: &ruleDecodeIssues)
        ruleBookInfo = try c.encodeRuleToData(.ruleBookInfo, fieldName: "ruleBookInfo", issues: &ruleDecodeIssues)
        ruleToc = try c.encodeRuleToData(.ruleToc, fieldName: "ruleToc", issues: &ruleDecodeIssues)
        ruleContent = try c.encodeRuleToData(.ruleContent, fieldName: "ruleContent", issues: &ruleDecodeIssues)
        var reviewIssues: [String] = []
        let reviewData = try c.encodeRuleToData(.ruleReview, issues: &reviewIssues)
        ruleReview = reviewData.isEmpty ? nil : reviewData

        bookSourceComment = try c.decodeFlexibleString(.bookSourceComment)
        variableComment = try c.decodeFlexibleString(.variableComment)

        // 保存未知字段
        var unknown: [String: JsonValue] = [:]
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let known = Set(CodingKeys.allStringValues)
        for key in dynamic.allKeys where !known.contains(key.stringValue) {
            if let v = try? dynamic.decode(JsonValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        unknownFields = unknown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bookSourceUrl, forKey: .bookSourceUrl)
        try c.encode(bookSourceName, forKey: .bookSourceName)
        try c.encodeIfPresent(bookSourceGroup, forKey: .bookSourceGroup)
        try c.encode(bookSourceType, forKey: .bookSourceType)
        try c.encodeIfPresent(bookUrlPattern, forKey: .bookUrlPattern)
        try c.encode(customOrder, forKey: .customOrder)
        try c.encode(weight, forKey: .weight)
        try c.encode(lastUpdateTime, forKey: .lastUpdateTime)
        try c.encode(respondTime, forKey: .respondTime)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(enabledExplore, forKey: .enabledExplore)
        try c.encode(enabledCookieJar, forKey: .enabledCookieJar)
        try c.encode(eventListener, forKey: .eventListener)
        try c.encodeIfPresent(customButton, forKey: .customButton)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encodeIfPresent(concurrentRate, forKey: .concurrentRate)
        try c.encodeIfPresent(loginUrl, forKey: .loginUrl)
        try c.encodeIfPresent(loginUi, forKey: .loginUi)
        try c.encodeIfPresent(loginCheckJs, forKey: .loginCheckJs)
        try c.encodeIfPresent(coverDecodeJs, forKey: .coverDecodeJs)
        try c.encodeIfPresent(jsLib, forKey: .jsLib)
        try c.encodeIfPresent(searchUrl, forKey: .searchUrl)
        try c.encodeIfPresent(exploreUrl, forKey: .exploreUrl)
        try c.encodeIfPresent(exploreScreen, forKey: .exploreScreen)
        try c.encodeIfPresent(homepageModules, forKey: .homepageModules)
        try c.encodeRuleData(ruleSearch, forKey: .ruleSearch)
        try c.encodeRuleData(ruleExplore, forKey: .ruleExplore)
        try c.encodeRuleData(ruleBookInfo, forKey: .ruleBookInfo)
        try c.encodeRuleData(ruleToc, forKey: .ruleToc)
        try c.encodeRuleData(ruleContent, forKey: .ruleContent)
        if let ruleReview { try c.encodeRuleData(ruleReview, forKey: .ruleReview) }
        try c.encodeIfPresent(bookSourceComment, forKey: .bookSourceComment)
        try c.encodeIfPresent(variableComment, forKey: .variableComment)

        // 未知字段原样回写，保证无损往返
        var dynamic = encoder.container(keyedBy: AnyCodingKey.self)
        for (k, v) in unknownFields.sorted(by: { $0.key < $1.key }) {
            try dynamic.encode(v, forKey: AnyCodingKey(k))
        }
    }
}

// MARK: - 解码辅助

extension BookSource.CodingKeys {
    static var allStringValues: [String] {
        [
            "bookSourceUrl", "bookSourceName", "bookSourceGroup", "bookSourceType",
            "bookUrlPattern", "customOrder", "weight", "lastUpdateTime", "respondTime",
            "enabled", "enabledExplore", "enabledCookieJar", "eventListener", "customButton",
            "header", "concurrentRate", "loginUrl", "loginUi", "loginCheckJs", "coverDecodeJs", "jsLib",
            "searchUrl", "exploreUrl", "exploreScreen", "homepageModules",
            "ruleSearch", "ruleExplore", "ruleBookInfo", "ruleToc", "ruleContent", "ruleReview",
            "bookSourceComment", "variableComment"
        ]
    }
}

extension KeyedDecodingContainer {
    func decodeFlexibleString(_ key: K) throws -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        // 数字型字段被写成数字时容忍（部分手写书源会这样）
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return JsonValue.number(d).text }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? "true" : "false" }
        return nil
    }

    func decodeFlexibleInt(_ key: K) throws -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return Int(s.trimmingCharacters(in: .whitespaces))
        }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? 1 : 0 }
        return nil
    }

    func decodeFlexibleBool(_ key: K) throws -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// 规则子对象既可能是对象也可能是字符串，统一转成 Data 存储。
    /// P1-20（v1.2.0）：畸形形态（字符串不是 JSON 对象 / 数组 / 数字布尔）不再静默变空，
    /// 记入 issues 供导入流程上报。
    func encodeRuleToData(_ key: K, fieldName: String? = nil, issues: inout [String]) throws -> Data {
        func report(_ msg: String) {
            if let fieldName { issues.append("\(fieldName) \(msg)") }
        }
        if let v = try? decodeIfPresent(JsonValue.self, forKey: key) {
            switch v {
            case .null: return Data()
            case .object:
                return (try? JSONEncoder().encode(v)) ?? Data()
            case .string(let s):
                // 字符串形态：本身就是序列化 JSON，规范化后存（保证后续解码稳定）
                if case .object(let o)? = JsonValue.parse(s) {
                    return (try? JSONEncoder().encode(JsonValue.object(o))) ?? Data()
                }
                report("为字符串形态但不是 JSON 对象，规则不可用")
                return Data()
            case .array:
                report("是数组（应为对象），规则不可用")
                return Data()
            case .number, .bool:
                report("类型不符（应为对象），规则不可用")
                return Data()
            }
        }
        return Data()
    }
}

extension KeyedEncodingContainer {
    mutating func encodeRuleData(_ data: Data, forKey key: K) throws {
        guard !data.isEmpty,
              let v = try? JSONDecoder().decode(JsonValue.self, from: data) else {
            return
        }
        try encode(v, forKey: key)
    }
}
