//
//  JSRuntime.swift
//  ReaderCore
//
//  JS 运行时协议（架构文档三·二）与 Tier B 支撑设施。
//
//  分层设计（为了让无 JavaScriptCore 的平台也能验证逻辑）：
//    · JSRuntime 协议 —— 求值入口，唯一参数是脚本 + 绑定 + 超时；
//    · JSCRuntime（Engine/JSCRuntime.swift，#if canImport(JavaScriptCore)）——
//      iOS/macOS 真实现：专用串行队列 + 单 JSContext（非线程安全，禁止并发进入）；
//      沙箱 Linux 无 JavaScriptCore，该文件不参与 Linux 编译；
//    · JSJavaBridge —— java 扩展的分发引擎（纯 Swift，Linux 可测），
//      含受限同步桥（SyncHTTPBridge：信号量等 URLSession，每次调用硬超时 8s）；
//    · UnsupportedJSRuntime —— 无运行时时的占位（调用即抛未实现）。
//
//  无 JIT 是既定事实（iOS 第三方 App 的 JavaScriptCore 只有 LLInt 解释器），
//  短脚本解释执行足够，不做任何性能前提假设。
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 绑定

/// 注入 JS 的绑定（对齐架构文档二·五的 13 个固定全局对象）。
/// JSCRuntime 据此绑定：java / cookie / cache / source / book / result / baseUrl /
/// chapter / title / src / nextChapterUrl / rssArticle / fromBookInfo。
public struct JSBindings: @unchecked Sendable {
    public var source: String        // 当前源原文（= src）
    public var result: String        // 上一段结果
    public var baseUrl: String
    public var bookName: String?
    public var bookAuthor: String?
    public var chapterTitle: String?
    public var nextChapterUrl: String?
    public var fromBookInfo: Bool
    /// 变量表快照（@get 可见）
    public var variables: [String: String]
    /// 书源 jsLib（先于各规则注入）
    public var jsLib: String?
    /// book 全量快照（绑定 book 全局对象用）
    public var book: BookSnapshot?
    /// chapter 全量快照（绑定 chapter 全局对象用）
    public var chapter: ChapterSnapshot?
    /// rssArticle 快照（RSS 源语境；Tier B 一般为 nil，绑定空对象）
    public var rssArticle: BookSnapshot?

    public init(source: String = "",
                result: String = "",
                baseUrl: String = "",
                bookName: String? = nil,
                bookAuthor: String? = nil,
                chapterTitle: String? = nil,
                nextChapterUrl: String? = nil,
                fromBookInfo: Bool = false,
                variables: [String: String] = [:],
                jsLib: String? = nil,
                book: BookSnapshot? = nil,
                chapter: ChapterSnapshot? = nil,
                rssArticle: BookSnapshot? = nil) {
        self.source = source
        self.result = result
        self.baseUrl = baseUrl
        self.bookName = bookName
        self.bookAuthor = bookAuthor
        self.chapterTitle = chapterTitle
        self.nextChapterUrl = nextChapterUrl
        self.fromBookInfo = fromBookInfo
        self.variables = variables
        self.jsLib = jsLib
        self.book = book
        self.chapter = chapter
        self.rssArticle = rssArticle
    }
}

// MARK: - 错误

public enum JSRuntimeError: Error, CustomStringConvertible, Sendable {
    case unimplemented
    case timeout
    case missingBinding(String)
    case scriptError(String)
    /// 调用了本版未实现的 java 扩展方法（必须带方法名，禁止静默返回 undefined）
    case missingMethod(String)
    /// 同步桥网络失败 / 网络硬超时（8s）
    case network(String)

    public var description: String {
        switch self {
        case .unimplemented: return "JS 运行时未接入"
        case .timeout: return "JS 执行超时"
        case .missingBinding(let n): return "JS 绑定的 java.\(n) 未实现"
        case .scriptError(let m): return "JS 执行错误：\(m)"
        case .missingMethod(let m):
            return "该步骤需要 JS 能力 java.\(m)，本版未实现"
        case .network(let m): return "JS 网络扩展失败：\(m)"
        }
    }
}

// MARK: - 协议

/// 架构文档三·二的 JSRuntime 协议。
/// 返回值：String / 数值 / 布尔 / [Any]（数组按行折算为文本列表）。
public protocol JSRuntime: AnyObject, Sendable {
    func evaluate(_ script: String, bindings: JSBindings, timeout: Duration) throws -> Any?
}

/// 无运行时占位：调用即抛「未实现」。
public final class UnsupportedJSRuntime: JSRuntime {
    public static let shared = UnsupportedJSRuntime()
    public init() {}

    public func evaluate(_ script: String, bindings: JSBindings, timeout: Duration) throws -> Any? {
        throw JSRuntimeError.unimplemented
    }
}

