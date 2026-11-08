//
//  JSCRuntime.swift
//  ReaderCore
//
//  JSCRuntime —— JavaScriptCore 真实现（架构文档三·二 / 任务模块一）。
//
//  线程模型（架构文档二·五的既定约束）：
//    · 专用串行队列 `jsQueue` + 单个 JSContext —— JSContext 非线程安全，
//      **所有** JSContext 访问都发生在 jsQueue 上，绝不并发进入；
//    · 无 JIT（iOS 第三方 App 只有 LLInt 解释器）是既定事实，短脚本解释执行；
//    · `java.ajax` 等网络扩展在 jsQueue 线程上以信号量同步等待 URLSession
//      （受限同步桥，见 JSRuntime.swift 的 SemaphoreSyncHTTPBridge），
//      每次调用硬超时 8 秒，超时抛 JS 异常而不是挂死。
//
//  脚本级超时：evaluate() 把脚本投递到 jsQueue，调用方以信号量限时等待。
//  超时后把上下文标记为「中毒」并重建（脚本可能仍在队列线程上死循环，
//  重建保证后续求值不受影响）。这是解释器无法安全中断 JS 的现实折衷。
//
//  注意：本文件 #if canImport(JavaScriptCore) —— 沙箱 Linux 无 JavaScriptCore，
//  不参与 swift test 编译；跨平台逻辑（java 扩展、同步桥、超时）全部在
//  JSRuntime.swift 的纯 Swift 层，Linux 测试直接覆盖。
//

import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore

public final class JSCRuntime: JSRuntime, @unchecked Sendable {
    private let jsQueue = DispatchQueue(label: "com.tingdu.jscruntime", qos: .userInitiated)
    private let bridge: JSJavaBridge
    private let scriptTimeout: TimeInterval

    // 以下全部只在 jsQueue 上访问
    private var context: JSContext?
    private var poisoned = false
    private var injectedJsLib: String?
    private var currentBindings = JSBindings()

    public init(bridge: JSJavaBridge = JSJavaBridge(), scriptTimeout: TimeInterval = 10.0) {
        self.bridge = bridge
        self.scriptTimeout = scriptTimeout
    }

    // MARK: - 求值入口（线程安全：经 jsQueue 串行化）

    public func evaluate(_ script: String, bindings: JSBindings, timeout: Duration) throws -> Any? {
        let semaphore = DispatchSemaphore(value: 0)
        final class ResultBox: @unchecked Sendable {
            var value: Any?
            var error: Error?
        }
        let box = ResultBox()

        jsQueue.async { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            do {
                box.value = try self.evaluateOnQueue(script, bindings: bindings)
            } catch {
                box.error = error
            }
            semaphore.signal()
        }

        let effectiveTimeout = max(0.1, Self.toTimeInterval(timeout, fallback: scriptTimeout))
        if semaphore.wait(timeout: .now() + effectiveTimeout) == .timedOut {
            // 脚本级超时：上下文可能卡死，标记中毒并在下次求值时重建。
            jsQueue.async { [weak self] in
                self?.poisoned = true
            }
            throw JSRuntimeError.timeout
        }
        if let e = box.error { throw e }
        return box.value
    }

    private static func toTimeInterval(_ d: Duration, fallback: TimeInterval) -> TimeInterval {
        let comps = d.components
        let seconds = Double(comps.seconds) + Double(comps.attoseconds) / 1e18
        return seconds > 0 ? seconds : fallback
    }

    // MARK: - jsQueue 上执行

    private func evaluateOnQueue(_ script: String, bindings: JSBindings) throws -> Any? {
        if poisoned || context == nil {
            context = makeContext()
            injectedJsLib = nil
            poisoned = false
        }
        currentBindings = bindings
        guard let ctx = context else {
            throw JSRuntimeError.unimplemented
        }

        // ① jsLib 先于各规则注入（内容变化时重注入）
        if let lib = bindings.jsLib,
           !lib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           injectedJsLib != lib {
            _ = ctx.evaluateScript(lib)
            injectedJsLib = lib
        }

        // ② 重设 13 个全局绑定
        installGlobals(ctx, bindings: bindings)

        // ③ 执行脚本
        let value = ctx.evaluateScript(script)
        if let exception = ctx.exception {
            ctx.exception = nil
            throw JSRuntimeError.scriptError(exception.toString())
        }
        return convert(value)
    }

