//
//  ContentProcessor.swift
//  ReaderCore
//
//  正文净化流水线（架构文档二·八，任务模块二）。
//
//  真实顺序（顺序错了，替换规则会作用在错误文本上）：
//    ① 去掉正文开头的重复标题（用章节名构造正则，允许前缀标点）
//    ② reSegment 重新分段（按句号/引号等切段；用户设置，默认关闭）
//    ③ 繁简转换（按用户设置走 t2s / s2t，默认关闭）
//    ④ 逐行 trim
//    ⑤ 应用用户 ReplaceRule 列表（每条规则独立超时，默认 3000ms，
//       正则路径用剩余时间熔断；scope/excludeScope/scopeTitle/scopeContent 过滤）
//    ⑥ 书源自带正文后处理（ruleContent.replaceRegex / sourceRegex）
//    ⑦ 补标题、段落缩进
//
//  解释性偏差（与 Android 侧的差异，逐条对齐后在《实现说明》登记）：
//    · reSegment / 繁简转换 / 补标题 / 段落缩进都是用户设置项，默认全部关闭
//      （对齐 legado：reSegment 与 t2s/s2t 是阅读设置；关闭态保证
//      「净化后段落数与原文一致 ±0」的可验收性）；
//    · 书源 replaceRegex / sourceRegex 采用 `pattern##replacement##` 语义
//      （第三段存在 = 只替换首个），无 `##` 时整串视为 pattern、替换为空（删除）；
//    · 段落缩进用两个全角空格，标题行不缩进。
//

import Foundation

// MARK: - 配置

public enum ChineseConversionMode: String, Sendable, Codable {
    case none
    case t2s
    case s2t
}

public struct ContentProcessOptions: Sendable, Codable {
    /// ② reSegment 重新分段（按句末标点切段）
    public var reSegment: Bool
    /// ③ 繁简转换
    public var chineseConversion: ChineseConversionMode
    /// ⑦ 补标题（正文顶部缺失章节标题时补一行）
    public var reinsertTitle: Bool
    /// ⑦ 段落缩进（每段行首两个全角空格；标题行不缩进）
    public var indentParagraphs: Bool

    public init(reSegment: Bool = false,
                chineseConversion: ChineseConversionMode = .none,
                reinsertTitle: Bool = false,
                indentParagraphs: Bool = false) {
        self.reSegment = reSegment
        self.chineseConversion = chineseConversion
        self.reinsertTitle = reinsertTitle
        self.indentParagraphs = indentParagraphs
    }
}

/// 净化执行报告（供调试 / UI 提示）
public struct ContentProcessReport: Sendable {
    public var appliedRules: [String] = []
    public var timedOutRules: [String] = []
    public init() {}
}

// MARK: - 净化输入（fetchContent 的可选参数）

/// 调用方（App 层）传入的用户净化配置：替换规则 + 设置项。
/// nil = 不启用用户净化（P0 行为，仅书源侧正则参与）。
public struct ContentPurifyInput: Sendable {
    public var rules: [ReplaceRule]
    public var options: ContentProcessOptions

    public init(rules: [ReplaceRule] = [], options: ContentProcessOptions = ContentProcessOptions()) {
        self.rules = rules
        self.options = options
    }
}

// MARK: - 流水线

public enum ContentProcessor {