// MARK: - 受限同步桥（java.ajax 等网络类扩展）

public struct SyncHTTPRequest: Sendable {
    public var url: String
    public var method: String          // GET / POST / HEAD
    public var headers: [String: String]
    public var body: String?

    public init(url: String, method: String = "GET",
                headers: [String: String] = [:], body: String? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct SyncHTTPResponse: Sendable {
    public var statusCode: Int
    public var body: String
    public var finalURL: String
    public var headers: [String: String]

    public init(statusCode: Int, body: String, finalURL: String, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.finalURL = finalURL
        self.headers = headers
    }
}

/// 同步 HTTP 桥协议。真实现阻塞调用方线程（专用 JS 线程）直至完成或硬超时。
/// 协议化是为了 Linux 测试能注入假桥（慢响应模拟 8s 超时）。
public protocol SyncHTTPBridge: Sendable {
    /// 阻塞式请求。`hardTimeout` 为本次调用硬超时（秒），超时必须抛错返回，
    /// 绝不允许永久阻塞。
    func request(_ spec: SyncHTTPRequest, hardTimeout: TimeInterval) throws -> SyncHTTPResponse
}

/// 基于 URLSession + DispatchSemaphore 的同步桥（iOS / macOS / Linux 均可用）。
/// 注意：只能在专用线程上调用（JSCRuntime 的串行队列线程），不得在
/// Swift 并发协作线程上直接调用（会阻塞 cooperative pool）。
public final class SemaphoreSyncHTTPBridge: SyncHTTPBridge, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    public func request(_ spec: SyncHTTPRequest, hardTimeout: TimeInterval) throws -> SyncHTTPResponse {
        guard let url = URL(string: spec.url) else {
            throw JSRuntimeError.network("URL 非法：\(spec.url.prefix(80))")
        }
        var req = URLRequest(url: url)
        req.httpMethod = spec.method
        req.timeoutInterval = max(1, hardTimeout)
        if let b = spec.body { req.httpBody = b.data(using: .utf8) }
        for (k, v) in spec.headers { req.setValue(v, forHTTPHeaderField: k) }
        if spec.body != nil, req.value(forHTTPHeaderField: "Content-Type") == nil {
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
            var error: Error?
        }
        let box = Box()

        let task = session.dataTask(with: req) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }
        task.resume()

        // 硬超时：超时先 cancel 再抛错，绝不挂死
        let waitResult = semaphore.wait(timeout: .now() + max(0.1, hardTimeout))
        if waitResult == .timedOut {
            task.cancel()
            throw JSRuntimeError.network("java 网络扩展硬超时（\(Int(hardTimeout))s）：\(spec.method) \(spec.url.prefix(80))")
        }
        if let error = box.error {
            throw JSRuntimeError.network(error.localizedDescription)
        }
        guard let http = box.response as? HTTPURLResponse else {
            throw JSRuntimeError.network("非 HTTP 响应")
        }
        let text = TextDecoder.decodeResponse(box.data ?? Data(), charset: nil)
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JSRuntimeError.network("HTTP \(http.statusCode)（\(spec.method) \(spec.url.prefix(80))）")
        }
        return SyncHTTPResponse(
            statusCode: http.statusCode,
            body: text,
            finalURL: http.url?.absoluteString ?? spec.url,
            headers: headers
        )
    }
}

// MARK: - cookie / cache 存储（内存实现，进程内共享）

/// cookie 全局对象的存储。内存实现（Tier B：不落盘；跨源隔离按 URL host 归并，
/// 简化为按整 URL 存取 —— 命中不了再精确到 host 的场景极少，已在说明文档标注）。
public final class JSCookieStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func getCookie(_ url: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return storage[url] ?? ""
    }

    public func setCookie(_ url: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        storage[url] = value
    }

    public func removeCookie(_ url: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: url)
    }
}

/// cache 全局对象的存储（java 缓存语义：get/set，带可选过期）。
public final class JSCacheStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: (value: String, expiresAt: Date?)] = [:]

    public init() {}

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        if let exp = entry.expiresAt, Date() > exp {
            storage.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    public func set(_ key: String, _ value: String, lifetimeSeconds: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = (value, lifetimeSeconds.map { Date().addingTimeInterval($0) })
    }
}

// MARK: - java 扩展分发引擎（纯 Swift，Linux 可测）