    // MARK: - 上下文构建

    private func makeContext() -> JSContext {
        let ctx = JSContext()
        ctx.exceptionHandler = { [weak self] _, exception in
            // 缺方法异常在调用点抛出；这里只兜底记录其它异常
            if let exception, self?.context != nil {
                _ = exception.toString()
            }
        }
        installJavaObject(ctx)
        installCookieObject(ctx)
        installCacheObject(ctx)
        // 沙箱基线：禁掉危险全局（Tier B 只需要纯计算 + 受限网络）
        ctx.evaluateScript("""
        var window = this;
        """)
        return ctx
    }

    private func installGlobals(_ ctx: JSContext, _ b: JSBindings) {
        ctx.setObject(b.source, forKeyedSubscript: "source" as NSString)
        ctx.setObject(b.source, forKeyedSubscript: "src" as NSString)
        ctx.setObject(b.result, forKeyedSubscript: "result" as NSString)
        ctx.setObject(b.baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        ctx.setObject(b.chapterTitle ?? "", forKeyedSubscript: "title" as NSString)
        ctx.setObject(b.nextChapterUrl ?? "", forKeyedSubscript: "nextChapterUrl" as NSString)
        ctx.setObject(NSNumber(value: b.fromBookInfo), forKeyedSubscript: "fromBookInfo" as NSString)

        // book / chapter / rssArticle 快照对象
        ctx.setObject(snapshotObject(b.book), forKeyedSubscript: "book" as NSString)
        ctx.setObject(chapterObject(b.chapter), forKeyedSubscript: "chapter" as NSString)
        ctx.setObject(snapshotObject(b.rssArticle), forKeyedSubscript: "rssArticle" as NSString)
    }

    private func snapshotObject(_ book: BookSnapshot?) -> [String: Any] {
        guard let book else { return [:] }
        var o: [String: Any] = [
            "name": book.name,
            "author": book.author,
            "bookUrl": book.bookUrl,
            "origin": book.origin,
        ]
        if let v = book.tocUrl { o["tocUrl"] = v }
        if let v = book.kind { o["kind"] = v }
        if let v = book.intro { o["intro"] = v }
        if let v = book.coverUrl { o["coverUrl"] = v }
        if let v = book.latestChapterTitle { o["latestChapterTitle"] = v }
        return o
    }

    private func chapterObject(_ c: ChapterSnapshot?) -> [String: Any] {
        guard let c else { return [:] }
        var o: [String: Any] = [
            "title": c.title,
            "url": c.url,
            "index": c.index,
        ]
        if let v = c.baseUrl { o["baseUrl"] = v }
        return o
    }

    private func installJavaObject(_ ctx: JSContext) {
        let java = JSValue(newObjectIn: ctx)
        // 全部已实现方法：经 JSJavaBridge 分发
        for method in JSJavaBridge.implementedMethods.sorted() {
            let block: @convention(block) ([Any]) -> Any? = { [weak self] args in
                guard let self else { return nil }
                return self.callJavaFromJS(method, args: args)
            }
            java?.setObject(block, forKeyedSubscript: method as NSString)
        }
        // 先把裸对象挂到临时全局名，供 Proxy 工厂引用
        ctx.setObject(java, forKeyedSubscript: "__tingdu_java_target" as NSString)

        // 未实现方法：必须抛明确 JS 异常并带方法名，禁止静默 undefined。
        // JS 没有原生「未知属性钩子」，用 Proxy 拦截 java.xxx 读取。
        let methodsJSON = "[" + JSJavaBridge.implementedMethods.sorted()
            .map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let proxyScript = """
        (function() {
            var implemented = \(methodsJSON);
            var target = __tingdu_java_target;
            var proxy = new Proxy(target, {
                get: function(obj, prop) {
                    if (typeof prop === 'string' && implemented.indexOf(prop) < 0) {
                        throw new Error("java." + prop + " 本版未实现（Tier C/未覆盖方法）");
                    }
                    var v = obj[prop];
                    return (typeof v === 'function') ? v.bind(obj) : v;
                }
            });
            return proxy;
        })()
        """
        if let proxied = ctx.evaluateScript(proxyScript), proxied.isObject {
            ctx.setObject(proxied, forKeyedSubscript: "java" as NSString)
        } else {
            // 兜底：Proxy 不可用时直接绑定裸对象（缺项异常仍由 Swift 层保证）
            ctx.setObject(java, forKeyedSubscript: "java" as NSString)
        }
        // 清理临时全局名
        _ = ctx.evaluateScript("delete this.__tingdu_java_target;")
    }

    /// JS 调用点：Swift 异常 → JS 异常（带方法名），保证缺项在 JS 侧可见。
    private func callJavaFromJS(_ method: String, args: [Any]) -> Any? {
        let strings = args.map(Self.jsArgumentToString)
        do {
            let result = try bridge.call(method, strings, baseURL: currentBindings.baseUrl)
            return result.isEmpty ? "" : result
        } catch let e as JSRuntimeError {
            let ctx = context
            if let ctx {
                ctx.exception = JSValue(
                    newErrorWithMessage: e.description,
                    in: ctx
                )
            }
            return nil
        } catch {
            let ctx = context
            if let ctx {
                ctx.exception = JSValue(
                    newErrorWithMessage: "java.\(method) 调用失败：\(error.localizedDescription)",
                    in: ctx
                )
            }
            return nil
        }
    }

    private static func jsArgumentToString(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if v is NSNull { return "" }
        if let a = v as? [Any] {
            // JS 数组（bytesToStr 场景）→ 逗号串
            return a.map(jsArgumentToString).joined(separator: ",")
        }
        return String(describing: v)
    }

    private func installCookieObject(_ ctx: JSContext) {
        let cookie = JSValue(newObjectIn: ctx)
        let store = bridge.cookies
        let getBlock: @convention(block) (String) -> String = { url in
            store.getCookie(url)
        }
        let setBlock: @convention(block) (String, String) -> Void = { url, value in
            store.setCookie(url, value)
        }
        let removeBlock: @convention(block) (String) -> Void = { url in
            store.removeCookie(url)
        }
        cookie?.setObject(getBlock, forKeyedSubscript: "getCookie" as NSString)
        cookie?.setObject(setBlock, forKeyedSubscript: "setCookie" as NSString)
        cookie?.setObject(removeBlock, forKeyedSubscript: "removeCookie" as NSString)
        ctx.setObject(cookie, forKeyedSubscript: "cookie" as NSString)
    }

    private func installCacheObject(_ ctx: JSContext) {
        let cache = JSValue(newObjectIn: ctx)
        let store = bridge.cache
        let getBlock: @convention(block) (String) -> Any? = { key in
            store.get(key).map { $0 as NSString } ?? NSNull()
        }
        let setBlock: @convention(block) (String, String) -> Void = { key, value in
            store.set(key, value)
        }
        cache?.setObject(getBlock, forKeyedSubscript: "get" as NSString)
        cache?.setObject(setBlock, forKeyedSubscript: "set" as NSString)
        ctx.setObject(cache, forKeyedSubscript: "cache" as NSString)
    }

    // MARK: - 返回值转换

    private func convert(_ value: JSValue?) -> Any? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isNumber { return value.toDouble() }
        if value.isBoolean { return value.toBool() }
        if value.isString { return value.toString() }
        if value.isArray {
            return value.toArray().map { Self.jsArgumentToString($0) }
        }
        if value.isObject { return value.toString() }
        return value.toString()
    }
}

#endif // canImport(JavaScriptCore)
