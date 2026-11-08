//
//  URLTemplate+Convenience.swift
//  ReaderCore
//
//  不带 EvalContext 的便捷入口。搜索 URL 的 query 参数里若只有 `{{key}}`/`{{page}}`
//  这类纯变量替换，不需要 DOM 上下文；但书源也可能写成 `?q=@text` 这种规则，
//  所以仍需要一个「空源」上下文兜底（此时规则求值结果为空，不会崩）。
//

import Foundation

public extension URLTemplateEngine {
    /// 仅给变量的便捷分析。
    static func analyze(
        template: String,
        vars: [String: String],
        evaluator: RuleEvaluator = RuleEvaluator()
    ) throws -> AnalyzedUrl {
        let ctx = EvalContext(
            source: EvalSource.text(""),
            variables: VariableStore(vars)
        )
        return try analyze(template: template, vars: vars, evaluator: evaluator, ctx: ctx)
    }
}
