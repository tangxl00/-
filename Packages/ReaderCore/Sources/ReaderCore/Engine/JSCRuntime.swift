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
//  脚本级超时（v1.2.0 修复）：evaluate() 把脚本投递到 jsQueue，调用方以信号量限时等待。
//  超时后**从等待方线程直接**把 context 置为 nil（而不是往排满死循环的 jsQueue 上再投递
//  一个任务——那种写法永远排在死循环之后，一次失控脚本会让 JS 永久不可用）。
//  下一次求值在 jsQueue 上看到 context == nil 就新建上下文，旧上下文随引用释放。
//  这是解释器无法安全中断 JS 的现实折衷：毒化的上下文被丢弃，运行时不进入永久失效态。
//
//  注意：本文件 #if canImport(JavaScriptCore) —— 沙箱 Linux 无 JavaScriptCore，
//  不参与 swift test 编译；跨平台逻辑（java 扩展、同步桥、超时）全部在
//  JSRuntime.swift 的纯 Swift 层，Linux 测试直接覆盖。
//
//  iOS 可用性约束（v1.2.0）：JSContext() 在不同平台签名不同——iOS 上 JSContext 的
//  初始化器返回非可选，macOS/Linux 上返回 Optional。因此这里统一用
//  `let ctx = JSContext()` 后接 `guard let` 收口成非可选绑定（两边都能编译）；
//  java 扩展的错误一律经「原生返回哨兵对象 → JS 包装层 throw」上抛，不写 ctx.exception。
//

import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore

public final class JSCRuntime: JSRuntime, @unchecked Sendable {
    private let jsQueue = DispatchQueue(label: "com.tingdu.jscruntime", qos: .userInitiated)
    private let bridge: JSJavaBridge
    private let scriptTimeout: TimeInterval

    /// 串行化「重建 / 取用上下文」与「超时置空」两侧的写操作。
    /// jsQueue 上的所有 JSContext 访问只在 jsQueue 线程执行；
    /// 这个锁只保护 `context` 这个引用本身（跨线程读写）。
    private let contextLock = NSLock()

    // 以下全部只在 jsQueue 上访问
    private var context: JSContext?
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
            // 脚本级超时：脚本可能仍在 jsQueue 线程上死循环。
            // 从当前线程直接把上下文引用置空——下一次求值会新建上下文，
            // 不会出现「投递的任务永远排在死循环后面、毒化标记永不生效」的问题。
            discardContext()
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

    /// 丢弃当前上下文（跨线程安全）。在 jsQueue 上调用时同样适用：
    /// 置空后下一次求值走 makeContext()。
    private func discardContext() {
        contextLock.lock()
        context = nil
        injectedJsLib = nil
        contextLock.unlock()
    }

    // MARK: - jsQueue 上执行

    private func evaluateOnQueue(_ script: String, bindings: JSBindings) throws -> Any? {
        // 超时后 context 已被置空：这里重建。锁只保护引用，不覆盖 JS 访问。
        contextLock.lock()
        let existing = context
        contextLock.unlock()

        let ctx: JSContext
        if let existing {
            ctx = existing
        } else {
            let fresh = try makeContext()
            contextLock.lock()
            context = fresh
            injectedJsLib = nil
            contextLock.unlock()
            ctx = fresh
        }
        currentBindings = bindings

        // ① jsLib 先于各规则注入（内容变化时重注入）
        if let lib = bindings.jsLib,
           !lib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           injectedJsLib != lib {
            _ = ctx.evaluateScript(lib)
            injectedJsLib = lib
        }

        // ② 重设 13 个全局绑定
        installGlobals(ctx, bindings)

        // ③ 执行脚本
        let value = ctx.evaluateScript(script)
        if let exception = ctx.exception {
            ctx.exception = nil
            throw JSRuntimeError.scriptError(exception.toString())
        }
        return convert(value)
    }

    // MARK: - 上下文构建