/// java.xxx 调用的统一分发器。JSCRuntime 把 JS 侧调用转到这里的 `call`；
/// 测试直接驱动 `call` 验证 20 个方法的语义与缺项异常。
public final class JSJavaBridge: @unchecked Sendable {
    /// 本版已实现的 java 扩展方法（静态扫描能力清单的唯一事实源）。
    public static let implementedMethods: Set<String> = [
        // 网络
        "ajax", "connect", "head", "post",
        // 编解码
        "base64Encode", "base64Decode", "hexEncodeToString", "hexDecodeToString",
        "strToBytes", "bytesToStr", "encodeURI", "htmlFormat", "toURL",
        // 文本
        "t2s", "s2t", "toNumChapter", "timeFormat", "timeFormatUTC", "randomUUID",
        // 其它
        "toast", "log",
    ]

    public let network: SyncHTTPBridge
    public let cookies: JSCookieStore
    public let cache: JSCacheStore
    /// toast / log 的回调（App 层接 UI；默认 no-op）
    public var toastHandler: @Sendable (String) -> Void
    public var logHandler: @Sendable (String) -> Void
    /// 每次网络调用的硬超时（架构文档：8 秒）
    public var networkHardTimeout: TimeInterval

    public init(
        network: SyncHTTPBridge = SemaphoreSyncHTTPBridge(),
        cookies: JSCookieStore = JSCookieStore(),
        cache: JSCacheStore = JSCacheStore(),
        networkHardTimeout: TimeInterval = 8.0
    ) {
        self.network = network
        self.cookies = cookies
        self.cache = cache
        self.networkHardTimeout = networkHardTimeout
        self.toastHandler = { _ in }
        self.logHandler = { _ in }
    }

    /// 分发一次 java.xxx 调用。args 全部为字符串（JSCRuntime 负责 JSValue → String）。
    /// 未实现的方法抛 `JSRuntimeError.missingMethod`（带方法名，禁止静默失败）。
    public func call(
        _ method: String,
        _ args: [String],
        baseURL: String? = nil
    ) throws -> String {
        func arg(_ i: Int) -> String { i < args.count ? args[i] : "" }

        switch method {
        // ---- 网络（受限同步桥）----
        case "ajax":
            return try networkRequest(url: arg(0), method: "GET", headersJSON: arg(1)).body
        case "connect":
            return try networkRequest(url: arg(0), method: "GET", headersJSON: arg(1)).body
        case "head":
            _ = try networkRequest(url: arg(0), method: "HEAD", headersJSON: arg(1))
            return ""
        case "post":
            let headers = arg(1)
            return try networkRequest(url: arg(0), method: "POST", headersJSON: headers, body: arg(2)).body

        // ---- 编解码 ----
        case "base64Encode":
            return JavaExtensionCore.base64Encode(arg(0))
        case "base64Decode":
            return JavaExtensionCore.base64Decode(arg(0))
        case "hexEncodeToString":
            return JavaExtensionCore.hexEncodeToString(arg(0))
        case "hexDecodeToString":
            return JavaExtensionCore.hexDecodeToString(arg(0))
        case "strToBytes":
            return JavaExtensionCore.strToBytes(arg(0))
        case "bytesToStr":
            return JavaExtensionCore.bytesToStr(arg(0))
        case "encodeURI":
            return JavaExtensionCore.encodeURI(arg(0))
        case "htmlFormat":
            return JavaExtensionCore.htmlFormat(arg(0))
        case "toURL":
            return JavaExtensionCore.toURL(arg(0), baseURL: baseURL ?? arg(1))

        // ---- 文本 ----
        case "t2s":
            return ChineseConverter.toSimplified(arg(0))
        case "s2t":
            return ChineseConverter.toTraditional(arg(0))
        case "toNumChapter":
            return JavaExtensionCore.toNumChapter(arg(0))
        case "timeFormat":
            return JavaExtensionCore.timeFormat(arg(0), format: arg(1).isEmpty ? nil : arg(1), utc: false)
        case "timeFormatUTC":
            return JavaExtensionCore.timeFormat(arg(0), format: arg(1).isEmpty ? nil : arg(1), utc: true)
        case "randomUUID":
            return UUID().uuidString

        // ---- 其它 ----
        case "toast":
            toastHandler(arg(0))
            return ""
        case "log":
            logHandler(arg(0))
            return ""

        default:
            throw JSRuntimeError.missingMethod(method)
        }
    }

    private func networkRequest(
        url: String,
        method: String,
        headersJSON: String,
        body: String? = nil
    ) throws -> SyncHTTPResponse {
        var headers: [String: String] = [
            "User-Agent":
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        ]
        if !headersJSON.isEmpty, let j = JsonValue.parse(headersJSON), case .object(let o) = j {
            for (k, v) in o { headers[k] = v.text }
        }
        let spec = SyncHTTPRequest(url: url, method: method, headers: headers, body: body)
        return try network.request(spec, hardTimeout: networkHardTimeout)
    }
}

// MARK: - java 扩展的纯函数实现（可单测）

