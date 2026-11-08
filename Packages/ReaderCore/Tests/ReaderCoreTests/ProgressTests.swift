import XCTest
@testable import ReaderCore

/// 阅读进度：5 条验收标准（4.9）+ 钳制 + 节流。
final class ProgressTests: XCTestCase {

    // MARK: - 4.9-(1) 记录维度：章节号 + 章内字符偏移（无页码）

    func testProgressModelFields() {
        let p = ReadingProgress(
            bookKey: "src|https://b/1", chapterIndex: 3,
            characterOffset: 123, chapterTitle: "第四章", fraction: 0.31
        )
        XCTAssertEqual(p.chapterIndex, 3)
        XCTAssertEqual(p.characterOffset, 123)
        XCTAssertEqual(p.chapterTitle, "第四章")
        XCTAssertEqual(p.bookKey, "src|https://b/1")
    }

    func testProgressCodableRoundTrip() throws {
        let p = ReadingProgress(bookKey: "k", chapterIndex: 2, characterOffset: 45, chapterTitle: "t", fraction: 0.2)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(ReadingProgress.self, from: data)
        XCTAssertEqual(back, p)
    }

    // MARK: - 4.9-(2) 切章立即落盘

    func testSwitchChapterSavesImmediately() {
        let store = InMemoryProgressStore()
        let c = ProgressCoordinator(store: store, bookKey: "k1")
        c.switchChapter(to: 5, title: "第六章", chapterCount: 20)
        // 不调 flush，store 里也必须有
        let saved = store.load(bookKey: "k1")
        XCTAssertEqual(saved?.chapterIndex, 5)
        XCTAssertEqual(saved?.chapterTitle, "第六章")
        XCTAssertEqual(c.snapshot?.chapterIndex, 5)
    }

    func testSwitchChapterClearsPendingOffset() {
        let store = InMemoryProgressStore()
        let c = ProgressCoordinator(store: store, bookKey: "k1")
        c.switchChapter(to: 1, title: "一", chapterCount: 10)
        c.updateOffset(500) // 可能被节流挂起
        c.switchChapter(to: 2, title: "二", chapterCount: 10)
        // 切章后 pending 清空：flush 不应把旧偏移写进新章
        c.flush()
        XCTAssertEqual(store.load(bookKey: "k1")?.chapterIndex, 2)
        XCTAssertEqual(store.load(bookKey: "k1")?.characterOffset, 0)
    }

    func testSwitchChapterClampsNegative() {
        let store = InMemoryProgressStore()
        let c = ProgressCoordinator(store: store, bookKey: "k1")
        c.switchChapter(to: -3, title: "x", offset: -10, chapterCount: 10)
        XCTAssertEqual(store.load(bookKey: "k1")?.chapterIndex, 0)
        XCTAssertEqual(store.load(bookKey: "k1")?.characterOffset, 0)
    }

    // MARK: - 4.9-(3) 滚动节流 ≤1s

    func testThrottleIntervalDefaultIsOneSecond() {
        let c = ProgressCoordinator(store: InMemoryProgressStore(), bookKey: "k")
        XCTAssertEqual(c.throttleInterval, 1.0)
    }

    func testUpdateOffsetThrottled() {
        let store = InMemoryProgressStore()
        let c = ProgressCoordinator(store: store, bookKey: "k1")
        c.switchChapter(to: 0, title: "一", chapterCount: 10) // lastSaveAt = now
        c.updateOffset(100) // 距上次保存 < 1s → 挂起
        XCTAssertEqual(store.load(bookKey: "k1")?.characterOffset, 0, "节流窗口内不应写盘")
        // flush 后落盘
        c.flush()
        XCTAssertEqual(store.load(bookKey: "k1")?.characterOffset, 100)
    }

    func testUpdateOffsetAfterIntervalWritesDirectly() {
        let store = InMemoryProgressStore()
        let c = ProgressCoordinator(store: store, bookKey: "k1")
        c.switchChapter(to: 0, title: "一", chapterCount: 10)
        c.throttleInterval = -1 // 强制已过窗口
        c.updateOffset(200)
        XCTAssertEqual(store.load(bookKey: "k1")?.characterOffset, 200)
    }

