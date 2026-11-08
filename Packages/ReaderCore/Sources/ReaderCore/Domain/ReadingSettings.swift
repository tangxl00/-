//
//  ReadingSettings.swift
//  ReaderCore
//
//  阅读界面自定义（P0-5 / 需求 2-10 ~ 2-12 / 4.7）。
//
//  要求逐条：
//    · 字号 / 行距 / 段距 / 页边距 / 首行缩进 —— 全部是数值参数。
//    · 字体子集 ≥3 种系统字体 —— `ReaderFont` 给 4 种（系统/宋体/黑体/圆体），
//      都映射到 iOS 上真实存在的系统字体名，不引入自定义字体文件（避免包体与授权问题）。
//    · 日/夜配色 + ≥2 背景色 —— `ReaderTheme` 给 4 套（日间白、日间米、夜间深、夜间灰）。
//    · 即时生效 + 退出重进保留 + **改参数后阅读位置不跳** ——
//      位置不跳由「进度存字符偏移」保证（见 ReadingProgress.swift）；
//      这里只负责参数本身，并提供 `layoutSignature` 用于分页缓存失效。
//

import Foundation

// MARK: - 字体

/// 可选字体子集。
/// 全部映射到 iOS 系统自带字体（不打包字体文件）：4 种 ≥ 需求要求的 3 种。
public enum ReaderFont: String, CaseIterable, Sendable, Codable {
    case system
    case serif
    case sans
    case rounded

    public var displayName: String {
        switch self {
        case .system: return "系统默认"
        case .serif: return "宋体（衬线）"
        case .sans: return "黑体（无衬线）"
        case .rounded: return "圆体"
        }
    }

    /// iOS 上真实可用的 PostScript / family 名。
    /// - Note: iOS 上 `UIFont(name:)` 用 family 名不可靠，用具体字体名更稳；
    ///   这里给出主选 + 逐个回退链，最终回退 `UIFont.systemFont`。
    public var iOSExtraCandidates: [String] {
        switch self {
        case .system: return ["PingFangSC-Regular"]
        case .serif: return ["SongtiSC-Regular", "STSongti-SC-Regular", "TimesNewRomanPSMT"]
        case .sans: return ["PingFangSC-Regular", "HeitiSC-Light", "HelveticaNeue"]
        case .rounded: return ["PingFangSC-Regular", "ArialRoundedMTBold", ".SFUI-Rounded"]
        }
    }
}

// MARK: - 主题

public enum ReaderTheme: String, CaseIterable, Sendable, Codable {
    case lightPaper       // 日间 · 纸白
    case lightSepia       // 日间 · 米黄
    case darkNight        // 夜间 · 深黑
    case darkGray         // 夜间 · 深灰

    public var isDark: Bool {
        self == .darkNight || self == .darkGray
    }

    public var displayName: String {
        switch self {
        case .lightPaper: return "日间 · 纸白"
        case .lightSepia: return "日间 · 米黄"
        case .darkNight: return "夜间 · 深黑"
        case .darkGray: return "夜间 · 深灰"
        }
    }

    /// 背景色（hex，含 alpha 由调用方处理）。UI 层转 UIColor 用。
    public var backgroundHex: String {
        switch self {
        case .lightPaper: return "#FFFFFF"
        case .lightSepia: return "#F5EBDC"
        case .darkNight: return "#000000"
        case .darkGray: return "#1C1C1E"
        }
    }

    public var textHex: String {
        switch self {
        case .lightPaper: return "#1A1A1A"
        case .lightSepia: return "#3B2F20"
        case .darkNight: return "#C8C8C8"
        case .darkGray: return "#B0B0B4"
        }
    }

    /// 次要文字（章节标题、进度条等）
    public var secondaryTextHex: String {
        isDark ? "#8A8A8E" : "#7A7A7A"
    }
}

// MARK: - 设置

