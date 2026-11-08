//
//  RateLimiting.swift
//  ReaderCore
//
//  书源级 + 域名级限流（架构文档二·七、三·四、六·R3）。
//
//  concurrentRate 两种写法：
//    · "N/interval" —— interval 毫秒内最多 N 次
//    · 纯 "N"        —— 等价于 1/N，N 的单位是毫秒（即两次请求间隔 N 毫秒）
//  超限时不要硬等太久：这里用「滑动窗口 + 必要时 sleep」实现，
//  并且按域名做二级限速（同一站点多个书源时，避免叠加速度把站点打到封禁）。
//
//  实现方式：actor，按 key 维护「最近 N 次请求的时间戳」，
//  acquire 时算出需要等待的毫秒数，然后 await Task.sleep。
//  这样天然串行化同一 key 的并发请求节奏，且不会长时间占用 CPU。
//

import Foundation

// MARK: - 速率规格

public struct RateSpec: Sendable, Equatable {
    /// 窗口内允许的次数
    public var permits: Int
    /// 窗口长度（毫秒）
    public var windowMs: Int

    /// 解析 concurrentRate。
    /// - `"2/1000"` → 1000ms 内 2 次
    /// - `"500"`    → 每 500ms 1 次
    /// - 空 / 非法   → nil（不限速）
    public init?(raw: String?) {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.contains("/") {
            let parts = t.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let n = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let w = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  n > 0, w > 0 else { return nil }
            self.permits = n
            self.windowMs = w
        } else {
            guard let ms = Int(t), ms > 0 else { return nil }
            self.permits = 1
            self.windowMs = ms
        }
    }

    public init(permits: Int, windowMs: Int) {
        self.permits = max(1, permits)
        self.windowMs = max(1, windowMs)
    }

    /// 两次请求之间的最小间隔（毫秒），列表无业务含义，仅用于日志展示。
    public var minIntervalMs: Int { windowMs / max(1, permits) }
}

// MARK: - 限流器

/// 按 key 分桶的滑动窗口限流器。
/// 单例足够：限流是进程级事实，不应该由调用方各自持有。
public actor RateLimiter {
    public static let shared = RateLimiter()

    /// key → 最近请求时间戳（毫秒）
    private var stamps: [String: [Int64]] = [:]
    /// key → 规格
    private var specs: [String: RateSpec] = [:]

    /// 域名级默认限速（同一域名多个书源时的兜底）。
    /// 取 8 次/秒：既不给站点明显压力，也不至于让搜索慢到不可用。
    private let domainSpec = RateSpec(permits: 8, windowMs: 1000)

    public init() {}

    /// 登记一个书源规格。`sourceKey` 用 bookSourceUrl。
    public func register(sourceKey: String, spec: RateSpec?) {
        guard let spec else {
            specs.removeValue(forKey: sourceKey)
            return
        }
        specs[sourceKey] = spec
    }

    /// 域名二级桶的 key。
    private func domainKey(_ sourceKey: String) -> String? {
        guard let u = URL(string: sourceKey), let host = u.host else { return nil }
        return "domain:\(host)"
    }

    /// 申请一次配额。内部会等到「可以发」为止，然后记账。
    /// - Returns: 实际等待的毫秒数（便于上层日志 / 调试）
    @discardableResult
    public func acquire(sourceKey: String) async -> Int {
        var waited = 0

        // 书源桶
        if let spec = specs[sourceKey] {
            waited += await reserve(key: "src:\(sourceKey)", spec: spec)
        }
        // 域名桶
        if let dk = domainKey(sourceKey) {
            waited += await reserve(key: dk, spec: domainSpec)
        }
        return waited
    }

    /// 滑动窗口记账 + 等待。
    private func reserve(key: String, spec: RateSpec) async -> Int {
        var totalWait = 0
        var rounds = 0
        while true {
            let now = Self.nowMs()
            var list = stamps[key] ?? []
            // 丢掉窗口外的旧时间戳
            list.removeAll { now - $0 >= Int64(spec.windowMs) }
            if list.count < spec.permits {
                list.append(now)
                stamps[key] = list
                return totalWait
            }
            // 窗口满：等到最早那个时间戳过期
            let earliest = list.min() ?? now
            let waitMs = Int(Int64(spec.windowMs) - (now - earliest)) + 1
            let clamped = max(1, min(waitMs, 30_000))
            stamps[key] = list
            try? await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
            totalWait += clamped
            rounds += 1
            if rounds > 8 { return totalWait }   // 兜底：极端情况下不无限循环
        }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
