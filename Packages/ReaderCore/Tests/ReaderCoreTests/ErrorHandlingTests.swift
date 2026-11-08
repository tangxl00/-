import XCTest
@testable import ReaderCore

/// 统一错误口径：jsUnsupported 绝不静默返回空串。
final class ErrorHandlingTests: XCTestCase {

    func testJsUnsupportedErrorHasMessage() {
        let e = RuleEvalError.jsUnsupported("@js")
        XCTAssertTrue(String(describing: e).contains("不支持") || String(describing: e).contains("JS"))
    }

    func testSelectorFailedErrorHasMessage() {
        let e = RuleEvalError.selectorFailed("boom")
        XCTAssertTrue(String(describing: e).contains("boom"))
    }

    func testRecursionLimitDescription() {
        let e = RuleEvalError.recursionLimit
        XCTAssertFalse(String(describing: e).isEmpty)
    }
}