    func testUpdateOffsetClampsNegative() {
        let store = InMemoryProgressStore()
        let c = ProgressCoordinator(store: store, bookKey: "k1")
        c.switchChapter(to: 0, title: "一", chapterCount: 10)
        c.throttleInterval = -1
        c.updateOffset(-50)
        XCTAssertEqual(store.load(bookKey: "k1")?.characterOffset, 0)
    }

    func testFlushWithoutPendingIsNoop() {
        let store = InMemoryProgressStore()
        let c = ProgressCoordinator(store: store, bookKey: "k1")
        c.switchChapter(to: 1, title: "一", chapterCount: 10)
        c.flush() // 无 pending，不崩不丢
        XCTAssertEqual(store.load(bookKey: "k1")?.chapterIndex, 1)
    }

    // MARK: - 4.9-(4) 退出即保存

    func testExitFlushPersistsLatestOffset() {
        let store = InMemoryProgressStore()
        let c = ProgressCoordinator(store: store, bookKey: "k1")
        c.switchChapter(to: 4, title: "五", chapterCount: 10)
        c.updateOffset(999) // 挂起
        c.flush()           // 退出阅读页
        let saved = store.load(bookKey: "k1")
        XCTAssertEqual(saved?.chapterIndex, 4)
        XCTAssertEqual(saved?.characterOffset, 999)
    }

    // MARK: - 4.9-(5) 恢复（续读）

    func testRestoreReturnsSavedLocator() {
        let store = InMemoryProgressStore()
        store.save(ReadingProgress(bookKey: "k1", chapterIndex: 7, characterOffset: 321, chapterTitle: "八", fraction: 0.5))
        let c = ProgressCoordinator(store: store, bookKey: "k1")
        let loc = c.restore()
        XCTAssertEqual(loc?.chapterIndex, 7)
        XCTAssertEqual(loc?.characterOffset, 321)
    }

    func testRestoreNilWhenNoHistory() {
        let c = ProgressCoordinator(store: InMemoryProgressStore(), bookKey: "nobody")
        XCTAssertNil(c.restore())
    }

    func testOpenTargetWithProgress() {
        let p = ReadingProgress(bookKey: "k", chapterIndex: 3, characterOffset: 50)
        let target = ProgressResolver.openTarget(progress: p, chapterCount: 10)
        XCTAssertEqual(target.chapterIndex, 3)
        XCTAssertEqual(target.characterOffset, 50)
    }

    func testOpenTargetNilProgressStartsAtZero() {
        let target = ProgressResolver.openTarget(progress: nil, chapterCount: 10)
        XCTAssertEqual(target.chapterIndex, 0)
        XCTAssertEqual(target.characterOffset, 0)
    }

    func testOpenTargetClampsOutOfRange() {
        let p = ReadingProgress(bookKey: "k", chapterIndex: 99, characterOffset: 5)
        let target = ProgressResolver.openTarget(progress: p, chapterCount: 10)
        XCTAssertEqual(target.chapterIndex, 9)
    }

    func testOpenTargetZeroChapterCountFallsToZero() {
        let p = ReadingProgress(bookKey: "k", chapterIndex: 3, characterOffset: 5)
        let target = ProgressResolver.openTarget(progress: p, chapterCount: 0)
        XCTAssertEqual(target.chapterIndex, 0)
    }

    // MARK: - 翻章

    func testPreviousAndNextChapter() {
        XCTAssertNil(ProgressResolver.previousChapter(current: 0))
        XCTAssertEqual(ProgressResolver.previousChapter(current: 3), 2)
        XCTAssertEqual(ProgressResolver.nextChapter(current: 3, chapterCount: 10), 4)
        XCTAssertNil(ProgressResolver.nextChapter(current: 9, chapterCount: 10))
        XCTAssertNil(ProgressResolver.nextChapter(current: 10, chapterCount: 10))
    }

    // MARK: - 偏移钳制（换源/重新解析后章节变短）

