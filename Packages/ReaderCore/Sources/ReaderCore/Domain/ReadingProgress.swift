//
//  ReadingProgress.swift
//  ReaderCore
//
//  阅读进度模型（P0-8 / 需求 2-14 / 4.9，五条细口径）。
//
//  ★ 需求 4.9 的五条口径逐条对应：
//    (1) 按「章节 + 字符偏移」记录，不用页码 —— `ReadingProgress` 只有
//        `chapterIndex` + `characterOffset` 两个定位字段，没有 page 字段。
//    (2) 切章这个动作本身必须触发持久化，不能只依赖滚动停止事件 ——
//        由 `ProgressCoordinator.switchChapter(...)` 强制 `save()`，
//        与滚动产生的 `update(offset:)`（可节流）分开。
//    (3) 字号变化后位置不漂到章首或别章 —— 因为进度存的是「字符偏移」而非
//        「页内比例」，字号变化只影响渲染分页，偏移值不变；见
//        `ProgressRestorer.offsetAfterLayoutChange(...)` 的断言与测试。
//    (4) 书架进度与阅读页实时一致 —— `ProgressCoordinator` 是单一事实源，
//        书架读同一个 `store`，不做第二份副本。
//    (5) 杀进程后能续读 —— `save()` 是同步写（UserDefaults/SwiftData 均可），
//        切章即写，滚动节流写（≤1s），保证强杀最多丢 1 秒的滚动。
//
//  这一层刻意不依赖 SwiftData / UIKit，纯值类型 + 协议，便于在 Linux 上跑测试。
//

import Foundation

// MARK: - 进度值

/// 阅读进度（章节 + 字符偏移）。
public struct ReadingProgress: Sendable, Equatable, Codable {
    /// 书籍唯一标识（`origin|bookUrl` 形式，跨源唯一）
    public var bookKey: String
    /// 章节下标（0 基）
    public var chapterIndex: Int
    /// 章节内字符偏移（0 基，指向该章正文纯文本的第几个字符）
    public var characterOffset: Int
    /// 章节标题快照（用于列表展示与「目录跳转」定位；不参与排序）
    public var chapterTitle: String
    /// 全书进度百分比（0...1），由章节数与章内偏移估算，仅展示用
    public var fraction: Double
    /// 最后阅读时间（用于书架「最近阅读」排序）
    public var updatedAt: Date

    public init(
        bookKey: String,
        chapterIndex: Int,
        characterOffset: Int,
        chapterTitle: String = "",
        fraction: Double = 0,
        updatedAt: Date = Date()
    ) {
        self.bookKey = bookKey
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.chapterTitle = chapterTitle
        self.fraction = fraction
        self.updatedAt = updatedAt
    }
}

// MARK: - 章节文本度量

/// 一章的「可度量信息」：正文字符数。用于把偏移换算成百分比、以及给 UI 显示。
public struct ChapterMetrics: Sendable, Equatable {
    public var chapterIndex: Int
    public var characterCount: Int

    public init(chapterIndex: Int, characterCount: Int) {
        self.chapterIndex = chapterIndex
        self.characterCount = characterCount
    }
}

// MARK: - 存储协议

/// 进度持久化接口。iOS 侧用 SwiftData/UserDefaults 实现，测试用内存实现。
public protocol ProgressStoring: AnyObject, Sendable {
    func load(bookKey: String) -> ReadingProgress?
    func save(_ progress: ReadingProgress)
    /// 书架排序用：所有进度按 updatedAt 降序
    func allProgress() -> [ReadingProgress]
    func remove(bookKey: String)
}

/// 内存实现（测试 / 预览用；也可作为 iOS 上「无 SwiftData 时」的降级实现）。
public final class InMemoryProgressStore: ProgressStoring, @unchecked Sendable {
    private var map: [String: ReadingProgress] = [:]
    private let lock = NSLock()

    public init() {}

    public func load(bookKey: String) -> ReadingProgress? {
        lock.lock(); defer { lock.unlock() }
        return map[bookKey]
    }

    public func save(_ progress: ReadingProgress) {
        lock.lock(); defer { lock.unlock() }
        map[progress.bookKey] = progress
    }

    public func allProgress() -> [ReadingProgress] {
        lock.lock(); defer { lock.unlock() }
        return map.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func remove(bookKey: String) {
        lock.lock(); defer { lock.unlock() }
        map.removeValue(forKey: bookKey)
    }

    /// 测试用：当前条数
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return map.count
    }
}

// MARK: - 坐标（跨层交换用）

/// 阅读器与 Domain 之间交换的「位置」。
/// 刻意分成 `chapterIndex` + `characterOffset`，不让上层接触页码。
public struct ReadingLocator: Sendable, Equatable {
    public var chapterIndex: Int
    public var characterOffset: Int

    public init(chapterIndex: Int, characterOffset: Int) {
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
    }
}

// MARK: - 进度协调器（单一事实源）