    /// 建上下文。失败抛 `JSRuntimeError.unimplemented`（此环境下无法创建 JSContext）。
    private func makeContext() throws -> JSContext {
        // 平台签名差异：JSContext() 在一部分 SDK 上导入为 `init?()`、另一部分导入为 `init()`。
        // 先赋给显式可选变量再 guard let —— 非可选返回值会被隐式提升，两种签名都能编译。
        let boxed: JSContext? = JSContext()
        guard let ctx = boxed else {
            throw JSRuntimeError.unimplemented
        }
        // 不装 exceptionHandler：脚本异常统一在 evaluateScript 之后读 ctx.exception 上报，
        // 这样既不依赖 exceptionHandler 闭包参数的平台快照，也不会出现两条上报通道互相覆盖。
        installJavaObject(ctx)
        installCookieObject(ctx)
        installCacheObject(ctx)
        // 沙箱基线：把顶层 this 暴露为 window（部分书源 jsLib 依赖 window）
        _ = ctx.evaluateScript("var window = this;")
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

    /// java 对象安装。
    ///
    /// 两个必须绕开的陷阱：
    ///   ① **block 元数**：为每个 java 方法各挂一个 `@convention(block) ([Any]) -> Any?`
    ///      会被 JSC 当成「元数 1 的 JS 函数」，JS 侧 `java.ajax(url, headers)` 的多余实参
    ///      直接丢失。因此这里只挂**一个**二元数的原生 block `__tingdu_invoke(name, args)`，
    ///      其余方法全部在 JS 侧用 `arguments` 收集后转发，参数个数与顺序都不受元数限制。
    ///   ② **错误上抛**：原生 block 设置 `ctx.exception` 不会把错误抛进 JS（JS 只拿到
    ///      `undefined`），而且 `ctx.exception` 会被下一次 evaluateScript 覆盖，错误彻底
    ///      消失（书源进入「取不到值也不报错」的半失效态）。这里让原生侧失败时返回带
    ///      哨兵键的对象，由 JS 包装层检测后 `throw new Error(...)`——错误串带 java 方法名。
    private func installJavaObject(_ ctx: JSContext) {
        // 形参用 JSValue（JSC 的 block 桥对 JSValue 形参/返回值是既定支持的形态），
        // 避免依赖 Swift `[Any]` → NSArray 的隐式桥接在 JSC 调用路径上的行为差异。
        let invoke: @convention(block) (String, JSValue) -> Any? = { [weak self] name, argsValue in
            guard let self else { return nil }
            let raw = argsValue.isArray ? (argsValue.toArray() ?? []) : []
            return self.callJavaFromJS(name, args: raw)
        }
        ctx.setObject(invoke, forKeyedSubscript: "__tingdu_invoke" as NSString)

        let methodsJSON = "[" + JSJavaBridge.implementedMethods.sorted()
            .map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let factoryScript = """
        (function() {
            var invoke = __tingdu_invoke;
            var implemented = \(methodsJSON);
            var api = {};
            implemented.forEach(function(name) {
                api[name] = function() {
                    var args = Array.prototype.slice.call(arguments);
                    var r = invoke(name, args);
                    if (r !== null && typeof r === 'object' && r.__tingduError !== undefined) {
                        throw new Error(String(r.__tingduError));
                    }
                    return r;
                };
            });
            return new Proxy(api, {
                get: function(obj, prop) {
                    if (typeof prop === 'string' && implemented.indexOf(prop) < 0) {
                        throw new Error("java." + prop + " 本版未实现（Tier C/未覆盖方法）");
                    }
                    return obj[prop];
                }
            });
        })()
        """
        if let proxied = ctx.evaluateScript(factoryScript), proxied.isObject {
            ctx.setObject(proxied, forKeyedSubscript: "java" as NSString)
        } else {
            // Proxy / 工厂脚本不可用时的兜底：把原生桥暴露成 java，调用方传错参数
            // 会直接失败而不是静默 undefined（错误可见优先于形状好看）。
            ctx.setObject(invoke, forKeyedSubscript: "java" as NSString)
        }
        _ = ctx.evaluateScript("delete this.__tingdu_invoke;")
    }

    /// 原生侧调度。失败时返回哨兵对象 `{"__tingduError": "java.xxx 调用失败：…"}`，
    /// 由 JS 包装层转为 `throw`（错误串带方法名，可归因到具体扩展方法）。
    private func callJavaFromJS(_ method: String, args: [Any]) -> Any? {
        let strings = args.map(Self.jsArgumentToString)
        do {
            let result = try bridge.call(method, strings, baseURL: currentBindings.baseUrl)
            return result.isEmpty ? "" : result
        } catch let e as JSRuntimeError {
            return NSDictionary(dictionary: ["__tingduError": "java.\(method) 调用失败：\(e.description)"])
        } catch {
            return NSDictionary(dictionary: ["__tingduError": "java.\(method) 调用失败：\(error.localizedDescription)"])
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
        let boxed: JSValue? = JSValue(newObjectIn: ctx)
        guard let cookie = boxed else { return }
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
        // cookie 的三个方法参数形态固定（getCookie/removeCookie 一元、setCookie 二元），
        // 直接用固定元数 block，无需走 java 的变参桥。
        cookie.setObject(getBlock, forKeyedSubscript: "getCookie" as NSString)
        cookie.setObject(setBlock, forKeyedSubscript: "setCookie" as NSString)
        cookie.setObject(removeBlock, forKeyedSubscript: "removeCookie" as NSString)
        ctx.setObject(cookie, forKeyedSubscript: "cookie" as NSString)
    }

    private func installCacheObject(_ ctx: JSContext) {
        let boxed: JSValue? = JSValue(newObjectIn: ctx)
        guard let cache = boxed else { return }
        let store = bridge.cache
        let getBlock: @convention(block) (String) -> Any? = { key in
            store.get(key).map { $0 as NSString } ?? NSNull()
        }
        let setBlock: @convention(block) (String, String) -> Void = { key, value in
            store.set(key, value)
        }
        cache.setObject(getBlock, forKeyedSubscript: "get" as NSString)
        cache.setObject(setBlock, forKeyedSubscript: "set" as NSString)
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