    public static func process(
        text: String,
        chapterTitle: String,
        bookName: String,
        rules: [ReplaceRule],
        sourceReplaceRegex: String? = nil,
        sourceRegex: String? = nil,
        options: ContentProcessOptions = ContentProcessOptions()
    ) -> (text: String, report: ContentProcessReport) {
        var report = ContentProcessReport()

        // ① 去掉正文开头的重复标题
        var body = stripLeadingTitle(text, chapterTitle: chapterTitle)

        // ② reSegment 重新分段
        if options.reSegment {
            body = reSegment(body)
        }

        // ③ 繁简转换
        switch options.chineseConversion {
        case .none: break
        case .t2s: body = ChineseConverter.toSimplified(body)
        case .s2t: body = ChineseConverter.toTraditional(body)
        }

        // ④ 逐行 trim
        body = trimLines(body)

        // ⑤ 用户替换规则（按 sortOrder 升序；每条独立超时，超时熔断不中断整条流水线）
        let sorted = rules
            .filter { $0.enable }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder }
        for rule in sorted {
            // scope 过滤：scope 空 = 全部书；命中才作用
            if !ReplaceRuleScope.scopeMatches(rule.scope, bookName: bookName) { continue }
            // excludeScope 过滤：命中的书被排除，规则跳过
            if ReplaceRuleScope.excludeMatches(rule.excludeScope, bookName: bookName) { continue }
            // scopeTitle / scopeContent：默认只作用正文（P1 阅读器正文场景恒走此分支，
            // scopeTitle 场景由目录标题净化调用方自行按字段拆分，这里按 scopeContent=false 跳过）
            guard rule.scopeContent || rule.scopeTitle else { continue }

            let deadline = Date().addingTimeInterval(TimeInterval(rule.timeoutMillisecond) / 1000.0)
            let (next, outcome) = ReplaceRuleEngine.apply(rule, to: body, deadline: deadline)
            switch outcome {
            case .applied:
                report.appliedRules.append(rule.name.isEmpty ? rule.pattern.prefix(24).description : rule.name)
            case .timedOut:
                report.timedOutRules.append(rule.name.isEmpty ? rule.pattern.prefix(24).description : rule.name)
            case .noMatch, .skipped:
                break
            }
            body = next
        }

        // ⑥ 书源自带正文后处理（replaceRegex / sourceRegex）
        body = applySourceReplace(body, spec: sourceReplaceRegex)
        body = applySourceReplace(body, spec: sourceRegex)

        // ⑦ 补标题、段落缩进
        body = finalize(body, chapterTitle: chapterTitle, options: options)

