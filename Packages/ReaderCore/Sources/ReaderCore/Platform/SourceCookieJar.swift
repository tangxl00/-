//
//  SourceCookieJar.swift
//  ReaderCore
//
//  P1-12（v1.2.0）：按书源隔离的 Cookie 罐。
//
//  旧实现把 URLSession 挂在 HTTPCookieStorage.shared 上且 acceptPolicy=.always，
//  所有书源共用系统级持久 Cookie：A 站的登录态会随请求发给 B 站（跨源凭据泄漏），
//  enabledCookieJar 字段被解码但无任何消费点。
//
//  本实现：
//    · 内存主存：[sourceKey: [HTTPCookie]]，NSLock 保护，按书源完全隔离。
//    · 请求注入：send() 前按 (sourceKey, URL host/path) 匹配生成 Cookie 头；
//      请求头已显式带 Cookie 时不覆盖。
//    · 响应收集：从 Set-Cookie 响应头解析后写入该 sourceKey 的桶（同名同域同路径覆盖）。
//    · 持久化：仅当书源 enabledCookieJar == true 时（persist 透传）写入 UserDefaults；
//      false = 会话级（进程内存，重启即清）。对齐 legado「enabledCookieJar = 持久化开关」语义。
//    · 系统共享罐不再使用：URLSessionTransport 默认禁用自动 Cookie 处理。
//
//  已知限制（已在《实现说明》登记）：[String: String] 响应头无法保留同名多值
//  Set-Cookie 的每一条，多 Cookie 响应可能被合并；域内基础反爬场景（单 Cookie）不受影响。
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class SourceCookieJar: @unchecked Sendable {
    /// 全局共享实例（App 与传输层共用）。带 UserDefaults 持久化能力，
    /// 但只有 persist == true（书源 enabledCookieJar）的写入会落盘。
    public static let shared: SourceCookieJar = SourceCookieJar(defaults: UserDefaults.standard)

    private let lock = NSLock()
    private var storage: [String: [HTTPCookie]]
    private let defaults: UserDefaults?
    private let keyPrefix: String

    /// 持久化用 Codable 快照（HTTPCookie 本身不是 Codable）。
    private struct PersistedCookie: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Double?

        init(_ c: HTTPCookie) {
            name = c.name; value = c.value; domain = c.domain; path = c.path
            expires = c.expiresDate?.timeIntervalSince1970
        }

        var cookie: HTTPCookie? {
            let props: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
                .expires: expires.map { Date(timeIntervalSince1970: $0) } as Any,
            ]
            return HTTPCookie(properties: props)
        }
    }

    public init(defaults: UserDefaults? = nil, keyPrefix: String = "td.sourceCookies") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        var loaded: [String: [HTTPCookie]] = [:]
        if let defaults {
            let prefix = keyPrefix + "."
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                let sourceKey = String(key.dropFirst(prefix.count))
                guard !sourceKey.isEmpty,
                      let data = defaults.data(forKey: key),
                      let list = try? JSONDecoder().decode([PersistedCookie].self, from: data)
                else { continue }
                loaded[sourceKey] = list.compactMap(\.cookie)
            }
        }
        self.storage = loaded
    }

    // MARK: - 读（生成 Cookie 请求头）

    /// 按 (sourceKey, URL) 匹配出 Cookie 请求头的值；无匹配返回 nil。
    public func cookieHeader(sourceKey: String, url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let bucket = storage[sourceKey], !bucket.isEmpty else { return nil }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let matched = bucket.filter { Self.matches($0, host: host, path: path) }
        guard !matched.isEmpty else { return nil }
        return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - 写（收集 Set-Cookie）

    /// 从响应头收集 Set-Cookie 并写入 sourceKey 桶；persist 时同步落盘。
    public func store(responseHeaders: [String: String], url: URL, sourceKey: String, persist: Bool) {
        var parsed: [HTTPCookie] = []
        for (k, v) in responseHeaders where k.lowercased() == "set-cookie" {
            parsed.append(contentsOf: HTTPCookie.cookies(withResponseHeaderFields: [k: v], for: url))
        }
        guard !parsed.isEmpty else { return }

        lock.lock(); defer { lock.unlock() }
        var bucket = storage[sourceKey] ?? []
        for cookie in parsed {
            bucket.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if let exp = cookie.expiresDate, exp < Date() { continue } // 过期 = 删除语义
            bucket.append(cookie)
        }
        storage[sourceKey] = bucket
        if persist, let defaults {
            let data = (try? JSONEncoder().encode(bucket.map(PersistedCookie.init))) ?? Data()
            defaults.set(data, forKey: keyPrefix + "." + sourceKey)
        }
    }

    // MARK: - 清理

    public func clear(sourceKey: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: sourceKey)
        defaults?.removeObject(forKey: keyPrefix + "." + sourceKey)
    }

    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        let keys = Array(storage.keys)
        storage = [:]
        for k in keys { defaults?.removeObject(forKey: keyPrefix + "." + k) }
    }

    /// 调试 / 测试用：某源当前持有的 Cookie 数。
    public func count(sourceKey: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storage[sourceKey]?.count ?? 0
    }

    // MARK: - 匹配（RFC 6265 简化：domain / path / 过期）

    static func matches(_ cookie: HTTPCookie, host: String, path: String) -> Bool {
        let domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") {
            // 子域通配：.example.com 匹配 example.com 与 a.example.com
            let bare = String(domain.dropFirst())
            guard host == bare || host.hasSuffix(domain) else { return false }
        } else {
            guard host == domain else { return false }
        }
        let cpath = cookie.path.isEmpty ? "/" : cookie.path
        guard path.hasPrefix(cpath) else { return false }
        if let exp = cookie.expiresDate, exp < Date() { return false }
        return true
    }
}
