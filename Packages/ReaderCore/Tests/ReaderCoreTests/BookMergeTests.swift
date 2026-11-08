import XCTest
@testable import ReaderCore

/// 四桶合并。对应需求 2-9 / 架构文档三·四。
final class BookMergeTests: XCTestCase {

    private func item(
        _ name: String, _ author: String, origin: String,
        kind: String? = nil, intro: String? = nil
    ) -> SearchResultItem {
        SearchResultItem(
            name: name, author: author, bookUrl: "https://\(origin)/b/\(name)",
            origin: origin, originName: "源\(origin)",
            coverUrl: nil, intro: intro, kind: kind
        )
    }

    // MARK: - 桶判定

    func testBucketExactNameMatch() {
        XCTAssertEqual(BookMerger.bucket(item: item("三体", "刘慈欣", origin: "a"), keyword: "三体"), .exact)
    }

    func testBucketExactAuthorMatch() {
        XCTAssertEqual(BookMerger.bucket(item: item("任意书名", "刘慈欣", origin: "a"), keyword: "刘慈欣"), .exact)
    }

    func testBucketExactIsCaseAndSpaceInsensitive() {
        // 归一化后（全半角空白折叠、大小写）仍算精确
        let it = SearchResultItem(name: "The Three Body Problem", author: "X", bookUrl: "u", origin: "a", originName: "a")
        XCTAssertEqual(BookMerger.bucket(item: it, keyword: "the three body problem"), .exact)
    }

    func testBucketCategoryKindContains() {
        XCTAssertEqual(BookMerger.bucket(item: item("超新星纪元", "刘", origin: "a", kind: "科幻 三体宇宙"), keyword: "三体"), .category)
    }

    func testBucketContainsNameContains() {
        XCTAssertEqual(BookMerger.bucket(item: item("三体Ⅱ·黑暗森林", "刘慈欣", origin: "a"), keyword: "三体"), .contains)
    }

    func testBucketOther() {
        XCTAssertEqual(BookMerger.bucket(item: item("流浪地球", "刘慈欣", origin: "a"), keyword: "三体"), .other)
    }

    func testBucketIntroHitIsOther() {
        // 简介命中不算包含（需求把它排在包含之后）
        XCTAssertEqual(
            BookMerger.bucket(item: item("流浪地球", "刘", origin: "a", intro: "讲述三体危机"), keyword: "三体"),
            .other
        )
    }

    func testBucketEmptyKeywordIsOther() {
        XCTAssertEqual(BookMerger.bucket(item: item("三体", "刘", origin: "a"), keyword: ""), .other)
    }

    // MARK: - 合并与排序