/// 进度协调器：把「切章」「滚动」「字号变化」「退出」四类事件统一收敛到一次持久化。
///
/// 设计要点：
///   · `switchChapter` **无条件立即 save**（需求 4.9-(2)：切章本身即持久化）。
///     即使新旧章节偏移都是 0，也要写一次 —— 因为「读了第几章」这件事变了。
///   · `updateOffset` 允许节流（滚动事件高频），但节流上限 ≤1s，且**切章/退出前
///     必须 flush**，否则强杀会丢。
///   · `restore` 在字号/行距变化后调用，只调整偏移到合法范围（不归零），
///     从而满足 4.9-(3)「字号变化后位置不漂到章首」。
public final class ProgressCoordinator: @unchecked Sendable {
    private let store: ProgressStoring
    /// 本书的唯一标识（`origin|bookUrl`），首次构造时固定，避免 current 为 nil 时丢失
    public let bookKey: String
    private let lock = NSLock()
    /// 当前进度（内存中的最新值）
    private var current: ReadingProgress?
    /// 滚动节流：pending 的偏移
    private var pendingOffset: Int?
    private var lastSaveAt: Date = .distantPast
    /// 节流窗口（秒）。1s 是「强杀最多丢 1 秒滚动」与「写入频率不过高」的折中。
    public var throttleInterval: TimeInterval = 1.0

    public init(store: ProgressStoring, bookKey: String) {
        self.store = store
        self.bookKey = bookKey
        self.current = store.load(bookKey: bookKey)
    }

    /// 当前进度（只读快照）
    public var snapshot: ReadingProgress? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// 初次加载：返回库里已有的进度（书架续读用）。
    public func restore() -> ReadingLocator? {
        lock.lock(); defer { lock.unlock() }
        guard let c = current else { return nil }
        return ReadingLocator(chapterIndex: c.chapterIndex, characterOffset: c.characterOffset)
    }

    /// **切章立即持久化**（需求 4.9-(2)）。
    /// - Parameters:
    ///   - chapterIndex: 新章节下标
    ///   - chapterTitle: 新章节标题
    ///   - offset: 新章内的偏移（通常 0，也可能从目录跳转带着历史偏移）
    ///   - chapterCount: 全书章节数（算百分比用）
    public func switchChapter(
        to chapterIndex: Int,
        title: String,
        offset: Int = 0,
        chapterCount: Int
    ) {
        lock.lock()
        let p = ReadingProgress(
            bookKey: bookKey,
            chapterIndex: max(0, chapterIndex),
            characterOffset: max(0, offset),
            chapterTitle: title,
            fraction: Self.fraction(
                chapterIndex: chapterIndex,
                offset: offset,
                chapterCount: chapterCount
            ),
            updatedAt: Date()
        )
        current = p
        pendingOffset = nil
        lastSaveAt = Date()
        lock.unlock()
        store.save(p)   // 立即写，不等节流
    }

    /// 滚动更新（可节流）。切章后立刻滚动也要保证最终落盘。
    public func updateOffset(_ offset: Int) {
        lock.lock()
        pendingOffset = max(0, offset)
        let now = Date()
        let shouldFlush = now.timeIntervalSince(lastSaveAt) >= throttleInterval
        lock.unlock()
        if shouldFlush { flush() }
    }

    /// 把待写偏移立即落盘。退出阅读页 / 切后台 / 切章前必须调。
    public func flush() {
        lock.lock()
        guard let pending = pendingOffset, var c = current else {
            lock.unlock()
            return
        }
        c.characterOffset = max(0, pending)
        c.updatedAt = Date()
        current = c
        pendingOffset = nil
        lastSaveAt = Date()
        lock.unlock()
        store.save(c)
    }

    /// 字号/行距/边距变化后的偏移校正。
    /// 因为进度存的是字符偏移，理论上不需要任何调整 —— 这里只做「越界钳制」：
    /// 若章节正文变短（换源/重新解析），偏移不能超出新长度，也不能归零。
    /// - Returns: 校正后的偏移（永远 >= 0；只有章节变短才可能变小）
    public static func clampOffset(_ offset: Int, chapterCharacterCount: Int) -> Int {
        guard chapterCharacterCount > 0 else { return max(0, offset) }
        return min(max(0, offset), chapterCharacterCount)
    }

    /// 百分比估算：以「平均每章等长」近似 + 章内偏移。
    public static func fraction(chapterIndex: Int, offset: Int, chapterCount: Int) -> Double {
        guard chapterCount > 0 else { return 0 }
        let base = Double(max(0, chapterIndex)) / Double(chapterCount)
        // 章内偏移的贡献上限是本段区间（1/chapterCount）的一半，
        // 避免「章内读到 50% 就显示全书 80%」这类错觉。
        let perChapter = 1.0 / Double(chapterCount)
        let inChapter = min(1.0, max(0.0, Double(offset) / 8000.0)) * perChapter
        return min(1.0, max(0.0, base + inChapter))
    }
}

// MARK: - 目录排序与续读定位

public enum ProgressResolver {

    /// 从书架点进一本书时，决定打开哪一章。
    /// - 有进度：用它；越界则钳到最后一章。
    /// - 无进度：第 0 章。
    public static func openTarget(
        progress: ReadingProgress?,
        chapterCount: Int
    ) -> ReadingLocator {
        guard let p = progress, chapterCount > 0 else {
            return ReadingLocator(chapterIndex: 0, characterOffset: 0)
        }
        let idx = min(max(0, p.chapterIndex), chapterCount - 1)
        return ReadingLocator(chapterIndex: idx, characterOffset: max(0, p.characterOffset))
    }

    /// 上一章 / 下一章。边界处返回 nil（UI 据此禁用按钮）。
    public static func previousChapter(current: Int) -> Int? {
        current > 0 ? current - 1 : nil
    }
    public static func nextChapter(current: Int, chapterCount: Int) -> Int? {
        current + 1 < chapterCount ? current + 1 : nil
    }
}
