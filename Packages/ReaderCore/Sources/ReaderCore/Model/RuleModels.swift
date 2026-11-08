//
//  RuleModels.swift
//  ReaderCore
//
//  五套规则子对象的镜像。字段名与 legado 完全一致，便于导入导出零转换。
//
//  关键点（架构文档二·一）：legado 的这些子对象都带自定义 JsonDeserializer，
//  「既接受 JSON 对象，也接受 JSON 字符串」——`"ruleSearch": "{\"bookList\":\"...\"}"`
//  在生态中合法且常见。所以下面每个类型都手写 init(from:) 兼容两形态；
//  用属性包装器做不到，因为要区分「字符串」与「同名字段」。
//

import Foundation

// MARK: - 通用解码工具

/// 允许规则子对象是「对象」或「对象序列化后的字符串」。
enum FlexibleObject {
    static func decodeDict(
        from decoder: Decoder,
        codingPathKey: [String] = []
    ) throws -> [String: JsonValue] {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return [:] }
        // 对象形态
        if let dict = try? c.decode([String: JsonValue].self) {
            return dict
        }
        // 字符串形态：内部可能是 JSON 对象
        if let s = try? c.decode(String.self) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return [:] }
            if case .object(let o)? = JsonValue.parse(trimmed) { return o }
            return [:]
        }
        return [:]
    }

    static func string(_ dict: [String: JsonValue], _ key: String) -> String? {
        guard let v = dict[key] else { return nil }
        switch v {
        case .null: return nil
        case .string(let s): return s
        default: return v.text
        }
    }

    static func bool(_ dict: [String: JsonValue], _ key: String) -> Bool? {
        guard let v = dict[key] else { return nil }
        switch v {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s):
            let t = s.lowercased()
            if t == "true" || t == "1" { return true }
            if t == "false" || t == "0" { return false }
            return nil
        default: return nil
        }
    }

    static func int(_ dict: [String: JsonValue], _ key: String) -> Int? {
        guard let v = dict[key] else { return nil }
        switch v {
        case .number(let d): return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
}

/// 解码时容忍任意键名。
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
    init(_ s: String) { self.stringValue = s }
}

// MARK: - SearchRule（11 项）

public struct SearchRule: Codable, Sendable, Equatable {
    public var checkKeyWord: String?
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var bookUrl: String?
    public var coverUrl: String?
    public var wordCount: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = try FlexibleObject.decodeDict(from: decoder)
        checkKeyWord = FlexibleObject.string(d, "checkKeyWord")
        bookList = FlexibleObject.string(d, "bookList")
        name = FlexibleObject.string(d, "name")
        author = FlexibleObject.string(d, "author")
        intro = FlexibleObject.string(d, "intro")
        kind = FlexibleObject.string(d, "kind")
        lastChapter = FlexibleObject.string(d, "lastChapter")
        updateTime = FlexibleObject.string(d, "updateTime")
        bookUrl = FlexibleObject.string(d, "bookUrl")
        coverUrl = FlexibleObject.string(d, "coverUrl")
        wordCount = FlexibleObject.string(d, "wordCount")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeNonEmpty("checkKeyWord", checkKeyWord)
        try c.encodeNonEmpty("bookList", bookList)
        try c.encodeNonEmpty("name", name)
        try c.encodeNonEmpty("author", author)
        try c.encodeNonEmpty("intro", intro)
        try c.encodeNonEmpty("kind", kind)
        try c.encodeNonEmpty("lastChapter", lastChapter)
        try c.encodeNonEmpty("updateTime", updateTime)
        try c.encodeNonEmpty("bookUrl", bookUrl)
        try c.encodeNonEmpty("coverUrl", coverUrl)
        try c.encodeNonEmpty("wordCount", wordCount)
    }
}

// MARK: - ExploreRule（10 项列表 + pageParam）

public struct ExploreRule: Codable, Sendable, Equatable {
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var bookUrl: String?
    public var coverUrl: String?
    public var wordCount: String?
    public var pageParam: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = try FlexibleObject.decodeDict(from: decoder)
        bookList = FlexibleObject.string(d, "bookList")
        name = FlexibleObject.string(d, "name")
        author = FlexibleObject.string(d, "author")
        intro = FlexibleObject.string(d, "intro")
        kind = FlexibleObject.string(d, "kind")
        lastChapter = FlexibleObject.string(d, "lastChapter")
        updateTime = FlexibleObject.string(d, "updateTime")
        bookUrl = FlexibleObject.string(d, "bookUrl")
        coverUrl = FlexibleObject.string(d, "coverUrl")
        wordCount = FlexibleObject.string(d, "wordCount")
        pageParam = FlexibleObject.string(d, "pageParam")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeNonEmpty("bookList", bookList)
        try c.encodeNonEmpty("name", name)
        try c.encodeNonEmpty("author", author)
        try c.encodeNonEmpty("intro", intro)
        try c.encodeNonEmpty("kind", kind)
        try c.encodeNonEmpty("lastChapter", lastChapter)
        try c.encodeNonEmpty("updateTime", updateTime)
        try c.encodeNonEmpty("bookUrl", bookUrl)
        try c.encodeNonEmpty("coverUrl", coverUrl)
        try c.encodeNonEmpty("wordCount", wordCount)
        try c.encodeNonEmpty("pageParam", pageParam)
    }
}

// MARK: - BookInfoRule（13 项）