    func testMergeGroupSameBookAcrossSources() {
        let books = BookMerger.merge(
            [item("三体", "刘慈欣", origin: "a"), item("三体", "刘慈欣", origin: "b")],
            keyword: "三体"
        ).books
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].sourceCount, 2)
        XCTAssertEqual(books[0].sources.count, 2)
        XCTAssertEqual(books[0].bucket, .exact)
    }

    func testMergeKeepsFirstAppearanceFields() {
        let books = BookMerger.merge(
            [item("三体", "刘慈欣", origin: "a"), item("三体", "刘慈欣", origin: "b", kind: "科幻")],
            keyword: "三体"
        ).books
        // kind 从任一源补齐
        XCTAssertEqual(books[0].kind, "科幻")
    }

    func testMergeBestBucketAcrossSources() {
        // a 源没 kind（contains），b 源有 kind（category）→ 取最优桶
        let books = BookMerger.merge(
            [item("三体前传", "刘", origin: "a"), item("三体前传", "刘", origin: "b", kind: "三体系列")],
            keyword: "三体"
        ).books
        XCTAssertEqual(books[0].bucket, .category)
    }

    func testMergeDedupSameOriginSameBook() {
        // 同一源对同一本书的多条结果只保留第一条
        let books = BookMerger.merge(
            [item("三体", "刘慈欣", origin: "a"), item("三体", "刘慈欣", origin: "a")],
            keyword: "三体"
        ).books
        XCTAssertEqual(books[0].sourceCount, 1)
    }

    func testMergeDifferentAuthorsNotMerged() {
        let books = BookMerger.merge(
            [item("三体", "刘慈欣", origin: "a"), item("三体", "别人", origin: "b")],
            keyword: "三体"
        ).books
        XCTAssertEqual(books.count, 2)
    }

    func testMergeAuthorNormalizationMerges() {
        // 「刘慈欣」与「刘慈欣 」（尾空格）归一化后同名同作者 → 合并
        let a = SearchResultItem(name: "三体", author: "刘慈欣", bookUrl: "u1", origin: "a", originName: "a")
        let b = SearchResultItem(name: "三体", author: "刘慈欣 ", bookUrl: "u2", origin: "b", originName: "b")
        let books = BookMerger.merge([a, b], keyword: "三体").books
        XCTAssertEqual(books.count, 1)
    }

    func testMergeSortBucketFirst() {
        let books = BookMerger.merge(
            [item("流浪地球", "刘", origin: "a"), item("三体", "刘慈欣", origin: "b")],
            keyword: "三体"
        ).books
        XCTAssertEqual(books.first?.name, "三体") // exact 桶在前
    }

    func testMergeSortMultiSourceBeforeSingle() {
        // 同桶内：多源命中优先
        let books = BookMerger.merge(
            [item("三体Ⅱ", "刘", origin: "a"), item("三体Ⅲ", "刘", origin: "x"), item("三体Ⅲ", "刘", origin: "y")],
            keyword: "三体"
        ).books
        XCTAssertEqual(books.first?.name, "三体Ⅲ")
    }

    func testMergeSortShorterNameFirstOnTie() {
        let books = BookMerger.merge(
            [item("三体后传很长很长的名字", "刘", origin: "a"), item("三体后传", "刘", origin: "b")],
            keyword: "三体"
        ).books
        XCTAssertEqual(books.first?.name, "三体后传")
    }

    func testMergeTruncationAndCount() {
        var items: [SearchResultItem] = []
        for i in 0..<25 {
            items.append(item("书\(i)", "作\(i)", origin: "a"))
        }
        let (books, truncated) = BookMerger.merge(items, keyword: "三体", maxCount: 10)
        XCTAssertEqual(books.count, 10)
        XCTAssertEqual(truncated, 15)
    }

    func testMergeDefaultCap1000() {
        XCTAssertEqual(BookMerger.maxResults, 1000)
        var items: [SearchResultItem] = []
        for i in 0..<1005 {
            items.append(item("k\(i)", "a\(i)", origin: "s\(i % 3)"))
        }
        let (books, truncated) = BookMerger.merge(items, keyword: "三体")
        XCTAssertEqual(books.count, 1000)
        XCTAssertEqual(truncated, 5)
    }

    func testMergeEmptyInput() {
        let (books, truncated) = BookMerger.merge([], keyword: "x")
        XCTAssertTrue(books.isEmpty)
        XCTAssertEqual(truncated, 0)
    }

    func testMergedBookIdentifiableKey() {
        let a = item("三体", "刘慈欣", origin: "a")
        let books = BookMerger.merge([a], keyword: "三体").books
        XCTAssertEqual(books[0].key.name, "三体")
        XCTAssertFalse(books[0].id.isEmpty)
    }

    func testMergePreservesAllSourceEntries() {
        let books = BookMerger.merge(
            [item("三体", "刘", origin: "a"), item("三体", "刘", origin: "b"), item("三体", "刘", origin: "c")],
            keyword: "三体"
        ).books
        XCTAssertEqual(Set(books[0].sources.map(\.origin)), ["a", "b", "c"])
    }

    // MARK: - 聚合状态（SearchReport）

    func testSearchReportSummaryCounts() {
        let report = SearchReport(
            keyword: "三体",
            outcomes: [
                SourceSearchOutcome(sourceKey: "a", sourceName: "A", state: .success, items: [item("三体", "刘", origin: "a")], errorMessage: nil, elapsedMs: 100),
                SourceSearchOutcome(sourceKey: "b", sourceName: "B", state: .failed, items: [], errorMessage: "网络错误", elapsedMs: 50),
                SourceSearchOutcome(sourceKey: "c", sourceName: "C", state: .empty, items: [], errorMessage: nil, elapsedMs: 30),
            ],
            merged: [],
            truncatedCount: 0
        )
        XCTAssertEqual(report.successSourceCount, 1)
        XCTAssertEqual(report.failedSourceCount, 1)
        XCTAssertEqual(report.emptySourceCount, 1)
    }

    func testSearchReportSummaryTextMentionsFailure() {
        let report = SearchReport(
            keyword: "三体",
            outcomes: [
                SourceSearchOutcome(sourceKey: "b", sourceName: "B", state: .failed, items: [], errorMessage: "网络错误", elapsedMs: 50),
            ],
            merged: [],
            truncatedCount: 0
        )
        let text = report.summaryText
        XCTAssertTrue(text.contains("失败") || text.contains("错误"), "汇总应提示失败源，实际：\(text)")
    }

    func testUnsupportedSourceCountedSeparately() {
        let report = SearchReport(
            keyword: "x",
            outcomes: [
                SourceSearchOutcome(sourceKey: "c", sourceName: "C", state: .unsupported, items: [], errorMessage: "js", elapsedMs: 1),
            ],
            merged: [],
            truncatedCount: 0
        )
        XCTAssertEqual(report.unsupportedSourceCount, 1)
    }

    // MARK: - 归一化

    func testBookKeyNormalize() {
        XCTAssertEqual(BookKey.normalize("  A　B  "), BookKey.normalize("a b"))
        XCTAssertEqual(BookKey.normalize("ABC"), "abc")
    }

    func testBookKeyRawFormat() {
        let k = BookKey(name: "n", author: "a")
        XCTAssertEqual(k.raw, "n\u{1}a")
    }
}
