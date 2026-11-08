//
//  HTTPClient.swift
//  ReaderCore
//
//  网络层。三件事：
//    1. 请求构造：把 `UrlOption`（method/headers/body/charset/retry/dnsIp）落到真实请求上。
//    2. 限速：先过 `RateLimiter`（书源桶 + 域名二级桶），再发。
//    3. 重试：`retry` 次指数退避，仅对「可重试错误」（网络错误 / 5xx / 429）重试，
//       4xx（除 429）不重试 —— 重试 404 只会白等。
//
//  设计成 `HTTPTransport` 协议是为了让测试能注入假 transport，
//  在 Linux 沙箱里不联网也能验证重试/限速/解码链路。
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 错误

public enum HTTPError: Error, Sendable, CustomStringConvertible {
    case badURL(String)
    case invalidResponse
    case status(Int, url: String)
    case transport(String)
    case cancelled
    case timeout(seconds: Int)

    public var description: String {
        switch self {
        case .badURL(let s): return "URL 非法：\(s)"
        case .invalidResponse: return "响应非法（非 HTTP 响应）"
        case .status(let code, let url): return "HTTP \(code)（\(url)）"
        case .transport(let msg): return "网络错误：\(msg)"
        case .cancelled: return "请求已取消"
        case .timeout(let s): return "请求超时（\(s)s）"
        }
    }
}

// MARK: - 请求 / 响应

public struct HTTPRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var charset: String?
    public var timeoutSeconds: Int
    public var retry: Int
    public var dnsIp: String?
    /// 授权书源身份（用于限速分桶 + P1-12 按源 Cookie 隔离）
    public var sourceKey: String?
    /// P1-12（v1.2.0）：该请求的 Cookie 是否允许持久化（= 书源 enabledCookieJar）。
    /// 无论真假，Cookie 都按 sourceKey 隔离存放；true 才会落盘。
    public var cookieJarEnabled: Bool

    public init(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        charset: String? = nil,
        timeoutSeconds: Int = 60,
        retry: Int = 0,
        dnsIp: String? = nil,
        sourceKey: String? = nil,
        cookieJarEnabled: Bool = false
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.charset = charset
        self.timeoutSeconds = timeoutSeconds
        self.retry = retry
        self.dnsIp = dnsIp
        self.sourceKey = sourceKey
        self.cookieJarEnabled = cookieJarEnabled
    }

    /// 从 `AnalyzedUrl` 构造。
    /// - Note: `dnsIp` 在 P0 只登记不生效（需要自定义 DNS 解析，涉及底层 socket API，
    ///   在 iOS 上要靠 `URLSessionTaskDelegate` + `CFStream`，P0 不做）。
    ///   这里保留字段是为了让书源解析不丢信息，并在日志里提示「已忽略 dnsIp」。
    public init(
        analyzed: AnalyzedUrl,
        sourceKey: String?,
        defaultHeaders: [String: String] = [:],
        cookieJarEnabled: Bool = false
    ) {
        var h = defaultHeaders
        if let extra = analyzed.option.headers {
            for (k, v) in extra { h[k] = v }
        }
        var body: Data? = nil
        if let b = analyzed.option.body, !b.isEmpty {
            body = b.data(using: .utf8)
            if h["Content-Type"] == nil, analyzed.isPost {
                h["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
            }
        }
        self.init(
            url: analyzed.url,
            method: analyzed.isPost ? "POST" : "GET",
            headers: h,
            body: body,
            charset: analyzed.option.charset,
            timeoutSeconds: 60,
            retry: max(0, analyzed.option.retry ?? 0),
            dnsIp: analyzed.option.dnsIp,
            sourceKey: sourceKey,
            cookieJarEnabled: cookieJarEnabled
        )
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var data: Data
    /// 已按 charset 解码的文本
    public var text: String
    /// 跟随重定向后的最终 URL（相对 URL 绝对化要用它做 base）
    public var finalURL: String
    public var headers: [String: String]
    /// 实际尝试次数（含首次）
    public var attempts: Int

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    public init(
        statusCode: Int,
        data: Data,
        text: String,
        finalURL: String,
        headers: [String: String] = [:],
        attempts: Int = 1
    ) {
        self.statusCode = statusCode
        self.data = data
        self.text = text
        self.finalURL = finalURL
        self.headers = headers
        self.attempts = attempts
    }
}

// MARK: - 可注入的传输层

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> (statusCode: Int, data: Data, finalURL: String, headers: [String: String])
}