        return (body, report)
    }

    // MARK: ① 去重复标题

    /// 用章节名构造正则，允许前缀/后缀标点（「『《（(【“ 等成对符号）。
    /// 只处理正文开头的第一条非空行；标题为空或正文为空时不动。
    static func stripLeadingTitle(_ text: String, chapterTitle: String) -> String {
        let title = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !text.isEmpty else { return text }

        var lines = text.components(separatedBy: "\n")
        // 找第一条非空行
        guard let idx = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return text
        }
        let line = lines[idx].trimmingCharacters(in: .whitespaces)
        let escaped = NSRegularExpression.escapedPattern(for: title)
        let pattern = "^[\\s「『《（(【“\"']*]*" + escaped + "[\\s」』》）)】”\"']*]*$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(line.startIndex..., in: line)
        if re.firstMatch(in: line, range: range) != nil {
            lines[idx] = ""
        }
        return lines.joined(separator: "\n")
    }

    // MARK: ② reSegment

    /// 按句末标点（。！？!?…；）切段；句末紧跟的收尾引号/括号与重复标点跟随本句。
    /// 原有换行视为段落边界信号保留在输出行序里（空行丢弃），
    /// 段内长句被切分为「一句一行」。这是对 legado reSegment 的解释性实现，
    /// 默认关闭（见文件头偏差说明）。
    static func reSegment(_ text: String) -> String {
        var outLines: [String] = []
        let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?", "…", "；"]
        let tailAbsorb: Set<Character> = ["。", "！", "？", "!", "?", "…", "；", ";",
                                          "」", "』", "）", ")", "】", "”", "\"", "'", "》"]
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var current = ""
            var afterEnd = false
            for ch in line {
                if afterEnd {
                    if tailAbsorb.contains(ch) {
                        current.append(ch)
                        continue
                    }
                    outLines.append(current)
                    current = String(ch)
                    afterEnd = sentenceEnds.contains(ch)
                } else {
                    current.append(ch)
                    if sentenceEnds.contains(ch) { afterEnd = true }
                }
            }
            if !current.isEmpty { outLines.append(current) }
        }
        return outLines.joined(separator: "\n")
    }

    // MARK: ④ 逐行 trim

    static func trimLines(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    // MARK: ⑥ 书源自带替换

    /// `pattern##replacement##isFirst`；无 ## 时整串为 pattern、替换为空。
    static func applySourceReplace(_ text: String, spec: String?) -> String {
        guard let spec = spec?.trimmingCharacters(in: .whitespacesAndNewlines),
              !spec.isEmpty else { return text }

        let parts = spec.components(separatedBy: "##")
        let pattern: String
        let replacement: String
        let firstOnly: Bool
        if parts.count >= 3, !parts[2].isEmpty {
            // 架构文档语义：「##匹配##替换##」第三段任意字符存在即为只替换首个；
            // 尾随 ## 产生的空第三段不算（"a##b##" 仍为全量替换）
            pattern = parts[0]
            replacement = parts[1]
            firstOnly = true
        } else if parts.count >= 2 {
            pattern = parts[0]
            replacement = parts[1]
            firstOnly = false
        } else {
            pattern = spec
            replacement = ""
            firstOnly = false
        }
        guard !pattern.isEmpty else { return text }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }

        let ns = text as NSString
        if firstOnly {
            guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
                return text
            }
            return ns.replacingCharacters(in: m.range, with: replacement)
        }
        var out = ""
        var pos = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            out += replacement
            pos = m.range.location + m.range.length
        }
        out += ns.substring(from: pos)
        return out
    }

    // MARK: ⑦ 补标题、段落缩进

    static func finalize(_ text: String, chapterTitle: String, options: ContentProcessOptions) -> String {
        var lines = text.components(separatedBy: "\n")
        // 去掉头部空行
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return text }

        let title = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        // 补标题：正文顶部没有标题行（且设置开启）时补一行
        if options.reinsertTitle, !title.isEmpty {
            let first = lines[0].trimmingCharacters(in: .whitespaces)
            let titleLike = first == title
                || (title.count >= 2 && first.contains(title))
                || (first.count >= 2 && title.contains(first))
            if !titleLike {
                lines.insert(title, at: 0)
            }
        }

        // 段落缩进：非空行行首补两个全角空格；标题行（补上的第 0 行）不缩进
        if options.indentParagraphs {
            let titleLineIdx = (options.reinsertTitle && !title.isEmpty && lines.first == title) ? 0 : -1
            lines = lines.enumerated().map { i, line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { return "" }
                if i == titleLineIdx { return t }
                return "　　" + t
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 默认净化规则组

/// 内置常见站点水印/广告净化规则（「默认规则组」，用户可整体停用或逐条改）。
/// 全部为行级正则：只删整行命中水印文案的行，不触碰正文段落本身，
/// 保证「段落数与原文一致 ±0」的验收口径（水印行本身计为被净化的目标行）。
public enum DefaultPurifyRules {

    public static let groupName = "默认规则组"

    /// 规则模板：命中这些模式之一的**整行**视为水印/推广行并删除。
    /// 取材于常见盗版聚合站的通用文案（不含任何具体站点品牌词之外的可疑泛化）。
    private static let linePatterns: [(String, String)] = [
        ("去重复标题守则外-未完待续", "未完待续[。.!！]?$"),
        ("首发域名提示", "请记住本书(首发|首发域名|最新)域名.*"),
        ("一秒记住", "^.*一秒记住.*$"),
        ("手机用户提示", "^.*手机用户(请|可以)(浏览|访问|阅读).*$"),
        ("更多精彩提示", "^.*更多(精彩|好看)(小说)?(请|就)(访问|到|去).*$"),
        ("本站网址提示", "^.*本站(最新网址|唯一地址|地址).*$"),
        ("笔趣系列站名", "^\\(?笔趣阁.*\\)?$"),
        ("求票求收藏", "^求(收藏|推荐票?|月票|鲜花|评价票).*$"),
    ]

    public static func rules() -> [ReplaceRule] {
        linePatterns.enumerated().map { idx, entry in
            ReplaceRule(
                id: "default-purify-\(idx + 1)",
                name: entry.0,
                group: groupName,
                pattern: "^[ \\t]*" + entry.1,
                replacement: "",
                isRegex: true,
                scope: "",
                scopeTitle: false,
                scopeContent: true,
                excludeScope: "",
                timeoutMillisecond: 3000,
                sortOrder: 9000 + idx,
                enable: true
            )
        }
    }
}