public struct BookInfoRule: Codable, Sendable, Equatable {
    public var `init`: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var coverUrl: String?
    public var tocUrl: String?
    public var wordCount: String?
    public var canReName: String?
    public var downloadUrls: String?
    public var relatedBooks: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = try FlexibleObject.decodeDict(from: decoder)
        self.`init` = FlexibleObject.string(d, "init")
        name = FlexibleObject.string(d, "name")
        author = FlexibleObject.string(d, "author")
        intro = FlexibleObject.string(d, "intro")
        kind = FlexibleObject.string(d, "kind")
        lastChapter = FlexibleObject.string(d, "lastChapter")
        updateTime = FlexibleObject.string(d, "updateTime")
        coverUrl = FlexibleObject.string(d, "coverUrl")
        tocUrl = FlexibleObject.string(d, "tocUrl")
        wordCount = FlexibleObject.string(d, "wordCount")
        canReName = FlexibleObject.string(d, "canReName")
        downloadUrls = FlexibleObject.string(d, "downloadUrls")
        relatedBooks = FlexibleObject.string(d, "relatedBooks")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeNonEmpty("init", self.`init`)
        try c.encodeNonEmpty("name", name)
        try c.encodeNonEmpty("author", author)
        try c.encodeNonEmpty("intro", intro)
        try c.encodeNonEmpty("kind", kind)
        try c.encodeNonEmpty("lastChapter", lastChapter)
        try c.encodeNonEmpty("updateTime", updateTime)
        try c.encodeNonEmpty("coverUrl", coverUrl)
        try c.encodeNonEmpty("tocUrl", tocUrl)
        try c.encodeNonEmpty("wordCount", wordCount)
        try c.encodeNonEmpty("canReName", canReName)
        try c.encodeNonEmpty("downloadUrls", downloadUrls)
        try c.encodeNonEmpty("relatedBooks", relatedBooks)
    }
}

// MARK: - TocRule（10 项）

public struct TocRule: Codable, Sendable, Equatable {
    public var preUpdateJs: String?
    public var chapterList: String?
    public var chapterName: String?
    public var chapterUrl: String?
    public var formatJs: String?
    public var isVolume: String?
    public var isVip: String?
    public var isPay: String?
    public var updateTime: String?
    public var nextTocUrl: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = try FlexibleObject.decodeDict(from: decoder)
        preUpdateJs = FlexibleObject.string(d, "preUpdateJs")
        chapterList = FlexibleObject.string(d, "chapterList")
        chapterName = FlexibleObject.string(d, "chapterName")
        chapterUrl = FlexibleObject.string(d, "chapterUrl")
        formatJs = FlexibleObject.string(d, "formatJs")
        isVolume = FlexibleObject.string(d, "isVolume")
        isVip = FlexibleObject.string(d, "isVip")
        isPay = FlexibleObject.string(d, "isPay")
        updateTime = FlexibleObject.string(d, "updateTime")
        nextTocUrl = FlexibleObject.string(d, "nextTocUrl")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeNonEmpty("preUpdateJs", preUpdateJs)
        try c.encodeNonEmpty("chapterList", chapterList)
        try c.encodeNonEmpty("chapterName", chapterName)
        try c.encodeNonEmpty("chapterUrl", chapterUrl)
        try c.encodeNonEmpty("formatJs", formatJs)
        try c.encodeNonEmpty("isVolume", isVolume)
        try c.encodeNonEmpty("isVip", isVip)
        try c.encodeNonEmpty("isPay", isPay)
        try c.encodeNonEmpty("updateTime", updateTime)
        try c.encodeNonEmpty("nextTocUrl", nextTocUrl)
    }
}

// MARK: - ContentRule（11 项）

public struct ContentRule: Codable, Sendable, Equatable {
    public var content: String?
    public var subContent: String?
    public var title: String?
    public var nextContentUrl: String?
    public var webJs: String?
    public var sourceRegex: String?
    /// P1 净化用，本版不执行；保留字段以保证导入导出无损。
    public var replaceRegex: String?
    public var imageStyle: String?
    public var imageDecode: String?
    /// 本版不支持（不绕过付费墙）。
    public var payAction: String?
    public var callBackJs: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = try FlexibleObject.decodeDict(from: decoder)
        content = FlexibleObject.string(d, "content")
        subContent = FlexibleObject.string(d, "subContent")
        title = FlexibleObject.string(d, "title")
        nextContentUrl = FlexibleObject.string(d, "nextContentUrl")
        webJs = FlexibleObject.string(d, "webJs")
        sourceRegex = FlexibleObject.string(d, "sourceRegex")
        replaceRegex = FlexibleObject.string(d, "replaceRegex")
        imageStyle = FlexibleObject.string(d, "imageStyle")
        imageDecode = FlexibleObject.string(d, "imageDecode")
        payAction = FlexibleObject.string(d, "payAction")
        callBackJs = FlexibleObject.string(d, "callBackJs")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeNonEmpty("content", content)
        try c.encodeNonEmpty("subContent", subContent)
        try c.encodeNonEmpty("title", title)
        try c.encodeNonEmpty("nextContentUrl", nextContentUrl)
        try c.encodeNonEmpty("webJs", webJs)
        try c.encodeNonEmpty("sourceRegex", sourceRegex)
        try c.encodeNonEmpty("replaceRegex", replaceRegex)
        try c.encodeNonEmpty("imageStyle", imageStyle)
        try c.encodeNonEmpty("imageDecode", imageDecode)
        try c.encodeNonEmpty("payAction", payAction)
        try c.encodeNonEmpty("callBackJs", callBackJs)
    }
}

// MARK: - 编码辅助

extension KeyedEncodingContainer where Key == AnyCodingKey {
    mutating func encodeNonEmpty(_ key: String, _ value: String?) throws {
        guard let value, !value.isEmpty else { return }
        try encode(value, forKey: AnyCodingKey(key))
    }
}