/// 基于 URLSession 的真实实现。iOS / macOS / Linux(swift-corelibs) 都可用。
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage?
    /// P1-12（v1.2.0）：按书源隔离的 Cookie 罐（默认 .shared；测试可注入独立实例）。
    private let cookieJar: SourceCookieJar

    /// P1-12 修复：cookieStorage 默认 nil——不再挂系统共享罐
    /// （旧实现所有书源共用 HTTPCookieStorage.shared，A 站登录态会发给 B 站）。
    /// 显式传入 cookieStorage 时保留旧行为（测试兼容）。
    public init(
        configuration: URLSessionConfiguration = .default,
        cookieStorage: HTTPCookieStorage? = nil,
        protocolClasses: [AnyClass] = [],
        cookieJar: SourceCookieJar = .shared
    ) {
        let cfg = configuration
        cfg.httpCookieStorage = cookieStorage
        if cookieStorage != nil {
            cfg.httpCookieAcceptPolicy = .always
            cfg.httpShouldSetCookies = true
        } else {
            // 系统自动 Cookie 处理关闭，统一走 SourceCookieJar 手工注入
            cfg.httpCookieAcceptPolicy = .never
            cfg.httpShouldSetCookies = false
        }
        if !protocolClasses.isEmpty { cfg.protocolClasses = protocolClasses }
        self.cookieStorage = cookieStorage
        self.cookieJar = cookieJar
        self.session = URLSession(configuration: cfg)
    }

    public func send(_ request: HTTPRequest) async throws
        -> (statusCode: Int, data: Data, finalURL: String, headers: [String: String])
    {
        guard let url = URL(string: request.url) else { throw HTTPError.badURL(request.url) }
        var req = URLRequest(url: url)
        req.httpMethod = request.method
        req.timeoutInterval = TimeInterval(request.timeoutSeconds)
        req.httpBody = request.body
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }

        // P1-12：按书源注入 Cookie（请求头已显式带 Cookie 时不覆盖）
        if cookieStorage == nil, let sourceKey = request.sourceKey,
           let header = cookieJar.cookieHeader(sourceKey: sourceKey, url: url),
           req.value(forHTTPHeaderField: "Cookie") == nil {
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
            }
            // P1-12：收集 Set-Cookie 到该书源的桶（enabledCookieJar=true 才落盘）
            if cookieStorage == nil, let sourceKey = request.sourceKey {
                let finalURL = http.url ?? url
                cookieJar.store(
                    responseHeaders: headers,
                    url: finalURL,
                    sourceKey: sourceKey,
                    persist: request.cookieJarEnabled
                )
            }
            return (http.statusCode, data, http.url?.absoluteString ?? request.url, headers)
        } catch let e as HTTPError {
            throw e
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw HTTPError.timeout(seconds: request.timeoutSeconds)
            case .cancelled: throw HTTPError.cancelled
            default: throw HTTPError.transport(e.localizedDescription)
            }
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
    }
}

// MARK: - 客户端

/// 网络门面：限速 → 传输 → 重试 → 解码。
public struct HTTPClient: Sendable {
    public let transport: HTTPTransport
    public var limiter: RateLimiter
    /// 默认请求头（UA 等）。legado 默认 UA 是 OkHttp 的，这里用一个中立桌面 UA，
    /// 避免被部分站点按「非浏览器」直接拒绝。
    public var defaultHeaders: [String: String]
    /// 重试退避基数（毫秒），第 n 次重试等待 base * 2^(n-1)
    public var retryBaseDelayMs: Int

    public init(
        transport: HTTPTransport = URLSessionTransport(),
        limiter: RateLimiter = .shared,
        defaultHeaders: [String: String] = HTTPClient.defaultUserHeaders,
        retryBaseDelayMs: Int = 400
    ) {
        self.transport = transport
        self.limiter = limiter
        self.defaultHeaders = defaultHeaders
        self.retryBaseDelayMs = retryBaseDelayMs
    }

    public static let defaultUserHeaders: [String: String] = [
        "User-Agent":
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    ]

    /// 发一次请求，内部完成限速与重试。
    public func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard !request.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPError.badURL(request.url)
        }
        var req = request
        for (k, v) in defaultHeaders where req.headers[k] == nil { req.headers[k] = v }

        var attempt = 0
        var lastError: Error = HTTPError.invalidResponse
        let total = max(0, req.retry) + 1

        while attempt < total {
            attempt += 1
            if let key = req.sourceKey {
                _ = await limiter.acquire(sourceKey: key)
            }
            do {
                let r = try await transport.send(req)
                if (200..<300).contains(r.statusCode) {
                    let text = TextDecoder.decodeResponse(r.data, charset: req.charset)
                    return HTTPResponse(
                        statusCode: r.statusCode,
                        data: r.data,
                        text: text,
                        finalURL: r.finalURL,
                        headers: r.headers,
                        attempts: attempt
                    )
                }
                // 5xx / 429 可重试；其余 4xx 立即失败
                if !Self.isRetryableStatus(r.statusCode) {
                    throw HTTPError.status(r.statusCode, url: r.finalURL)
                }
                lastError = HTTPError.status(r.statusCode, url: r.finalURL)
            } catch let e as HTTPError {
                if case .status(let code, _) = e, !Self.isRetryableStatus(code) { throw e }
                if case .cancelled = e { throw e }
                if case .badURL = e { throw e }
                lastError = e
            } catch {
                lastError = HTTPError.transport(error.localizedDescription)
            }

            if attempt < total {
                let delay = retryBaseDelayMs * (1 << (attempt - 1))
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay)) * 1_000_000)
            }
        }
        throw lastError
    }

    /// 便捷：按 URL+选项直接取。
    public func fetch(
        analyzed: AnalyzedUrl,
        sourceKey: String?,
        cookieJarEnabled: Bool = false
    ) async throws -> HTTPResponse {
        try await fetch(HTTPRequest(
            analyzed: analyzed,
            sourceKey: sourceKey,
            cookieJarEnabled: cookieJarEnabled
        ))
    }

    static func isRetryableStatus(_ code: Int) -> Bool {
        code == 429 || (500..<600).contains(code)
    }
}