    func testClampOffset() {
        XCTAssertEqual(ProgressCoordinator.clampOffset(500, chapterCharacterCount: 300), 300)
        XCTAssertEqual(ProgressCoordinator.clampOffset(100, chapterCharacterCount: 300), 100)
        XCTAssertEqual(ProgressCoordinator.clampOffset(-5, chapterCharacterCount: 300), 0)
        XCTAssertEqual(ProgressCoordinator.clampOffset(50, chapterCharacterCount: 0), 50)
    }

    // MARK: - 百分比

    func testFractionMonotonicAcrossChapters() {
        let f0 = ProgressCoordinator.fraction(chapterIndex: 0, offset: 0, chapterCount: 10)
        let f5 = ProgressCoordinator.fraction(chapterIndex: 5, offset: 0, chapterCount: 10)
        let f9 = ProgressCoordinator.fraction(chapterIndex: 9, offset: 8000, chapterCount: 10)
        XCTAssertTrue(f0 < f5 && f5 < f9)
    }

    func testFractionBounded01() {
        XCTAssertEqual(ProgressCoordinator.fraction(chapterIndex: 0, offset: 0, chapterCount: 0), 0)
        XCTAssertLessThanOrEqual(ProgressCoordinator.fraction(chapterIndex: 99, offset: 999999, chapterCount: 1), 1.0)
        XCTAssertGreaterThanOrEqual(ProgressCoordinator.fraction(chapterIndex: -2, offset: -3, chapterCount: 10), 0.0)
    }

    // MARK: - 存储层

    func testInMemoryStoreCRUD() {
        let s = InMemoryProgressStore()
        XCTAssertNil(s.load(bookKey: "a"))
        s.save(ReadingProgress(bookKey: "a", chapterIndex: 1, characterOffset: 1))
        s.save(ReadingProgress(bookKey: "b", chapterIndex: 2, characterOffset: 2))
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.allProgress().count, 2)
        XCTAssertEqual(s.load(bookKey: "a")?.chapterIndex, 1)
        s.remove(bookKey: "a")
        XCTAssertNil(s.load(bookKey: "a"))
        XCTAssertEqual(s.count, 1)
    }

    func testStoreSaveOverwritesSameBook() {
        let s = InMemoryProgressStore()
        s.save(ReadingProgress(bookKey: "a", chapterIndex: 1, characterOffset: 1))
        s.save(ReadingProgress(bookKey: "a", chapterIndex: 5, characterOffset: 5))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.load(bookKey: "a")?.chapterIndex, 5)
    }

    // MARK: - 字号变化不改偏移（字符偏移的意义）

    func testCharacterOffsetInvariantAcrossLayoutChange() {
        // 排版参数变化后，同一阅读位置的字符偏移不变（无需换算）
        let offsetBefore = 1234
        let s1 = ReadingSettings.default
        let s2 = ReadingSettings(fontSize: 28, lineSpacing: 2.0)
        XCTAssertNotEqual(s1.layoutSignature, s2.layoutSignature)
        // 偏移本身就是位置事实，与排版无关
        XCTAssertEqual(ProgressCoordinator.clampOffset(offsetBefore, chapterCharacterCount: 5000), 1234)
    }

    // MARK: - 多书隔离

    func testCoordinatorIsolatedPerBook() {
        let store = InMemoryProgressStore()
        let c1 = ProgressCoordinator(store: store, bookKey: "book1")
        let c2 = ProgressCoordinator(store: store, bookKey: "book2")
        c1.switchChapter(to: 1, title: "一", chapterCount: 10)
        c2.switchChapter(to: 8, title: "九", chapterCount: 10)
        XCTAssertEqual(store.load(bookKey: "book1")?.chapterIndex, 1)
        XCTAssertEqual(store.load(bookKey: "book2")?.chapterIndex, 8)
        XCTAssertEqual(c1.bookKey, "book1")
    }

    func testSnapshotReflectsLatestState() {
        let c = ProgressCoordinator(store: InMemoryProgressStore(), bookKey: "k")
        XCTAssertNil(c.snapshot)
        c.switchChapter(to: 2, title: "三", chapterCount: 10)
        c.throttleInterval = -1
        c.updateOffset(77)
        XCTAssertEqual(c.snapshot?.characterOffset, 77)
    }
}