public enum JavaExtensionCore {

    public static func base64Encode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    public static func base64Decode(_ s: String) -> String {
        guard let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }
        return String(data: d, encoding: .utf8) ?? ""
    }

    public static func hexEncodeToString(_ s: String) -> String {
        s.utf8.map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDecodeToString(_ s: String) -> String {
        let chars = Array(s.trimmingCharacters(in: .whitespacesAndNewlines))
        var bytes: [UInt8] = []
        var i = 0
        while i + 1 < chars.count {
            if let b = UInt8(String(chars[i...i + 1]), radix: 16) {
                bytes.append(b)
            }
            i += 2
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// 字符串 → 字节数组。Tier B 返回逗号分隔的十进制字节串
    /// （JS 侧拿到的是字符串；与 bytesToStr 互补，已在说明文档标注为简化）。
    public static func strToBytes(_ s: String) -> String {
        s.utf8.map(String.init).joined(separator: ",")
    }

    /// 字节数组（"1,2,3" 或 JS 数组序列化形态）→ 字符串。
    public static func bytesToStr(_ s: String) -> String {
        let cleaned = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !cleaned.isEmpty else { return "" }
        let parts = cleaned.split(separator: ",")
        var bytes: [UInt8] = []
        for p in parts {
            if let b = UInt8(p.trimmingCharacters(in: .whitespaces)) { bytes.append(b) }
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// JS encodeURI 语义：保留 RFC3986 保留字与 unreserved，其余百分号编码。
    public static func encodeURI(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'();/?:@&=+$,")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// HTML 转义（& < > " ' → 实体）。
    public static func htmlFormat(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }

    /// 相对 URL 绝对化（基于当前规则求值的 baseUrl）。
    public static func toURL(_ url: String, baseURL: String?) -> String {
        URLResolution.absolute(url, base: baseURL)
    }

    /// 章节名中的中文数字转阿拉伯数字（"第十二章" → "第12章"）。
    public static func toNumChapter(_ s: String) -> String {
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "两": 2,
        ]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000, "亿": 100000000]

        // 找最长的一段「中文数字」连续子串
        let chars = Array(s)
        var best: (range: Range<Int>, value: Int)?
        var start: Int? = nil
        var i = 0
        while i <= chars.count {
            let isNumChar: Bool
            if i < chars.count {
                let c = chars[i]
                isNumChar = digits[c] != nil || units[c] != nil
            } else {
                isNumChar = false
            }
            if isNumChar {
                if start == nil { start = i }
                i += 1
                continue
            }
            if let st = start {
                let segment = chars[st..<i]
                // 至少含一个数字字符，且不全是一个"零"
                if let v = parseChineseNumber(Array(segment), digits: digits, units: units),
                   segment.count >= 1 {
                    if best == nil || (i - st) > (best!.range.count) {
                        best = (st..<i, v)
                    }
                }
                start = nil
            }
            i += 1
        }
        guard let b = best, b.value > 0 || chars[b.range].contains("零") else { return s }
        var out = ""
        for (idx, c) in chars.enumerated() {
            if b.range.contains(idx) { continue }
            out.append(c)
        }
        // 把数字插到原数字段起始位置
        let insertAt = out.index(out.startIndex, offsetBy: b.range.lowerBound)
        out.insert(contentsOf: String(b.value), at: insertAt)
        return out
    }

    private static func parseChineseNumber(_ chars: [Character],
                                           digits: [Character: Int],
                                           units: [Character: Int]) -> Int? {
        guard !chars.isEmpty else { return nil }
        var total = 0          // 亿/万 段累计
        var section = 0        // 当前段
        var current = 0        // 当前数字
        var sawDigit = false
        for c in chars {
            if let d = digits[c] {
                current = d
                sawDigit = true
            } else if let u = units[c] {
                if u >= 10000 {
                    section = (section + current) * u
                    total += section
                    section = 0
                    current = 0
                } else {
                    // "十"开头 = 一十（12 章 → 十二 = 12）
                    if current == 0 && !sawDigit { current = 1 }
                    section += current * u
                    current = 0
                    sawDigit = false
                }
            } else {
                return nil
            }
        }
        return total + section + current
    }

    /// 时间戳（秒或毫秒，>1e11 视为毫秒）→ 格式化字符串。
    public static func timeFormat(_ raw: String, format: String?, utc: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let t = Double(trimmed) else { return "" }
        let seconds = t > 1e11 ? t / 1000.0 : t
        let date = Date(timeIntervalSince1970: seconds)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = utc ? TimeZone(identifier: "UTC") : TimeZone.current
        df.dateFormat = format?.isEmpty == false ? format! : "yyyy-MM-dd HH:mm:ss"
        return df.string(from: date)
    }
}