/// 阅读界面设置。全部字段都有默认值，可直接从 `UserDefaults` 反序列化缺字段的老版本数据。
public struct ReadingSettings: Sendable, Equatable, Codable {
    /// 字号（pt），可调范围由 `fontSizeRange` 约束
    public var fontSize: Double
    /// 行距倍数（1.0 = 单倍），可调范围 `lineSpacingRange`
    public var lineSpacing: Double
    /// 段间距（pt，段与段之间的额外空白）
    public var paragraphSpacing: Double
    /// 页边距（pt，左右一致；上下用 `verticalMarginRatio` 联动）
    public var horizontalMargin: Double
    /// 首行缩进（字符数，0 = 不缩进）
    public var firstLineIndent: Double
    /// 字体
    public var font: ReaderFont
    /// 主题
    public var theme: ReaderTheme

    public init(
        fontSize: Double = 17,
        lineSpacing: Double = 1.5,
        paragraphSpacing: Double = 10,
        horizontalMargin: Double = 20,
        firstLineIndent: Double = 2,
        font: ReaderFont = .system,
        theme: ReaderTheme = .lightPaper
    ) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.horizontalMargin = horizontalMargin
        self.firstLineIndent = firstLineIndent
        self.font = font
        self.theme = theme
    }

    public static let `default` = ReadingSettings()

    // MARK: 可调范围

    public static let fontSizeRange: ClosedRange<Double> = 12...32
    public static let lineSpacingRange: ClosedRange<Double> = 1.0...2.5
    public static let paragraphSpacingRange: ClosedRange<Double> = 0...30
    public static let horizontalMarginRange: ClosedRange<Double> = 8...48
    public static let firstLineIndentRange: ClosedRange<Double> = 0...4

    /// 上下边距按左右边距的比例（固定比例，避免出现上下 0 边距贴边）
    public static let verticalMarginRatio: Double = 1.4

    // MARK: 校验

    /// 把越界值钳回合法范围。反序列化老数据 / 外部写入都可能越界。
    public func clamped() -> ReadingSettings {
        var s = self
        s.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        s.lineSpacing = min(
            max(lineSpacing, Self.lineSpacingRange.lowerBound),
            Self.lineSpacingRange.upperBound
        )
        s.paragraphSpacing = min(
            max(paragraphSpacing, Self.paragraphSpacingRange.lowerBound),
            Self.paragraphSpacingRange.upperBound
        )
        s.horizontalMargin = min(
            max(horizontalMargin, Self.horizontalMarginRange.lowerBound),
            Self.horizontalMarginRange.upperBound
        )
        s.firstLineIndent = min(
            max(firstLineIndent, Self.firstLineIndentRange.lowerBound),
            Self.firstLineIndentRange.upperBound
        )
        return s
    }

    /// 排版签名：任何影响分页/行数的参数变化都会改变签名，
    /// 用于让分页缓存与「首可见字符偏移」缓存失效。**注意不含 theme**
    /// —— 换配色不影响排版，不应触发重新分页（否则切日/夜会白重算一遍）。
    public var layoutSignature: String {
        "f\(fontSize)-l\(lineSpacing)-p\(paragraphSpacing)-m\(horizontalMargin)-i\(firstLineIndent)-font\(font.rawValue)"
    }

    /// 影响阅读位置稳定性的参数（字号/行距/段距/边距/字体）。
    /// 主题变化不在此列：切主题不该改变阅读位置。
    public var affectsLayout: Bool { true }
}

// MARK: - 字号档位（UI 用）

public enum ReadingSettingsPresets {
    /// 字号档位表（UI 上做成「A- / A+」或用分段控件）
    public static let fontSizes: [Double] = [12, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 30, 32]
    public static let lineSpacings: [Double] = [1.0, 1.2, 1.4, 1.5, 1.7, 1.9, 2.2, 2.5]
    public static let paragraphSpacings: [Double] = [0, 4, 8, 10, 14, 18, 24, 30]
    public static let margins: [Double] = [8, 12, 16, 20, 24, 32, 40, 48]
    public static let indents: [Double] = [0, 1, 2, 3, 4]

    public static func nextFontSize(_ current: Double, up: Bool) -> Double {
        step(current, in: fontSizes, up: up)
    }

    public static func step(_ current: Double, in list: [Double], up: Bool) -> Double {
        if up {
            return list.first { $0 > current + 0.001 } ?? list.last ?? current
        }
        return list.last { $0 < current - 0.001 } ?? list.first ?? current
    }
}
